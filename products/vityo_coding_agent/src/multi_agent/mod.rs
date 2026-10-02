//! Bounded task scheduling over isolated, reviewable worker changes.

mod integration_plan;
mod resource_lease;
mod scheduler;
mod task_graph;
mod worktree;

pub use crate::sessions::utc_now_rfc3339;
pub use integration_plan::{
    IntegrationCandidate, IntegrationCandidateStatus, IntegrationError, IntegrationPlan,
    IntegrationReviewDecision, IntegrationReviewOutcome, IntegrationReviewReceipt,
};
pub use resource_lease::{LeaseDecision, ResourceLeaseRegistry, ResourceLeaseToken};
pub use scheduler::{
    AgentScheduler, DelegationBudget, DelegationOutcome, DelegationStatus, graph_error,
    integration_error,
};
pub use task_graph::{
    DelegatedTask, TaskGraph, TaskGraphError, TaskGraphSchedule, WorkerScope,
    is_normalized_ownership, ownership_scope_contains, ownership_scopes_overlap,
};
pub use worktree::{
    DelegatedWorker, WorkerChangeSet, WorkerRequest, WorkerResult, WorkerResultStatus,
    WorktreeCleanupReceipt, WorktreeHandle, WorktreeProvider,
};
