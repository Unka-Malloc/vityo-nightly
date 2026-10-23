//! Revisioned evidence records and source contracts.

use crate::cancellation::AgentCancellationToken;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum ContextSensitivity {
    Public,
    Internal,
    Confidential,
    Secret,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ContextRange {
    pub start: usize,
    pub end: usize,
}

impl ContextRange {
    pub fn new(start: usize, end: usize) -> Result<Self, ContextEvidenceError> {
        if end < start {
            return Err(ContextEvidenceError::InvalidRange);
        }
        Ok(Self { start, end })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContextProvenance {
    pub source_id: String,
    pub retrieval: String,
    pub source_revision: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ContextEvidence {
    pub id: String,
    pub source: String,
    pub resource: String,
    pub revision: u64,
    pub range: ContextRange,
    pub sensitivity: ContextSensitivity,
    pub base_score: f64,
    pub content: String,
    pub token_cost: usize,
    pub provenance: ContextProvenance,
    pub content_digest: String,
    pub byte_cost: usize,
    pub truncated: bool,
}

impl ContextEvidence {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: String,
        source: String,
        resource: String,
        revision: u64,
        range: ContextRange,
        sensitivity: ContextSensitivity,
        base_score: f64,
        content: String,
        token_cost: usize,
        provenance: ContextProvenance,
        truncated: bool,
    ) -> Result<Self, ContextEvidenceError> {
        if id.is_empty() || source.is_empty() || resource.is_empty() {
            return Err(ContextEvidenceError::EmptyIdentity);
        }
        if !base_score.is_finite() {
            return Err(ContextEvidenceError::InvalidScore);
        }
        use sha2::{Digest, Sha256};
        let bytes = content.as_bytes();
        let byte_cost = bytes.len();
        let digest = Sha256::digest(bytes);
        Ok(Self {
            id,
            source,
            resource,
            revision,
            range,
            sensitivity,
            base_score,
            content,
            token_cost,
            provenance,
            content_digest: format!("{digest:x}"),
            byte_cost,
            truncated,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContextEvidenceError {
    EmptyIdentity,
    InvalidRange,
    InvalidScore,
}

#[derive(Clone, Debug)]
pub struct ContextQuery {
    pub terms: Vec<String>,
    pub roots: Vec<String>,
    pub expected_revisions: std::collections::HashMap<String, u64>,
    pub explicit_evidence_ids: std::collections::HashSet<String>,
    pub maximum_sensitivity: ContextSensitivity,
    pub deadline: Option<tokio::time::Instant>,
}

#[derive(Clone, Debug)]
pub struct ContextBudget {
    pub max_items: usize,
    pub max_bytes: usize,
    pub max_tokens: usize,
    pub reserved_output_tokens: usize,
    pub per_source_caps: std::collections::HashMap<String, usize>,
}

pub trait ContextSource: Send + Sync {
    fn id(&self) -> &str;

    fn fetch<'a>(
        &'a self,
        query: &'a ContextQuery,
        limit: usize,
        cancellation: AgentCancellationToken,
    ) -> futures::future::BoxFuture<'a, Result<ContextPage, ContextSourceFailure>>;
}

#[derive(Clone, Debug, PartialEq)]
pub struct ContextPage {
    pub items: Vec<ContextEvidence>,
    pub has_more: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContextSourceFailureCode {
    Unavailable,
    Deadline,
    InvalidResponse,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContextSourceFailure {
    pub code: ContextSourceFailureCode,
    pub source_id: String,
}

impl ContextSourceFailure {
    pub fn attributed_to(mut self, source: &str) -> Self {
        if self.source_id.is_empty() {
            self.source_id = source.to_owned();
        }
        self
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContextEngineFailureCode {
    Cancelled,
    Deadline,
    InvalidBudget,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ContextEngineFailure(pub ContextEngineFailureCode);
