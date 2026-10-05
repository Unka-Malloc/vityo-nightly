//! Provider-neutral request and streaming types.

use std::time::Duration;

use crate::{cancellation::AgentCancellationToken, contracts::JsonObject};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelMessageRole {
    System,
    User,
    Assistant,
    Tool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ModelToolCall {
    pub id: String,
    pub name: String,
    pub arguments: JsonObject,
}

/// A message in the canonical provider conversation history.
///
/// Assistant tool-call messages keep their structured calls and tool results
/// keep their matching call id; neither is flattened into text.
#[derive(Clone, Debug, PartialEq)]
pub struct ModelMessage {
    pub role: ModelMessageRole,
    pub content: Option<String>,
    pub tool_calls: Vec<ModelToolCall>,
    pub tool_call_id: Option<String>,
}

impl ModelMessage {
    pub fn text(role: ModelMessageRole, content: impl Into<String>) -> Self {
        Self {
            role,
            content: Some(content.into()),
            tool_calls: Vec::new(),
            tool_call_id: None,
        }
    }

    pub fn assistant_tool_calls(calls: Vec<ModelToolCall>) -> Self {
        Self {
            role: ModelMessageRole::Assistant,
            content: None,
            tool_calls: calls,
            tool_call_id: None,
        }
    }

    pub fn tool_result(call_id: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            role: ModelMessageRole::Tool,
            content: Some(content.into()),
            tool_calls: Vec::new(),
            tool_call_id: Some(call_id.into()),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelRetrySafety {
    ReadOnly,
    IdempotentMutation,
    UnsafeMutation,
}

impl ModelRetrySafety {
    fn permits_replay(self, idempotency_key: Option<&str>) -> bool {
        match self {
            Self::ReadOnly => true,
            Self::IdempotentMutation => idempotency_key.is_some_and(|key| !key.trim().is_empty()),
            Self::UnsafeMutation => false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelEffectState {
    None,
    Uncertain,
    Committed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProviderFailureKind {
    Authentication,
    RateLimited,
    TransientUnavailable,
    InvalidRequest,
    CapabilityUnavailable,
    BudgetExceeded,
    Cancelled,
    Deadline,
    Protocol,
    CredentialStoreUnavailable,
}

/// Provider errors intentionally contain a safe category message, never SDK or
/// response-body text that could disclose credentials, prompts, or endpoints.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProviderFailure {
    pub kind: ProviderFailureKind,
    pub message: &'static str,
    pub retryable: bool,
    pub effect_state: ModelEffectState,
    pub retry_after: Option<Duration>,
    pub usage: Option<ModelUsage>,
}

impl ProviderFailure {
    pub const fn new(
        kind: ProviderFailureKind,
        message: &'static str,
        retryable: bool,
        effect_state: ModelEffectState,
    ) -> Self {
        Self {
            kind,
            message,
            retryable,
            effect_state,
            retry_after: None,
            usage: None,
        }
    }

    pub fn with_retry_after(mut self, retry_after: Duration) -> Self {
        self.retry_after = Some(retry_after);
        self
    }

    pub fn with_usage(mut self, usage: ModelUsage) -> Self {
        self.usage = Some(usage);
        self
    }

    pub fn permits_fallback(&self, request: &ModelRequest) -> bool {
        request
            .retry_safety
            .permits_replay(request.idempotency_key.as_deref())
            && self.retryable
            && self.effect_state == ModelEffectState::None
            && matches!(
                self.kind,
                ProviderFailureKind::RateLimited | ProviderFailureKind::TransientUnavailable
            )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ModelProviderCapabilities {
    pub context_tokens: u32,
    /// `None` means the provider declares no finite output ceiling.
    pub output_tokens: Option<u32>,
    pub supports_tools: bool,
    pub max_concurrency: usize,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ProviderRequirements {
    pub requires_tools: bool,
    pub minimum_context_tokens: u32,
    pub minimum_output_tokens: u32,
}

impl ProviderRequirements {
    pub fn accepts(self, capabilities: ModelProviderCapabilities) -> bool {
        (!self.requires_tools || capabilities.supports_tools)
            && capabilities.context_tokens >= self.minimum_context_tokens
            && capabilities
                .output_tokens
                .is_none_or(|output_tokens| output_tokens >= self.minimum_output_tokens)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ModelToolDefinition {
    pub name: String,
    pub description: String,
    pub input_schema: JsonObject,
}

#[derive(Clone, Debug)]
pub struct ModelRequest {
    pub request_id: String,
    pub messages: Vec<ModelMessage>,
    pub tools: Vec<ModelToolDefinition>,
    pub estimated_context_tokens: u32,
    /// `None` means no explicit output ceiling: the request omits the provider's
    /// max-output field and skips output budgeting.
    pub output_token_limit: Option<u32>,
    pub retry_safety: ModelRetrySafety,
    pub idempotency_key: Option<String>,
    pub deadline: Option<tokio::time::Instant>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelFinishReason {
    Completed,
    ToolCalls,
    Length,
    ContentFilter,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ModelEvent {
    TextDelta(String),
    ToolCallDelta {
        index: u32,
        id: Option<String>,
        name: Option<String>,
        arguments_fragment: String,
    },
    Usage(ModelUsage),
    Completed(ModelFinishReason),
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ModelUsage {
    pub input_tokens: u32,
    pub output_tokens: u32,
    /// Provider pricing is not part of the OpenAI-compatible usage contract.
    pub cost_micros: Option<u64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ModelExecutionReceipt {
    pub request_id: String,
    pub provider_id: String,
    pub text: String,
    pub tool_calls: Vec<ModelToolCall>,
    pub usage: ModelUsage,
    pub finish_reason: ModelFinishReason,
}

pub type ProviderEventStream =
    futures::stream::BoxStream<'static, Result<ModelEvent, ProviderFailure>>;

pub trait ModelProvider: Send + Sync {
    fn id(&self) -> &str;

    fn capabilities(&self) -> ModelProviderCapabilities;

    fn stream(
        &self,
        request: ModelRequest,
        cancellation: AgentCancellationToken,
    ) -> ProviderEventStream;
}
