//! Small types shared by runtime ports.

use serde_json::{Map, Value};
use thiserror::Error;

/// A JSON object accepted at a typed protocol or provider boundary.
pub type JsonObject = Map<String, Value>;

/// Safe error categories used when adapting module errors to protocol output.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgentErrorCode {
    Cancelled,
    InvalidRequest,
    CapabilityUnavailable,
    PermissionDenied,
    Conflict,
    StaleRevision,
    BudgetExceeded,
    Failed,
}

/// A concise, non-sensitive failure that may cross an Agent boundary.
#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
#[error("{message}")]
pub struct AgentError {
    pub code: AgentErrorCode,
    pub message: &'static str,
}

impl AgentError {
    pub const fn new(code: AgentErrorCode, message: &'static str) -> Self {
        Self { code, message }
    }
}

pub type AgentResult<T> = Result<T, AgentError>;
