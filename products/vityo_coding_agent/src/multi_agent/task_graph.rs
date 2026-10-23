//! Validated task dependencies and an incrementally maintained ready queue.

use std::collections::{BTreeMap, BTreeSet, HashSet};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkerScope {
    pub context_evidence_ids: BTreeSet<String>,
    pub tool_ids: BTreeSet<String>,
    pub max_operations: usize,
}

impl WorkerScope {
    pub fn new(
        context_evidence_ids: impl IntoIterator<Item = String>,
        tool_ids: impl IntoIterator<Item = String>,
        max_operations: usize,
    ) -> Result<Self, TaskGraphError> {
        let scope = Self {
            context_evidence_ids: context_evidence_ids.into_iter().collect(),
            tool_ids: tool_ids.into_iter().collect(),
            max_operations,
        };
        if scope.max_operations == 0
            || scope
                .context_evidence_ids
                .iter()
                .chain(scope.tool_ids.iter())
                .any(|id| id.trim().is_empty())
        {
            return Err(TaskGraphError::InvalidScope);
        }
        Ok(scope)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DelegatedTask {
    pub id: String,
    pub title: String,
    pub prerequisites: BTreeSet<String>,
    pub owned_resources: BTreeSet<String>,
    pub scope: WorkerScope,
}

impl DelegatedTask {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        prerequisites: impl IntoIterator<Item = String>,
        owned_resources: impl IntoIterator<Item = String>,
        scope: WorkerScope,
    ) -> Result<Self, TaskGraphError> {
        let task = Self {
            id: id.into(),
            title: title.into(),
            prerequisites: prerequisites.into_iter().collect(),
            owned_resources: owned_resources.into_iter().collect(),
            scope,
        };
        if task.id.trim().is_empty()
            || task.title.trim().is_empty()
            || task.owned_resources.is_empty()
            || task
                .owned_resources
                .iter()
                .any(|resource| !is_normalized_ownership(resource))
        {
            return Err(TaskGraphError::InvalidTask);
        }
        Ok(task)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TaskGraphError {
    Empty,
    DuplicateTask,
    InvalidTask,
    InvalidScope,
    MissingPrerequisite,
    SelfDependency,
    Cycle,
    InvalidStateTransition,
}

pub struct TaskGraph {
    tasks: BTreeMap<String, DelegatedTask>,
    dependents: BTreeMap<String, Vec<String>>,
    prerequisite_counts: BTreeMap<String, usize>,
}

impl TaskGraph {
    pub fn new(tasks: impl IntoIterator<Item = DelegatedTask>) -> Result<Self, TaskGraphError> {
        let mut by_id = BTreeMap::new();
        for task in tasks {
            let id = task.id.clone();
            if by_id.insert(id, task).is_some() {
                return Err(TaskGraphError::DuplicateTask);
            }
        }
        if by_id.is_empty() {
            return Err(TaskGraphError::Empty);
        }
        let mut dependents = by_id
            .keys()
            .map(|id| (id.clone(), Vec::new()))
            .collect::<BTreeMap<_, _>>();
        let mut prerequisite_counts = BTreeMap::new();
        for task in by_id.values() {
            for prerequisite in &task.prerequisites {
                if prerequisite == &task.id {
                    return Err(TaskGraphError::SelfDependency);
                }
                let Some(children) = dependents.get_mut(prerequisite) else {
                    return Err(TaskGraphError::MissingPrerequisite);
                };
                children.push(task.id.clone());
            }
            prerequisite_counts.insert(task.id.clone(), task.prerequisites.len());
        }
        let graph = Self {
            tasks: by_id,
            dependents,
            prerequisite_counts,
        };
        if !graph.is_acyclic() {
            return Err(TaskGraphError::Cycle);
        }
        Ok(graph)
    }

    pub fn tasks(&self) -> impl Iterator<Item = &DelegatedTask> {
        self.tasks.values()
    }

    pub fn len(&self) -> usize {
        self.tasks.len()
    }

    pub fn is_empty(&self) -> bool {
        self.tasks.is_empty()
    }

    pub fn find(&self, id: &str) -> Option<&DelegatedTask> {
        self.tasks.get(id)
    }

    pub fn create_schedule(&self) -> TaskGraphSchedule<'_> {
        TaskGraphSchedule::new(self)
    }

    fn is_acyclic(&self) -> bool {
        let mut remaining = self.prerequisite_counts.clone();
        let mut ready = remaining
            .iter()
            .filter_map(|(id, count)| (*count == 0).then_some(id.clone()))
            .collect::<BTreeSet<_>>();
        let mut count = 0;
        while let Some(id) = ready.pop_first() {
            count += 1;
            for dependent in &self.dependents[&id] {
                let next = remaining
                    .get_mut(dependent)
                    .expect("dependent IDs are present in the graph");
                *next -= 1;
                if *next == 0 {
                    ready.insert(dependent.clone());
                }
            }
        }
        count == self.tasks.len()
    }
}

pub struct TaskGraphSchedule<'a> {
    graph: &'a TaskGraph,
    remaining_prerequisites: BTreeMap<String, usize>,
    ready: BTreeSet<String>,
    started: HashSet<String>,
    completed: HashSet<String>,
}

impl<'a> TaskGraphSchedule<'a> {
    fn new(graph: &'a TaskGraph) -> Self {
        let remaining_prerequisites = graph.prerequisite_counts.clone();
        let ready = remaining_prerequisites
            .iter()
            .filter_map(|(id, count)| (*count == 0).then_some(id.clone()))
            .collect();
        Self {
            graph,
            remaining_prerequisites,
            ready,
            started: HashSet::new(),
            completed: HashSet::new(),
        }
    }

