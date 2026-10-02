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
    output_token_limit: u32,
    max_tool_calls: usize,
    system_prompt: String,
}

impl ReActRuntime {
    pub fn new(
        provider: Arc<ProviderRouter>,
        output_token_limit: u32,
        max_tool_calls: usize,
        system_prompt: impl Into<String>,
    ) -> Option<Self> {
        (output_token_limit > 0 && max_tool_calls > 0).then(|| Self {
            provider,
            output_token_limit,
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
        let mut conversation =
            conversation_for_turns(completed_turns, user_text, &self.system_prompt);
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

fn conversation_for_turns(
    completed_turns: &[CompletedTurn],
    current_user_text: &str,
    system_prompt: &str,
) -> Vec<ModelMessage> {
    const HOT_TURNS: usize = 8;
    const SUMMARY_TOKENS: usize = 4096;
    let compacted_turn_count = completed_turns.len().saturating_sub(HOT_TURNS);
    let old_turns = completed_turns[..compacted_turn_count]
        .iter()
        .enumerate()
        .map(|(index, turn)| {
            let text = format!(
                "User: {}\nAssistant: {}",
                turn.user_text, turn.assistant_text
            );
            crate::context::ConversationTurn {
                id: format!("turn-{index}"),
                revision: index as u64,
                token_cost: text.len().div_ceil(4),
                text,
                sensitivity: crate::context::ContextSensitivity::Internal,
            }
        })
        .collect::<Vec<_>>();
    let compaction = crate::context::ConversationCompactor.compact(&old_turns, 0, SUMMARY_TOKENS);
    let hot_turns = &completed_turns[compacted_turn_count..];
    let mut messages = Vec::with_capacity(hot_turns.len() * 2 + 3);
    messages.push(ModelMessage::text(ModelMessageRole::System, system_prompt));
    if !compaction.summary.is_empty() {
        messages.push(ModelMessage::text(
            ModelMessageRole::System,
            format!("Earlier conversation context:\n{}", compaction.summary),
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

fn model_request(
    messages: &[ModelMessage],
    tools: &[ModelToolDefinition],
    output_token_limit: u32,
) -> ModelRequest {
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
    let estimated_context_tokens = encoded_bytes
        .saturating_add(3)
        .checked_div(4)
        .unwrap_or(usize::MAX)
        .min(u32::MAX as usize) as u32;
    ModelRequest {
        request_id: uuid::Uuid::new_v4().to_string(),
        messages: messages.to_vec(),
        tools: tools.to_vec(),
        estimated_context_tokens,
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
