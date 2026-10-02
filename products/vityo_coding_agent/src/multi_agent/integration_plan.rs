//! Deterministic integration review for delegated worker changes.

use std::collections::{BTreeMap, BTreeSet};

use super::task_graph::ownership_scopes_overlap;
pub use super::worktree::WorkerChangeSet;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IntegrationCandidateStatus {
    Ready,
    Conflict,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IntegrationCandidate {
    pub task_id: String,
    pub change_set: WorkerChangeSet,
    pub status: IntegrationCandidateStatus,
    pub requires_review: bool,
    pub reason: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IntegrationReviewDecision {
    Approve,
    Reject,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IntegrationReviewOutcome {
    Approved,
    Rejected,
    Conflict,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IntegrationReviewReceipt {
    pub task_id: String,
    pub change_set_id: String,
    pub outcome: IntegrationReviewOutcome,
    pub reason: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IntegrationError {
    InvalidChange,
    EmptyTargetRevision,
}

pub struct IntegrationPlan {
    candidates: Vec<IntegrationCandidate>,
    by_task_id: BTreeMap<String, usize>,
}

impl IntegrationPlan {
    pub fn empty() -> Self {
        Self {
            candidates: Vec::new(),
            by_task_id: BTreeMap::new(),
        }
    }

    pub fn from_changes(
        target_revision: &str,
        changes: &BTreeMap<String, WorkerChangeSet>,
    ) -> Result<Self, IntegrationError> {
        if target_revision.trim().is_empty() {
            return Err(IntegrationError::EmptyTargetRevision);
        }
        let mut accepted_scopes = BTreeSet::<String>::new();
        let mut candidates = Vec::with_capacity(changes.len());
        let mut by_task_id = BTreeMap::new();
        for (task_id, change_set) in changes {
            let stale = change_set.base_revision != target_revision;
            let overlap = change_set.resources.iter().any(|resource| {
                accepted_scopes
                    .iter()
                    .any(|accepted| ownership_scopes_overlap(resource, accepted))
            });
            let conflict = stale || overlap;
            let reason = if stale {
                "Worker base revision differs from the integration target."
            } else if overlap {
                "Worker change overlaps an earlier integration candidate."
            } else {
                ""
            };
            let index = candidates.len();
            by_task_id.insert(task_id.clone(), index);
            candidates.push(IntegrationCandidate {
                task_id: task_id.clone(),
                change_set: change_set.clone(),
                status: if conflict {
                    IntegrationCandidateStatus::Conflict
                } else {
                    IntegrationCandidateStatus::Ready
                },
                requires_review: true,
                reason: reason.to_owned(),
            });
            if !conflict {
                accepted_scopes.extend(change_set.resources.iter().cloned());
            }
        }
        Ok(Self {
            candidates,
            by_task_id,
        })
    }

    pub fn candidates(&self) -> &[IntegrationCandidate] {
        &self.candidates
    }

    pub fn review(
        &self,
        task_id: &str,
        decision: IntegrationReviewDecision,
    ) -> IntegrationReviewReceipt {
        let Some(index) = self.by_task_id.get(task_id) else {
            return IntegrationReviewReceipt {
                task_id: task_id.to_owned(),
                change_set_id: String::new(),
                outcome: IntegrationReviewOutcome::Conflict,
                reason: "Integration candidate is unavailable.".to_owned(),
            };
        };
        let candidate = &self.candidates[*index];
        if candidate.status == IntegrationCandidateStatus::Conflict {
            return IntegrationReviewReceipt {
                task_id: task_id.to_owned(),
                change_set_id: candidate.change_set.id.clone(),
                outcome: IntegrationReviewOutcome::Conflict,
                reason: candidate.reason.clone(),
            };
        }
        let (outcome, reason) = match decision {
            IntegrationReviewDecision::Approve => (
                IntegrationReviewOutcome::Approved,
                "Approved for an outer integration adapter.",
            ),
            IntegrationReviewDecision::Reject => (
                IntegrationReviewOutcome::Rejected,
                "Reviewer rejected the candidate.",
            ),
        };
        IntegrationReviewReceipt {
            task_id: task_id.to_owned(),
            change_set_id: candidate.change_set.id.clone(),
            outcome,
            reason: reason.to_owned(),
        }
    }
}
