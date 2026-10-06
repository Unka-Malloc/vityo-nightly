use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    fs,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};

use tokio::sync::{Barrier, Notify};
use vityo_coding_agent::{
    cancellation::AgentCancellationToken,
    contracts::{AgentError, AgentErrorCode},
    multi_agent::{
        AgentScheduler, DelegatedTask, DelegatedWorker, DelegationBudget, DelegationStatus,
        IntegrationCandidateStatus, IntegrationPlan, IntegrationReviewDecision,
        IntegrationReviewOutcome, LeaseDecision, ResourceLeaseRegistry, TaskGraph, TaskGraphError,
        WorkerChangeSet, WorkerRequest, WorkerResult, WorkerResultStatus, WorkerScope,
        WorktreeCleanupReceipt, WorktreeHandle, WorktreeProvider, is_normalized_ownership,
        ownership_scope_contains, ownership_scopes_overlap,
    },
    sessions::{InMemorySessionEventStore, SessionEventStore},
};

#[test]
fn graph_has_a_sorted_incremental_ready_queue_and_rejects_cycles() {
    let graph = TaskGraph::new([
        task("30-after", ["20-first"], ["lib/c.dart"]),
        task("20-first", [], ["lib/a.dart"]),
        task("10-independent", [], ["lib/b.dart"]),
    ])
    .unwrap();
    let mut schedule = graph.create_schedule();
    assert_eq!(
        schedule
            .ready()
            .map(|task| task.id.as_str())
            .collect::<Vec<_>>(),
        ["10-independent", "20-first"]
    );
    schedule.mark_started("20-first").unwrap();
    schedule.mark_completed("20-first").unwrap();
    assert_eq!(
        schedule
            .ready()
            .map(|task| task.id.as_str())
            .collect::<Vec<_>>(),
        ["10-independent", "30-after"]
    );
    assert_eq!(
        schedule.mark_completed("20-first"),
        Err(TaskGraphError::InvalidStateTransition)
    );

    let cycle = TaskGraph::new([
        task("one", ["two"], ["lib/a.dart"]),
        task("two", ["one"], ["lib/b.dart"]),
    ]);
    assert!(matches!(cycle, Err(TaskGraphError::Cycle)));
    assert!(TaskGraph::new([task("self", ["self"], ["lib/a.dart"])]).is_err());
    assert!(!is_normalized_ownership("../outside"));
    assert!(ownership_scope_contains(
        "lib/feature",
        "lib/feature/main.dart"
    ));
    assert!(!ownership_scope_contains(
        "lib/feature/main.dart",
        "lib/feature"
    ));
    assert!(ownership_scopes_overlap(
        "lib/feature",
        "lib/feature/main.dart"
    ));
}

#[test]
fn resource_leases_find_hierarchical_conflicts_and_release_exactly_once() {
    let registry = ResourceLeaseRegistry::default();
    let parent = match registry.acquire("parent", ["lib/feature".to_owned()]) {
        LeaseDecision::Granted(token) => token,
        other => panic!("expected grant, got {other:?}"),
    };
    let child = registry.acquire("child", ["lib/feature/main.dart".to_owned()]);
    assert_eq!(
        child,
        LeaseDecision::Contended(BTreeSet::from(["parent".to_owned()]))
    );
    let independent = registry.acquire("independent", ["lib/other.dart".to_owned()]);
    assert!(matches!(independent, LeaseDecision::Granted(_)));
    assert_eq!(registry.active_lease_count(), 2);
    assert!(registry.release(&parent));
    assert!(!registry.release(&parent));
    assert!(matches!(
        registry.acquire("child", ["lib/feature/main.dart".to_owned()]),
        LeaseDecision::Granted(_)
    ));
    assert_eq!(
        registry.acquire("invalid", ["/absolute/path".to_owned()]),
        LeaseDecision::Invalid
    );
}

