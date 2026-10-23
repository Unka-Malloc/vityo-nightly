//! The single ReAct action/observation loop used by the production ACP host.

use std::sync::Arc;

use async_trait::async_trait;

use crate::{
    cancellation::AgentCancellationToken,
    providers::{
        ModelExecutionReceipt, ModelMessage, ModelMessageRole, ModelRequest, ModelRetrySafety,
        ModelToolCall, ModelToolDefinition, ProviderFailure, ProviderFailureKind,
        ProviderRequirements, ProviderRouter,
    },
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RuntimeUpdate {
    ToolStarted {
        call_id: String,
        name: String,
    },
    ToolFinished {
        call_id: String,
        name: String,
        successful: bool,
        summary: String,
    },
}

#[async_trait]
pub trait RuntimeEventSink: Send + Sync {
    async fn emit(&self, update: RuntimeUpdate) -> Result<(), RuntimeHostError>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimeEffectState {
    None,
    Uncertain,
    Committed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolObservation {
    /// The actual operation result passed back to the model as an observation.
    pub content: String,
    /// Whether the operation produced a successful domain result.
    pub successful: bool,
    /// An uncertain dispatched effect ends the loop; it must not trigger a retry.
    pub effect_state: RuntimeEffectState,
    /// A concise, user-safe status for the ACP activity projection.
    pub summary: String,
}

#[async_trait]
pub trait ReActToolRuntime: Send + Sync {
    fn definitions(&self) -> Vec<ModelToolDefinition>;

    async fn invoke(
        &self,
        call: ModelToolCall,
        cancellation: AgentCancellationToken,
    ) -> Result<ToolObservation, RuntimeToolError>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimeToolError {
    Cancelled,
    CapabilityUnavailable,
    InvalidCall,
    PermissionDenied,
    StorageUnavailable,
    HostUnavailable,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimeHostError {
    ConnectionClosed,
    UpdateRejected,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompletedTurn {
    pub user_text: String,
    pub assistant_text: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReActTurnReceipt {
    pub assistant_text: String,
    pub tool_call_count: usize,
    pub usage: crate::providers::ModelUsage,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReActFailureKind {
    Cancelled,
    ProviderUnavailable,
    ProviderAuthentication,
    ProviderRateLimited,
    ProviderInvalidRequest,
    ProviderBudgetExceeded,
    ProviderProtocol,
    ProviderCredentialsUnavailable,
    ToolLimitReached,
    InvalidModelAction,
    UncertainToolEffect,
    ToolUnavailable,
    HostUnavailable,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReActFailure {
    pub kind: ReActFailureKind,
    pub message: &'static str,
}

impl ReActFailure {
    const fn new(kind: ReActFailureKind, message: &'static str) -> Self {
        Self { kind, message }
    }
}

pub struct ReActRuntime {
    provider: Arc<ProviderRouter>,
    output_token_limit: Option<u32>,
    context_tokens: u32,
    max_tool_calls: usize,
    system_prompt: String,
}

impl ReActRuntime {
    pub fn new(
        provider: Arc<ProviderRouter>,
        output_token_limit: Option<u32>,
        context_tokens: u32,
        max_tool_calls: usize,
        system_prompt: impl Into<String>,
    ) -> Option<Self> {
        (output_token_limit.is_none_or(|limit| limit > 0)
            && output_token_limit.is_none_or(|limit| limit <= context_tokens)
            && context_tokens > 0
            && max_tool_calls > 0)
            .then(|| Self {
                provider,
                output_token_limit,
                context_tokens,
                max_tool_calls,
                system_prompt: system_prompt.into(),
            })
    }

    /// Runs one user turn through repeated model action, authorized tool, and observation steps.
    /// Tool outputs remain internal context; only a final no-tool model response is user-facing.
    pub async fn run_turn(
        &self,
        completed_turns: &[CompletedTurn],
        user_text: &str,
        tools: &dyn ReActToolRuntime,
        sink: &dyn RuntimeEventSink,
        cancellation: AgentCancellationToken,
    ) -> Result<ReActTurnReceipt, ReActFailure> {
        if user_text.trim().is_empty() {
            return Err(ReActFailure::new(
                ReActFailureKind::InvalidModelAction,
                "The prompt is empty.",
            ));
        }

        let definitions = tools.definitions();
        let mut conversation = conversation_for_turns(
            completed_turns,
            user_text,
            &self.system_prompt,
            &definitions,
            self.context_tokens,
            self.output_token_limit,
        );
        let mut tool_call_count = 0;
        let mut usage = crate::providers::ModelUsage::default();

        loop {
            if cancellation.is_cancelled() {
                return Err(cancelled());
            }
            let request = model_request(&conversation, &definitions, self.output_token_limit);
            let receipt = self
                .provider
                .generate(
                    request,
                    ProviderRequirements {
                        requires_tools: !definitions.is_empty(),
                        ..ProviderRequirements::default()
                    },
                    cancellation.clone(),
                )
                .await
                .map_err(map_provider_failure)?;
            usage.input_tokens = usage
                .input_tokens
                .saturating_add(receipt.usage.input_tokens);
            usage.output_tokens = usage
                .output_tokens
                .saturating_add(receipt.usage.output_tokens);
            usage.cost_micros = match (usage.cost_micros, receipt.usage.cost_micros) {
                (Some(left), Some(right)) => Some(left.saturating_add(right)),
                _ => None,
            };

            if receipt.tool_calls.is_empty() {
                if receipt.text.trim().is_empty() {
                    return Err(ReActFailure::new(
                        ReActFailureKind::InvalidModelAction,
                        "The model returned no final response.",
                    ));
                }
                return Ok(ReActTurnReceipt {
                    assistant_text: receipt.text,
                    tool_call_count,
                    usage,
                });
            }

            if receipt.finish_reason != crate::providers::ModelFinishReason::ToolCalls {
                return Err(ReActFailure::new(
                    ReActFailureKind::InvalidModelAction,
                    "The model returned tool calls with an incompatible finish reason.",
                ));
            }
            if definitions.is_empty()
                || receipt.tool_calls.iter().any(|call| {
                    !definitions
                        .iter()
                        .any(|definition| definition.name == call.name)
                })
            {
                return Err(ReActFailure::new(
                    ReActFailureKind::InvalidModelAction,
                    "The model selected an unavailable operation.",
                ));
            }
            tool_call_count = tool_call_count.saturating_add(receipt.tool_calls.len());
            if tool_call_count > self.max_tool_calls {
                return Err(ReActFailure::new(
                    ReActFailureKind::ToolLimitReached,
                    "The operation budget for this turn was reached.",
                ));
            }

            conversation.push(assistant_action_message(&receipt));
            for call in receipt.tool_calls {
                if cancellation.is_cancelled() {
                    return Err(cancelled());
                }
                sink.emit(RuntimeUpdate::ToolStarted {
                    call_id: call.id.clone(),
                    name: call.name.clone(),
                })
                .await
                .map_err(|_| host_unavailable())?;

                let observation = match tools.invoke(call.clone(), cancellation.clone()).await {
                    Ok(observation) => observation,
                    Err(RuntimeToolError::Cancelled) => return Err(cancelled()),
                    Err(RuntimeToolError::PermissionDenied) => ToolObservation {
                        content: "{\"error\":\"permission_denied\"}".to_owned(),
                        successful: false,
                        effect_state: RuntimeEffectState::None,
                        summary: "Permission was not granted.".to_owned(),
                    },
                    Err(RuntimeToolError::CapabilityUnavailable) => ToolObservation {
                        content: "{\"error\":\"capability_unavailable\"}".to_owned(),
                        successful: false,
                        effect_state: RuntimeEffectState::None,
                        summary: "The requested operation is unavailable.".to_owned(),
                    },
                    Err(RuntimeToolError::InvalidCall) => ToolObservation {
                        content: "{\"error\":\"invalid_call\"}".to_owned(),
                        successful: false,
                        effect_state: RuntimeEffectState::None,
                        summary: "The requested operation was rejected.".to_owned(),
                    },
                    Err(RuntimeToolError::StorageUnavailable) => {
                        return Err(ReActFailure::new(
                            ReActFailureKind::ToolUnavailable,
                            "The operation journal is unavailable.",
                        ));
                    }
                    Err(RuntimeToolError::HostUnavailable) => {
                        return Err(ReActFailure::new(
                            ReActFailureKind::ToolUnavailable,
                            "The IDE operation channel is unavailable.",
                        ));
                    }
                };
                if observation.effect_state == RuntimeEffectState::Uncertain {
                    sink.emit(RuntimeUpdate::ToolFinished {
                        call_id: call.id.clone(),
                        name: call.name,
                        successful: false,
                        summary: "The operation outcome is uncertain.".to_owned(),
                    })
                    .await
                    .map_err(|_| host_unavailable())?;
                    return Err(ReActFailure::new(
                        ReActFailureKind::UncertainToolEffect,
                        "An operation outcome is uncertain and will not be retried automatically.",
                    ));
                }
                sink.emit(RuntimeUpdate::ToolFinished {
                    call_id: call.id.clone(),
                    name: call.name,
                    successful: observation.successful,
                    summary: observation.summary,
                })
                .await
                .map_err(|_| host_unavailable())?;
                conversation.push(ModelMessage::tool_result(call.id, observation.content));
            }
        }
    }
}

/// Pi-style context management: history is compacted only when the estimated
/// request would leave too little room for the model's own answer.
///
/// The context window is split into an output reserve and space left for input.
/// The default reserve is one quarter of the window, capped at Pi's 16384-token
/// default; a configured output ceiling can raise it. The hot window is at most
/// half the context and half the input left after reserving output, capped at
/// Pi's 20000-token default.
const RESERVE_OUTPUT_TOKENS: u32 = 16_384;
const KEEP_RECENT_TOKENS: u32 = 20_000;
/// Deterministic summary ceiling; also bounded by an eighth of the window.
const SUMMARY_TOKEN_BUDGET: u32 = 4_096;

/// Output space reserved inside the context window, raised to the configured
/// output ceiling when it is larger than the proportional default.
fn context_reserve_tokens(context_tokens: u32, output_token_limit: Option<u32>) -> u32 {
    context_tokens
        .div_ceil(4)
        .min(RESERVE_OUTPUT_TOKENS)
        .max(output_token_limit.unwrap_or(0))
        .min(context_tokens)
}

/// Verbatim recent history ceiling: at most half the context window and half
/// the input left after the output reserve, never more than Pi's 20000-token
/// default.
fn keep_recent_tokens(context_tokens: u32, reserve_tokens: u32) -> u32 {
    context_tokens
        .div_ceil(2)
        .min(context_tokens.saturating_sub(reserve_tokens).div_ceil(2))
        .min(KEEP_RECENT_TOKENS)
}

/// Summary ceiling: an eighth of the context window, never above 4096 tokens.
fn summary_token_budget(context_tokens: u32) -> usize {
    (context_tokens / 8).min(SUMMARY_TOKEN_BUDGET) as usize
}

fn conversation_for_turns(
    completed_turns: &[CompletedTurn],
    current_user_text: &str,
    system_prompt: &str,
    tools: &[ModelToolDefinition],
    context_tokens: u32,
    output_token_limit: Option<u32>,
) -> Vec<ModelMessage> {
    let reserve_tokens = context_reserve_tokens(context_tokens, output_token_limit);
    let trigger = context_tokens.saturating_sub(reserve_tokens);
    let verbatim = assemble_messages(completed_turns, 0, None, current_user_text, system_prompt);
    if estimated_request_tokens(&verbatim, tools) <= trigger {
        return verbatim;
    }

    let keep_recent = keep_recent_tokens(context_tokens, reserve_tokens);
    let mut hot_start = completed_turns.len();
    let mut hot_tokens = 0_u32;
    while hot_start > 0 {
        let turn_tokens = turn_token_cost(&completed_turns[hot_start - 1]);
        if hot_tokens.saturating_add(turn_tokens) > keep_recent {
            break;
        }
        hot_tokens = hot_tokens.saturating_add(turn_tokens);
        hot_start -= 1;
    }
    // Keep the latest turn verbatim even when it alone exceeds the hot window.
    if hot_start == completed_turns.len() && !completed_turns.is_empty() {
        hot_start = completed_turns.len() - 1;
    }
    let compaction = crate::context::ConversationCompactor.compact(
        &summarizable_turns(&completed_turns[..hot_start]),
        0,
        summary_token_budget(context_tokens),
    );
    assemble_messages(
        completed_turns,
        hot_start,
        Some(&compaction.summary),
        current_user_text,
        system_prompt,
    )
}

fn assemble_messages(
    completed_turns: &[CompletedTurn],
    hot_start: usize,
    summary: Option<&str>,
    current_user_text: &str,
    system_prompt: &str,
) -> Vec<ModelMessage> {
    let hot_turns = &completed_turns[hot_start..];
    let mut messages = Vec::with_capacity(hot_turns.len() * 2 + 3);
    messages.push(ModelMessage::text(ModelMessageRole::System, system_prompt));
    if let Some(summary) = summary.filter(|summary| !summary.is_empty()) {
        messages.push(ModelMessage::text(
            ModelMessageRole::System,
            format!("Earlier conversation context:\n{summary}"),
        ));
    }
    for turn in hot_turns {
        messages.push(ModelMessage::text(
            ModelMessageRole::User,
            turn.user_text.clone(),
        ));
        messages.push(ModelMessage::text(
            ModelMessageRole::Assistant,
            turn.assistant_text.clone(),
        ));
    }
    messages.push(ModelMessage::text(
        ModelMessageRole::User,
        current_user_text,
    ));
    messages
}

fn turn_text(turn: &CompletedTurn) -> String {
    format!(
        "User: {}\nAssistant: {}",
        turn.user_text, turn.assistant_text
    )
}

fn turn_token_cost(turn: &CompletedTurn) -> u32 {
    turn_text(turn).len().div_ceil(4).min(u32::MAX as usize) as u32
}

fn summarizable_turns(turns: &[CompletedTurn]) -> Vec<crate::context::ConversationTurn> {
    turns
        .iter()
        .enumerate()
        .map(|(index, turn)| {
            let text = turn_text(turn);
            let id = format!("turn-{index}");
            let revision = index as u64;
            // The compactor budgets the rendered summary line, including its
            // identity prefix and separator, rather than only the source text.
            let rendered_bytes = text
                .len()
                .saturating_add(id.len())
                .saturating_add(revision.to_string().len())
                .saturating_add(4); // `@`, `: `, and the joined line break.
            crate::context::ConversationTurn {
                id,
                revision,
                token_cost: rendered_bytes.div_ceil(4),
                text,
                sensitivity: crate::context::ContextSensitivity::Internal,
            }
        })
        .collect()
}

fn estimated_request_tokens(messages: &[ModelMessage], tools: &[ModelToolDefinition]) -> u32 {
    let encoded_bytes = messages
        .iter()
        .map(|message| {
            message.content.as_ref().map_or(0, String::len)
                + message.tool_call_id.as_ref().map_or(0, String::len)
                + message
                    .tool_calls
                    .iter()
                    .map(|call| {
                        call.id
                            .len()
                            .saturating_add(call.name.len())
                            .saturating_add(
                                serde_json::to_vec(&call.arguments)
                                    .map_or(usize::MAX, |bytes| bytes.len()),
                            )
                    })
                    .sum::<usize>()
        })
        .chain(tools.iter().map(|tool| {
            tool.name
                .len()
                .saturating_add(tool.description.len())
                .saturating_add(
                    serde_json::to_vec(&tool.input_schema).map_or(usize::MAX, |bytes| bytes.len()),
                )
        }))
        .fold(0usize, usize::saturating_add);
    encoded_bytes
        .saturating_add(3)
        .checked_div(4)
        .unwrap_or(usize::MAX)
        .min(u32::MAX as usize) as u32
}

fn model_request(
    messages: &[ModelMessage],
    tools: &[ModelToolDefinition],
    output_token_limit: Option<u32>,
) -> ModelRequest {
    ModelRequest {
        request_id: uuid::Uuid::new_v4().to_string(),
        messages: messages.to_vec(),
        tools: tools.to_vec(),
        estimated_context_tokens: estimated_request_tokens(messages, tools),
        output_token_limit,
        retry_safety: ModelRetrySafety::ReadOnly,
        idempotency_key: None,
        deadline: None,
    }
}

fn assistant_action_message(receipt: &ModelExecutionReceipt) -> ModelMessage {
    ModelMessage {
        role: ModelMessageRole::Assistant,
        content: (!receipt.text.is_empty()).then(|| receipt.text.clone()),
        tool_calls: receipt.tool_calls.clone(),
        tool_call_id: None,
    }
}

fn map_provider_failure(failure: ProviderFailure) -> ReActFailure {
    use ProviderFailureKind as Provider;
    let kind = match failure.kind {
        Provider::Authentication => ReActFailureKind::ProviderAuthentication,
        Provider::RateLimited => ReActFailureKind::ProviderRateLimited,
        Provider::InvalidRequest => ReActFailureKind::ProviderInvalidRequest,
        Provider::CapabilityUnavailable => ReActFailureKind::ProviderInvalidRequest,
        Provider::BudgetExceeded => ReActFailureKind::ProviderBudgetExceeded,
        Provider::Cancelled => ReActFailureKind::Cancelled,
        Provider::CredentialStoreUnavailable => ReActFailureKind::ProviderCredentialsUnavailable,
        Provider::Protocol => ReActFailureKind::ProviderProtocol,
        Provider::TransientUnavailable | Provider::Deadline => {
            ReActFailureKind::ProviderUnavailable
        }
    };
    let message = match kind {
        ReActFailureKind::Cancelled => "The turn was cancelled.",
        ReActFailureKind::ProviderAuthentication => "The provider rejected authentication.",
        ReActFailureKind::ProviderRateLimited => "The provider is temporarily rate limited.",
        ReActFailureKind::ProviderInvalidRequest => "The provider rejected the request.",
        ReActFailureKind::ProviderBudgetExceeded => "The provider usage budget was reached.",
        ReActFailureKind::ProviderProtocol => "The provider returned an invalid response.",
        ReActFailureKind::ProviderCredentialsUnavailable => "Provider credentials are unavailable.",
        _ => "The configured provider is unavailable.",
    };
    ReActFailure::new(kind, message)
}

const fn cancelled() -> ReActFailure {
    ReActFailure::new(ReActFailureKind::Cancelled, "The turn was cancelled.")
}

const fn host_unavailable() -> ReActFailure {
    ReActFailure::new(
        ReActFailureKind::HostUnavailable,
        "The IDE operation channel is unavailable.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const SUMMARY_PREFIX: &str = "Earlier conversation context:\n";

    #[test]
    fn reserve_and_hot_window_shrink_with_the_context_window() {
        let large_reserve = context_reserve_tokens(65_536, None);
        let small_reserve = context_reserve_tokens(8_192, None);
        assert_eq!(large_reserve, 16_384);
        assert_eq!(small_reserve, 2_048);
        assert_eq!(context_reserve_tokens(4_096, None), 1_024);
        assert_eq!(context_reserve_tokens(8_192, Some(4_096)), 4_096);
        assert_eq!(keep_recent_tokens(65_536, large_reserve), 20_000);
        assert_eq!(keep_recent_tokens(8_192, small_reserve), 3_072);
        assert_eq!(keep_recent_tokens(8_192, 4_096), 2_048);
        assert_eq!(summary_token_budget(65_536), 4_096);
        assert_eq!(summary_token_budget(8_192), 1_024);
    }

    #[test]
    fn compaction_triggers_earlier_in_a_small_context_window() {
        let turns = turns(12, 2_000);
        let system_prompt = "system";

        let large = conversation_for_turns(&turns, "now", system_prompt, &[], 65_536, None);
        assert!(!contains_summary(&large));
        assert_eq!(verbatim_turn_count(&large, &turns), 12);

        let small = conversation_for_turns(&turns, "now", system_prompt, &[], 8_192, None);
        assert!(contains_summary(&small));
        let kept = verbatim_turn_count(&small, &turns);
        assert!((1..12).contains(&kept), "small window keeps a shrunk tail");
    }

    #[test]
    fn a_short_history_is_kept_verbatim_without_a_summary() {
        let turns = turns(3, 40);
        let messages = conversation_for_turns(&turns, "now", "system", &[], 65_536, None);
        assert!(!contains_summary(&messages));
        assert_eq!(verbatim_turn_count(&messages, &turns), 3);
    }

    #[test]
    fn a_large_configured_output_reserve_compacts_before_the_heuristic() {
        let turns = turns(12, 1_000);
        let heuristic = conversation_for_turns(&turns, "now", "system", &[], 8_192, None);
        let configured = conversation_for_turns(&turns, "now", "system", &[], 8_192, Some(4_096));

        assert_eq!(verbatim_turn_count(&heuristic, &turns), 12);
        assert!(contains_summary(&configured));
        assert!(verbatim_turn_count(&configured, &turns) < 12);
    }

    #[test]
    fn compacted_summary_stays_within_its_rendered_token_budget() {
        let messages = conversation_for_turns(&turns(400, 3), "now", "system", &[], 1_024, None);
        let summary = messages
            .iter()
            .find_map(|message| {
                message
                    .content
                    .as_deref()
                    .and_then(|content| content.strip_prefix(SUMMARY_PREFIX))
            })
            .expect("oversized history is compacted");

        assert!(summary.len() <= summary_token_budget(1_024) * 4);
    }

    fn turns(count: usize, text_len: usize) -> Vec<CompletedTurn> {
        (0..count)
            .map(|index| CompletedTurn {
                user_text: format!("{index:02}{}", "u".repeat(text_len)),
                assistant_text: format!("{index:02}{}", "a".repeat(text_len)),
            })
            .collect()
    }

    fn contains_summary(messages: &[ModelMessage]) -> bool {
        messages.iter().any(|message| {
            message
                .content
                .as_deref()
                .is_some_and(|content| content.starts_with(SUMMARY_PREFIX))
        })
    }

    fn verbatim_turn_count(messages: &[ModelMessage], turns: &[CompletedTurn]) -> usize {
        messages
            .iter()
            .filter(|message| {
                message
                    .content
                    .as_deref()
                    .is_some_and(|content| turns.iter().any(|turn| turn.user_text == content))
            })
            .count()
    }
}
