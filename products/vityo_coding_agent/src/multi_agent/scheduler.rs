//! Bounded, cancellation-aware scheduling of isolated worker tasks.

use std::{
    collections::{BTreeMap, HashSet},
    panic::AssertUnwindSafe,
    sync::{Arc, Mutex},
};

use futures::{FutureExt, StreamExt, stream::FuturesUnordered};
use serde_json::json;
use tokio::task::JoinHandle;

use crate::{
    cancellation::AgentCancellationToken,
    contracts::{AgentError, AgentErrorCode},
    sessions::{
        SessionAppendOutcome, SessionCorrelation, SessionEventDraft, SessionEventKind,
        SessionEventStore,
    },
};

use super::{
    integration_plan::{IntegrationCandidate, IntegrationError, IntegrationPlan},
    resource_lease::{LeaseDecision, ResourceLeaseRegistry, ResourceLeaseToken},
    task_graph::{DelegatedTask, TaskGraph, TaskGraphError, ownership_scope_contains},
    worktree::{
        DelegatedWorker, WorkerRequest, WorkerResult, WorkerResultStatus, WorktreeCleanupReceipt,
        WorktreeHandle, WorktreeProvider,
    },
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DelegationBudget {
    pub max_tasks: usize,
    pub max_concurrency: usize,
    pub max_operations_per_worker: usize,
}

impl DelegationBudget {
    pub fn is_valid(self) -> bool {
        self.max_tasks > 0 && self.max_concurrency > 0 && self.max_operations_per_worker > 0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DelegationStatus {
    Completed,
    Blocked,
    Cancelled,
}

pub struct DelegationOutcome {
    pub status: DelegationStatus,
    pub ordered_results: Vec<WorkerResult>,
    pub cleanup_receipts: Vec<WorktreeCleanupReceipt>,
    pub integration_plan: IntegrationPlan,
    pub max_observed_concurrency: usize,
    pub blockers: Vec<String>,
}

pub struct AgentScheduler {
    worker: Arc<dyn DelegatedWorker>,
    worktrees: Arc<dyn WorktreeProvider>,
    leases: Arc<ResourceLeaseRegistry>,
    session_events: Arc<dyn SessionEventStore>,
}

impl AgentScheduler {
    pub fn new(
        worker: Arc<dyn DelegatedWorker>,
        worktrees: Arc<dyn WorktreeProvider>,
        leases: Arc<ResourceLeaseRegistry>,
        session_events: Arc<dyn SessionEventStore>,
    ) -> Self {
        Self {
            worker,
            worktrees,
            leases,
            session_events,
        }
    }

    pub async fn run(
        &self,
        graph: &TaskGraph,
        budget: DelegationBudget,
        base_revision: &str,
        cancellation: AgentCancellationToken,
    ) -> DelegationOutcome {
        let mut schedule = graph.create_schedule();
        let mut results = BTreeMap::<String, WorkerResult>::new();
        let mut cleanups = Vec::new();
        let mut blockers = Vec::new();
        let issued_worktree_ids = Arc::new(Mutex::new(HashSet::new()));
        let mut running = FuturesUnordered::<JoinHandle<TaskExecution>>::new();
        let mut max_observed_concurrency = 0;

        if !budget.is_valid()
            || base_revision.trim().is_empty()
            || graph.len() > budget.max_tasks
            || graph
                .tasks()
                .any(|task| task.scope.max_operations > budget.max_operations_per_worker)
        {
            blockers.push("delegationBudgetExceeded".to_owned());
        } else {
            let mut cancellation_observed = cancellation.is_cancelled();
            loop {
                if !cancellation_observed && !cancellation.is_cancelled() {
                    for task in schedule.ready().cloned().collect::<Vec<_>>() {
                        if running.len() >= budget.max_concurrency {
                            break;
                        }
                        match self
                            .leases
                            .acquire(task.id.clone(), task.owned_resources.iter().cloned())
                        {
                            LeaseDecision::Contended(_) => continue,
                            LeaseDecision::Invalid => {
                                let _ = schedule.mark_started(&task.id);
                                results.insert(
                                    task.id.clone(),
                                    WorkerResult::failed(task.id, "resourceLeaseRejected"),
                                );
                                blockers.push("resourceLeaseRejected".to_owned());
                            }
                            LeaseDecision::Granted(lease) => {
                                if schedule.mark_started(&task.id).is_err() {
                                    let _ = self.leases.release(&lease);
                                    blockers.push("taskScheduleStateInvalid".to_owned());
                                    continue;
                                }
                                running.push(tokio::spawn(execute_task(
                                    task,
                                    lease,
                                    base_revision.to_owned(),
                                    cancellation.clone(),
                                    Arc::clone(&self.worker),
                                    Arc::clone(&self.worktrees),
                                    Arc::clone(&self.leases),
                                    Arc::clone(&self.session_events),
                                    Arc::clone(&issued_worktree_ids),
                                )));
                                max_observed_concurrency =
                                    max_observed_concurrency.max(running.len());
                            }
                        }
                    }
                }

                if running.is_empty() {
                    if cancellation_observed || cancellation.is_cancelled() {
                        break;
                    }
                    if results.len() == graph.len() {
                        break;
                    }
                    blockers.push(if schedule.has_ready() {
                        "resourceLeaseContended".to_owned()
                    } else {
                        "dependencyBlocked".to_owned()
                    });
                    break;
                }

                let next = if cancellation_observed {
                    running.next().await
                } else {
                    tokio::select! {
                        _ = cancellation.cancelled() => {
                            cancellation_observed = true;
                            continue;
                        }
                        next = running.next() => next,
                    }
                };
                let Some(joined) = next else {
                    break;
                };
                let execution = match joined {
                    Ok(execution) => execution,
                    Err(_) => {
                        blockers.push("workerTaskPanicked".to_owned());
                        continue;
                    }
                };
                let task_id = execution.result.task_id.clone();
                if let Some(cleanup) = execution.cleanup {
                    if !cleanup.cleaned {
                        blockers.push("worktreeCleanupIncomplete".to_owned());
                    }
                    cleanups.push(cleanup);
                }
                if execution.result.status == WorkerResultStatus::Completed {
                    if schedule.mark_completed(&task_id).is_err() {
                        blockers.push("taskScheduleStateInvalid".to_owned());
                    }
                } else if execution.result.status == WorkerResultStatus::Failed {
                    blockers.push("workerFailed".to_owned());
                }
                results.insert(task_id, execution.result);
            }
        }

        let completed = results
            .values()
            .filter(|result| result.status == WorkerResultStatus::Completed)
            .count();
        let status = if cancellation.is_cancelled() {
            DelegationStatus::Cancelled
        } else if completed == graph.len() && blockers.is_empty() {
            DelegationStatus::Completed
        } else {
            DelegationStatus::Blocked
        };
        blockers.sort();
        blockers.dedup();
        cleanups.sort_by(|left, right| left.worktree_id.cmp(&right.worktree_id));
        let ordered_results = results.into_values().collect::<Vec<_>>();
        let changes = ordered_results
            .iter()
            .filter_map(|result| {
                (result.status == WorkerResultStatus::Completed)
                    .then(|| {
                        result
                            .change_set
                            .clone()
                            .map(|change| (result.task_id.clone(), change))
                    })
                    .flatten()
            })
            .collect::<BTreeMap<_, _>>();
        let integration_plan = IntegrationPlan::from_changes(base_revision, &changes)
            .unwrap_or_else(|_| IntegrationPlan::empty());
        DelegationOutcome {
            status,
            ordered_results,
            cleanup_receipts: cleanups,
            integration_plan,
            max_observed_concurrency,
            blockers,
        }
    }
}

struct TaskExecution {
    result: WorkerResult,
    cleanup: Option<WorktreeCleanupReceipt>,
}

#[allow(clippy::too_many_arguments)]
async fn execute_task(
    task: DelegatedTask,
    lease: ResourceLeaseToken,
    base_revision: String,
    cancellation: AgentCancellationToken,
    worker: Arc<dyn DelegatedWorker>,
    worktrees: Arc<dyn WorktreeProvider>,
    leases: Arc<ResourceLeaseRegistry>,
    session_events: Arc<dyn SessionEventStore>,
    issued_worktree_ids: Arc<Mutex<HashSet<String>>>,
) -> TaskExecution {
    let mut handle = None;
    let result = if cancellation.is_cancelled() {
        WorkerResult::cancelled(task.id.clone())
    } else {
        let created = AssertUnwindSafe(worktrees.create(
            &task.id,
            &base_revision,
            &task.owned_resources,
            cancellation.clone(),
        ))
        .catch_unwind()
        .await;
        match created {
            Ok(Ok(created)) => {
                let unique = issued_worktree_ids
                    .lock()
                    .map(|mut ids| ids.insert(created.id.clone()))
                    .unwrap_or(false);
                if !unique {
                    // A colliding identifier may refer to another live task's
                    // worktree. Do not dispose that shared handle here.
                    WorkerResult::failed(task.id.clone(), "duplicateWorktreeId")
                } else if !created.is_valid_for(&task, &base_revision) {
                    handle = Some(created);
                    WorkerResult::failed(task.id.clone(), "invalidWorktree")
                } else {
                    handle = Some(created.clone());
                    run_worker_task(
                        task.clone(),
                        created,
                        base_revision,
                        cancellation,
                        worker,
                        session_events,
                    )
                    .await
                }
            }
            Ok(Err(_)) => WorkerResult::failed(task.id.clone(), "worktreeUnavailable"),
            Err(_) => WorkerResult::failed(task.id.clone(), "worktreeProviderPanicked"),
        }
    };
    let cleanup = if let Some(handle) = handle {
        let disposed = AssertUnwindSafe(worktrees.dispose(&handle))
            .catch_unwind()
            .await;
        Some(match disposed {
            Ok(Ok(receipt)) if receipt.worktree_id == handle.id => receipt,
            _ => WorktreeCleanupReceipt {
                worktree_id: handle.id,
                cleaned: false,
            },
        })
    } else {
        None
    };
    let _ = leases.release(&lease);
    TaskExecution { result, cleanup }
}

async fn run_worker_task(
    task: DelegatedTask,
    worktree: WorktreeHandle,
    base_revision: String,
    cancellation: AgentCancellationToken,
    worker: Arc<dyn DelegatedWorker>,
    session_events: Arc<dyn SessionEventStore>,
) -> WorkerResult {
    let session_id = format!("worker:{base_revision}:{}:{}", task.id, worktree.id);
    if !record_worker_event(
        session_events.as_ref(),
        &session_id,
        &task.id,
        SessionEventKind::GoalRecorded,
        json!({ "state": "delegated" }),
    )
    .await
    {
        return WorkerResult::failed(task.id.clone(), "workerSessionUnavailable");
    }
    if cancellation.is_cancelled() {
        let _ = record_worker_event(
            session_events.as_ref(),
            &session_id,
            &task.id,
            SessionEventKind::TerminalRecorded,
            json!({ "state": "cancelled" }),
        )
        .await;
        return WorkerResult::cancelled(task.id);
    }
    let request = WorkerRequest {
        task: task.clone(),
        scope: task.scope.clone(),
        worktree,
        session_id: session_id.clone(),
        cancellation,
    };
    let result = match AssertUnwindSafe(worker.run(request)).catch_unwind().await {
        Ok(Ok(result)) => validate_worker_result(&task, &base_revision, result),
        Ok(Err(_)) => WorkerResult::failed(task.id.clone(), "workerCapabilityUnavailable"),
        Err(_) => WorkerResult::failed(task.id.clone(), "workerPanicked"),
    };
    let terminal_recorded = record_worker_event(
        session_events.as_ref(),
        &session_id,
        &task.id,
        SessionEventKind::TerminalRecorded,
        json!({ "state": result.status.as_str() }),
    )
    .await;
    if terminal_recorded {
        result
    } else {
        WorkerResult::failed(task.id.clone(), "workerSessionUnavailable")
    }
}

async fn record_worker_event(
    store: &dyn SessionEventStore,
    session_id: &str,
    task_id: &str,
    kind: SessionEventKind,
    payload: serde_json::Value,
) -> bool {
    let snapshot = match store.load(session_id, 0, 1).await {
        Ok(snapshot) if !snapshot.corrupted_tail => snapshot,
        _ => return false,
    };
    let Ok(draft) = SessionEventDraft::new(
        kind,
        SessionCorrelation::new(task_id, session_id),
        super::utc_now_rfc3339(),
        payload,
    ) else {
        return false;
    };
    matches!(
        store
            .append(session_id, snapshot.current_sequence, &[draft])
            .await,
        Ok(result) if result.outcome == SessionAppendOutcome::Committed
    )
}

fn validate_worker_result(
    task: &DelegatedTask,
    base_revision: &str,
    result: WorkerResult,
) -> WorkerResult {
    if result.task_id != task.id {
        return WorkerResult::failed(task.id.clone(), "workerCorrelationMismatch");
    }
    if result.status != WorkerResultStatus::Completed {
        return result;
    }
    let Some(change) = &result.change_set else {
        return WorkerResult::failed(task.id.clone(), "workerScopeExceeded");
    };
    if change.id.trim().is_empty() || change.base_revision != base_revision {
        return WorkerResult::failed(task.id.clone(), "workerBaseRevisionMismatch");
    }
    if change.resources.len() > task.scope.max_operations
        || change.resources.is_empty()
        || change.resources.iter().any(|resource| {
            !crate::multi_agent::task_graph::is_normalized_ownership(resource)
                || !task
                    .owned_resources
                    .iter()
                    .any(|owner| ownership_scope_contains(owner, resource))
        })
        || result.evidence_receipts.len() > task.scope.max_operations
        || result
            .evidence_receipts
            .iter()
            .any(|receipt| receipt.trim().is_empty())
    {
        return WorkerResult::failed(task.id.clone(), "workerScopeExceeded");
    }
    result
}

impl WorkerResultStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }
}

impl DelegationOutcome {
    pub fn candidate(&self, task_id: &str) -> Option<&IntegrationCandidate> {
        self.integration_plan
            .candidates()
            .iter()
            .find(|candidate| candidate.task_id == task_id)
    }
}

pub fn graph_error(error: TaskGraphError) -> AgentError {
    AgentError::new(
        AgentErrorCode::InvalidRequest,
        match error {
            TaskGraphError::Cycle => "taskGraphCycle",
            TaskGraphError::MissingPrerequisite => "taskGraphInvalidPrerequisite",
            _ => "taskGraphInvalid",
        },
    )
}

pub fn integration_error(error: IntegrationError) -> AgentError {
    AgentError::new(
        AgentErrorCode::InvalidRequest,
        match error {
            IntegrationError::EmptyTargetRevision => "integrationTargetMissing",
            IntegrationError::InvalidChange => "integrationChangeInvalid",
        },
    )
}
