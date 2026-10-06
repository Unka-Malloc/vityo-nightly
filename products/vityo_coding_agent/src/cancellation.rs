//! Structured cancellation shared by runtime modules.

pub use tokio_util::sync::CancellationToken as AgentCancellationToken;

/// Creates a cancellation scope for one session or child operation.
pub fn cancellation_scope() -> AgentCancellationToken {
    AgentCancellationToken::new()
}