#[test]
fn integration_plans_require_review_and_preserve_stale_and_overlap_conflicts() {
    let changes = BTreeMap::from([
        (
            "a-clean".to_owned(),
            change("clean", "base", ["lib/a.dart"]),
        ),
        (
            "b-overlap".to_owned(),
            change("overlap", "base", ["lib/a.dart/child"]),
        ),
        ("c-stale".to_owned(), change("stale", "old", ["lib/c.dart"])),
    ]);
    let plan = IntegrationPlan::from_changes("base", &changes).unwrap();
    assert_eq!(plan.candidates().len(), 3);
    assert!(
        plan.candidates()
            .iter()
            .all(|candidate| candidate.requires_review)
    );
    assert_eq!(
        plan.candidates()[0].status,
        IntegrationCandidateStatus::Ready
    );
    assert_eq!(
        plan.candidates()[1].status,
        IntegrationCandidateStatus::Conflict
    );
    assert_eq!(
        plan.review("a-clean", IntegrationReviewDecision::Approve)
            .outcome,
        IntegrationReviewOutcome::Approved
    );
    assert_eq!(
        plan.review("b-overlap", IntegrationReviewDecision::Approve)
            .outcome,
        IntegrationReviewOutcome::Conflict
    );
    assert_eq!(
        plan.review("c-stale", IntegrationReviewDecision::Reject)
            .outcome,
        IntegrationReviewOutcome::Conflict
    );
}

#[tokio::test]
async fn scheduler_runs_scoped_workers_in_parallel_and_cleans_their_worktrees() {
    let root = tempfile::tempdir().unwrap();
    let worktrees = Arc::new(DirectoryWorktrees::new(root.path().to_owned()));
    let worker = Arc::new(ParallelWorker::new(Arc::clone(&worktrees), 2));
    let sessions = Arc::new(InMemorySessionEventStore::default());
    let scheduler = AgentScheduler::new(
        worker.clone(),
        worktrees.clone(),
        Arc::new(ResourceLeaseRegistry::default()),
        sessions.clone(),
    );
    let graph = TaskGraph::new([
        task("first", [], ["lib/first.dart"]),
        task("second", [], ["lib/second.dart"]),
    ])
    .unwrap();

    let outcome = scheduler
        .run(
            &graph,
            DelegationBudget {
                max_tasks: 2,
                max_concurrency: 2,
                max_operations_per_worker: 2,
            },
            "base",
            AgentCancellationToken::new(),
        )
        .await;

    assert_eq!(outcome.status, DelegationStatus::Completed);
    assert_eq!(outcome.max_observed_concurrency, 2);
    assert_eq!(worker.maximum.load(Ordering::SeqCst), 2);
    assert_eq!(outcome.ordered_results.len(), 2);
    assert!(
        outcome
            .cleanup_receipts
            .iter()
            .all(|receipt| receipt.cleaned)
    );
    assert!(worktrees.active.lock().unwrap().is_empty());
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
    assert!(
        outcome
            .integration_plan
            .candidates()
            .iter()
            .all(|candidate| candidate.requires_review)
    );
    let session_ids = worker.sessions.lock().unwrap().clone();
    for session_id in &session_ids {
        let events = sessions.load(session_id, 0, 4).await.unwrap();
        assert_eq!(events.current_sequence, 2);
    }
}