    pub fn ready(&self) -> impl Iterator<Item = &DelegatedTask> {
        self.ready.iter().map(|id| &self.graph.tasks[id])
    }

    pub fn has_ready(&self) -> bool {
        !self.ready.is_empty()
    }

    pub fn is_started(&self, task_id: &str) -> bool {
        self.started.contains(task_id)
    }

    pub fn is_completed(&self, task_id: &str) -> bool {
        self.completed.contains(task_id)
    }

    pub fn mark_started(&mut self, task_id: &str) -> Result<(), TaskGraphError> {
        if !self.ready.remove(task_id) || !self.started.insert(task_id.to_owned()) {
            return Err(TaskGraphError::InvalidStateTransition);
        }
        Ok(())
    }

    pub fn mark_completed(&mut self, task_id: &str) -> Result<(), TaskGraphError> {
        if !self.started.contains(task_id) || !self.completed.insert(task_id.to_owned()) {
            return Err(TaskGraphError::InvalidStateTransition);
        }
        for dependent in &self.graph.dependents[task_id] {
            let remaining = self
                .remaining_prerequisites
                .get_mut(dependent)
                .expect("dependent IDs are present in the graph");
            *remaining -= 1;
            if *remaining == 0 && !self.started.contains(dependent) {
                self.ready.insert(dependent.clone());
            }
        }
        Ok(())
    }
}

pub fn is_normalized_ownership(resource: &str) -> bool {
    if resource.is_empty()
        || resource.trim() != resource
        || resource.starts_with('/')
        || resource.contains('\\')
        || resource.contains(':')
        || resource.contains('*')
        || resource.contains('?')
    {
        return false;
    }
    resource
        .split('/')
        .all(|segment| !segment.is_empty() && segment != "." && segment != "..")
}

pub fn ownership_scopes_overlap(left: &str, right: &str) -> bool {
    scope_contains(left, right) || scope_contains(right, left)
}

pub fn ownership_scope_contains(owner: &str, resource: &str) -> bool {
    scope_contains(owner, resource)
}

fn scope_contains(owner: &str, resource: &str) -> bool {
    resource == owner
        || resource
            .strip_prefix(owner)
            .is_some_and(|suffix| suffix.starts_with('/'))
}
