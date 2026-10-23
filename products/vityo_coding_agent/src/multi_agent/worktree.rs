//! Isolated worker state and execution contracts.

use crate::{cancellation::AgentCancellationToken, contracts::AgentResult};
use async_trait::async_trait;

use super::task_graph::{DelegatedTask, WorkerScope};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorktreeHandle {
    pub id: String,
    pub task_id: String,
    pub base_revision: String,
    pub owned_resources: std::collections::BTreeSet<String>,
}

impl WorktreeHandle {
    pub fn new(
        id: impl Into<String>,
        task_id: impl Into<String>,
        base_revision: impl Into<String>,
        owned_resources: impl IntoIterator<Item = String>,
    ) -> Self {
        Self {
            id: id.into(),
            task_id: task_id.into(),
            base_revision: base_revision.into(),
            owned_resources: owned_resources.into_iter().collect(),
        }
    }

    pub fn is_valid_for(&self, task: &DelegatedTask, base_revision: &str) -> bool {
        !self.id.trim().is_empty()
            && self.task_id == task.id
            && self.base_revision == base_revision
            && self.owned_resources == task.owned_resources
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorktreeCleanupReceipt {
    pub worktree_id: String,
    pub cleaned: bool,
}

#[async_trait]
pub trait WorktreeProvider: Send + Sync {
    async fn create(
        &self,
        task_id: &str,
        base_revision: &str,
        owned_resources: &std::collections::BTreeSet<String>,
        cancellation: AgentCancellationToken,
    ) -> AgentResult<WorktreeHandle>;

    async fn dispose(&self, handle: &WorktreeHandle) -> AgentResult<WorktreeCleanupReceipt>;
}

#[derive(Clone, Debug)]
pub struct WorkerRequest {
    pub task: DelegatedTask,
    pub scope: WorkerScope,
    pub worktree: WorktreeHandle,
    pub session_id: String,
    pub cancellation: AgentCancellationToken,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkerChangeSet {
    pub id: String,
    pub base_revision: String,
    pub resources: std::collections::BTreeSet<String>,
}

impl WorkerChangeSet {
    pub fn new(
        id: impl Into<String>,
        base_revision: impl Into<String>,
        resources: impl IntoIterator<Item = String>,
    ) -> Result<Self, &'static str> {
        let change = Self {
            id: id.into(),
            base_revision: base_revision.into(),
            resources: resources.into_iter().collect(),
        };
        if change.id.trim().is_empty()
            || change.base_revision.trim().is_empty()
            || change.resources.is_empty()
        {
            return Err("invalidChangeSet");
        }
        Ok(change)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkerResultStatus {
    Completed,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug)]
pub struct WorkerResult {
    pub task_id: String,
    pub status: WorkerResultStatus,
    pub change_set: Option<WorkerChangeSet>,
    pub evidence_receipts: Vec<String>,
    /// Stable failure category. Do not place tool output or private data here.
    pub failure: Option<&'static str>,
}

impl WorkerResult {
    pub fn completed(
        task_id: impl Into<String>,
        change_set: WorkerChangeSet,
        evidence_receipts: impl IntoIterator<Item = String>,
    ) -> Self {
        Self {
            task_id: task_id.into(),
            status: WorkerResultStatus::Completed,
            change_set: Some(change_set),
            evidence_receipts: evidence_receipts.into_iter().collect(),
            failure: None,
        }
    }

    pub fn failed(task_id: impl Into<String>, failure: &'static str) -> Self {
        Self {
            task_id: task_id.into(),
            status: WorkerResultStatus::Failed,
            change_set: None,
            evidence_receipts: Vec::new(),
            failure: Some(failure),
        }
    }

    pub fn cancelled(task_id: impl Into<String>) -> Self {
        Self {
            task_id: task_id.into(),
            status: WorkerResultStatus::Cancelled,
            change_set: None,
            evidence_receipts: Vec::new(),
            failure: None,
        }
    }
}

#[async_trait]
pub trait DelegatedWorker: Send + Sync {
    async fn run(&self, request: WorkerRequest) -> AgentResult<WorkerResult>;
}