#[tokio::test]
async fn duplicate_worktree_ids_do_not_dispose_another_workers_workspace() {
    let worktrees = Arc::new(DuplicateWorktrees::new());
    let scheduler = AgentScheduler::new(
        Arc::new(ImmediateWorker),
        worktrees.clone(),
        Arc::new(ResourceLeaseRegistry::default()),
        Arc::new(InMemorySessionEventStore::default()),
    );
    let graph = TaskGraph::new([
        task("first", [], ["lib/first.dart"]),
        task("second", [], ["lib/second.dart"]),
    ])
    .unwrap();

    let outcome = scheduler
        .run(
            &graph,
            DelegationBudget {
                max_tasks: 2,
                max_concurrency: 2,
                max_operations_per_worker: 1,
            },
            "base",
            AgentCancellationToken::new(),
        )
        .await;

    assert_eq!(outcome.status, DelegationStatus::Blocked);
    assert_eq!(
        outcome
            .ordered_results
            .iter()
            .filter(|result| result.failure == Some("duplicateWorktreeId"))
            .count(),
        1
    );
    assert_eq!(outcome.cleanup_receipts.len(), 1);
    assert!(outcome.cleanup_receipts[0].cleaned);
    assert_eq!(worktrees.disposals.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn cancellation_stops_new_workers_and_waits_for_the_running_worker() {
    let root = tempfile::tempdir().unwrap();
    let worktrees = Arc::new(DirectoryWorktrees::new(root.path().to_owned()));
    let started = Arc::new(Notify::new());
    let worker = Arc::new(CancellationWorker {
        started: Arc::clone(&started),
    });
    let sessions = Arc::new(InMemorySessionEventStore::default());
    let leases = Arc::new(ResourceLeaseRegistry::default());
    let scheduler = Arc::new(AgentScheduler::new(
        worker,
        worktrees.clone(),
        Arc::clone(&leases),
        sessions,
    ));
    let graph = TaskGraph::new([
        task("first", [], ["lib/first.dart"]),
        task("second", [], ["lib/second.dart"]),
    ])
    .unwrap();
    let cancellation = AgentCancellationToken::new();
    let notified = started.notified();
    let run_cancellation = cancellation.clone();
    let run = tokio::spawn(async move {
        scheduler
            .run(
                &graph,
                DelegationBudget {
                    max_tasks: 2,
                    max_concurrency: 1,
                    max_operations_per_worker: 2,
                },
                "base",
                run_cancellation,
            )
            .await
    });
    notified.await;
    cancellation.cancel();
    let outcome = run.await.unwrap();

    assert_eq!(outcome.status, DelegationStatus::Cancelled);
    assert_eq!(outcome.ordered_results.len(), 1);
    assert_eq!(
        outcome.ordered_results[0].status,
        WorkerResultStatus::Cancelled
    );
    assert_eq!(outcome.cleanup_receipts.len(), 1);
    assert!(outcome.cleanup_receipts[0].cleaned);
    assert!(worktrees.active.lock().unwrap().is_empty());
    assert_eq!(leases.active_lease_count(), 0);
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
}

#[tokio::test]
async fn external_resource_contention_blocks_without_creating_a_worktree() {
    let root = tempfile::tempdir().unwrap();
    let worktrees = Arc::new(DirectoryWorktrees::new(root.path().to_owned()));
    let leases = Arc::new(ResourceLeaseRegistry::default());
    let held = match leases.acquire("external", ["lib/feature".to_owned()]) {
        LeaseDecision::Granted(token) => token,
        _ => panic!("fixture lease should be granted"),
    };
    let scheduler = AgentScheduler::new(
        Arc::new(ParallelWorker::new(Arc::clone(&worktrees), 1)),
        worktrees.clone(),
        Arc::clone(&leases),
        Arc::new(InMemorySessionEventStore::default()),
    );
    let graph = TaskGraph::new([task("blocked", [], ["lib/feature/file.dart"])]).unwrap();
    let outcome = scheduler
        .run(
            &graph,
            DelegationBudget {
                max_tasks: 1,
                max_concurrency: 1,
                max_operations_per_worker: 1,
            },
            "base",
            AgentCancellationToken::new(),
        )
        .await;
    assert_eq!(outcome.status, DelegationStatus::Blocked);
    assert!(outcome.ordered_results.is_empty());
    assert!(
        outcome
            .blockers
            .contains(&"resourceLeaseContended".to_owned())
    );
    assert!(worktrees.active.lock().unwrap().is_empty());
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
    assert!(leases.release(&held));
}

#[tokio::test]
async fn worker_scope_violation_fails_instead_of_entering_the_integration_plan() {
    let root = tempfile::tempdir().unwrap();
    let worktrees = Arc::new(DirectoryWorktrees::new(root.path().to_owned()));
    let worker = Arc::new(OutOfScopeWorker {
        worktrees: Arc::clone(&worktrees),
    });
    let scheduler = AgentScheduler::new(
        worker,
        worktrees.clone(),
        Arc::new(ResourceLeaseRegistry::default()),
        Arc::new(InMemorySessionEventStore::default()),
    );
    let graph = TaskGraph::new([task("bad", [], ["lib/safe.dart"])]).unwrap();
    let outcome = scheduler
        .run(
            &graph,
            DelegationBudget {
                max_tasks: 1,
                max_concurrency: 1,
                max_operations_per_worker: 1,
            },
            "base",
            AgentCancellationToken::new(),
        )
        .await;
    assert_eq!(outcome.status, DelegationStatus::Blocked);
    assert_eq!(
        outcome.ordered_results[0].failure,
        Some("workerScopeExceeded")
    );
    assert!(outcome.integration_plan.candidates().is_empty());
    assert!(outcome.cleanup_receipts[0].cleaned);
}

fn task(
    id: &str,
    prerequisites: impl IntoIterator<Item = &'static str>,
    resources: impl IntoIterator<Item = &'static str>,
) -> DelegatedTask {
    DelegatedTask::new(
        id,
        id,
        prerequisites.into_iter().map(str::to_owned),
        resources.into_iter().map(str::to_owned),
        WorkerScope::new([format!("context-{id}")], [format!("tool-{id}")], 1).unwrap(),
    )
    .unwrap()
}

fn change(
    id: &str,
    base: &str,
    resources: impl IntoIterator<Item = &'static str>,
) -> WorkerChangeSet {
    WorkerChangeSet::new(id, base, resources.into_iter().map(str::to_owned)).unwrap()
}

struct DirectoryWorktrees {
    root: PathBuf,
    active: Mutex<HashMap<String, PathBuf>>,
    next_id: AtomicUsize,
}

impl DirectoryWorktrees {
    fn new(root: PathBuf) -> Self {
        Self {
            root,
            active: Mutex::new(HashMap::new()),
            next_id: AtomicUsize::new(0),
        }
    }

    fn directory_for(&self, handle: &WorktreeHandle) -> Option<PathBuf> {
        self.active.lock().unwrap().get(&handle.id).cloned()
    }
}

#[async_trait::async_trait]
impl WorktreeProvider for DirectoryWorktrees {
    async fn create(
        &self,
        task_id: &str,
        base_revision: &str,
        owned_resources: &BTreeSet<String>,
        cancellation: AgentCancellationToken,
    ) -> Result<WorktreeHandle, AgentError> {
        if cancellation.is_cancelled() {
            return Err(AgentError::new(AgentErrorCode::Cancelled, "cancelled"));
        }
        let id = format!("worker-{}", self.next_id.fetch_add(1, Ordering::SeqCst));
        let path = self.root.join(&id);
        fs::create_dir(&path).map_err(|_| {
            AgentError::new(
                AgentErrorCode::CapabilityUnavailable,
                "worktree create failed",
            )
        })?;
        self.active.lock().unwrap().insert(id.clone(), path);
        Ok(WorktreeHandle::new(
            id,
            task_id,
            base_revision,
            owned_resources.iter().cloned(),
        ))
    }

    async fn dispose(&self, handle: &WorktreeHandle) -> Result<WorktreeCleanupReceipt, AgentError> {
        let path = self.active.lock().unwrap().remove(&handle.id);
        let cleaned = path.is_some_and(|path| fs::remove_dir_all(path).is_ok());
        Ok(WorktreeCleanupReceipt {
            worktree_id: handle.id.clone(),
            cleaned,
        })
    }
}

struct ParallelWorker {
    worktrees: Arc<DirectoryWorktrees>,
    barrier: Barrier,
    active: AtomicUsize,
    maximum: AtomicUsize,
    sessions: Mutex<Vec<String>>,
}

impl ParallelWorker {
    fn new(worktrees: Arc<DirectoryWorktrees>, parties: usize) -> Self {
        Self {
            worktrees,
            barrier: Barrier::new(parties),
            active: AtomicUsize::new(0),
            maximum: AtomicUsize::new(0),
            sessions: Mutex::new(Vec::new()),
        }
    }
}

#[async_trait::async_trait]
impl DelegatedWorker for ParallelWorker {
    async fn run(&self, request: WorkerRequest) -> Result<WorkerResult, AgentError> {
        self.sessions
            .lock()
            .unwrap()
            .push(request.session_id.clone());
        let active = self.active.fetch_add(1, Ordering::SeqCst) + 1;
        self.maximum.fetch_max(active, Ordering::SeqCst);
        let directory = self.worktrees.directory_for(&request.worktree).unwrap();
        fs::write(directory.join("change.txt"), &request.task.id).unwrap();
        self.barrier.wait().await;
        assert_eq!(
            fs::read_to_string(directory.join("change.txt")).unwrap(),
            request.task.id
        );
        self.active.fetch_sub(1, Ordering::SeqCst);
        Ok(WorkerResult::completed(
            request.task.id.clone(),
            WorkerChangeSet::new(
                format!("change-{}", request.task.id),
                request.worktree.base_revision.clone(),
                request.task.owned_resources.iter().cloned(),
            )
            .unwrap(),
            [format!("evidence-{}", request.task.id)],
        ))
    }
}

struct CancellationWorker {
    started: Arc<Notify>,
}

struct DuplicateWorktrees {
    create_barrier: Barrier,
    disposals: AtomicUsize,
}

impl DuplicateWorktrees {
    fn new() -> Self {
        Self {
            create_barrier: Barrier::new(2),
            disposals: AtomicUsize::new(0),
        }
    }
}

#[async_trait::async_trait]
impl WorktreeProvider for DuplicateWorktrees {
    async fn create(
        &self,
        task_id: &str,
        base_revision: &str,
        owned_resources: &BTreeSet<String>,
        _cancellation: AgentCancellationToken,
    ) -> Result<WorktreeHandle, AgentError> {
        self.create_barrier.wait().await;
        Ok(WorktreeHandle::new(
            "shared-worktree",
            task_id,
            base_revision,
            owned_resources.iter().cloned(),
        ))
    }

    async fn dispose(&self, handle: &WorktreeHandle) -> Result<WorktreeCleanupReceipt, AgentError> {
        self.disposals.fetch_add(1, Ordering::SeqCst);
        Ok(WorktreeCleanupReceipt {
            worktree_id: handle.id.clone(),
            cleaned: true,
        })
    }
}

struct ImmediateWorker;

#[async_trait::async_trait]
impl DelegatedWorker for ImmediateWorker {
    async fn run(&self, request: WorkerRequest) -> Result<WorkerResult, AgentError> {
        Ok(WorkerResult::completed(
            request.task.id.clone(),
            WorkerChangeSet::new(
                format!("change-{}", request.task.id),
                request.worktree.base_revision,
                request.task.owned_resources.iter().cloned(),
            )
            .unwrap(),
            [format!("evidence-{}", request.task.id)],
        ))
    }
}

#[async_trait::async_trait]
impl DelegatedWorker for CancellationWorker {
    async fn run(&self, request: WorkerRequest) -> Result<WorkerResult, AgentError> {
        self.started.notify_one();
        request.cancellation.cancelled().await;
        Ok(WorkerResult::cancelled(request.task.id))
    }
}

struct OutOfScopeWorker {
    worktrees: Arc<DirectoryWorktrees>,
}

#[async_trait::async_trait]
impl DelegatedWorker for OutOfScopeWorker {
    async fn run(&self, request: WorkerRequest) -> Result<WorkerResult, AgentError> {
        let _ = self.worktrees.directory_for(&request.worktree).unwrap();
        Ok(WorkerResult::completed(
            request.task.id.clone(),
            WorkerChangeSet::new(
                "escape",
                request.worktree.base_revision,
                ["../../outside".to_owned()],
            )
            .unwrap(),
            ["receipt".to_owned()],
        ))
    }
}
