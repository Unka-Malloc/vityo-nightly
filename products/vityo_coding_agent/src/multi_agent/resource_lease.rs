//! Hierarchical resource ownership leases for parallel workers.

use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    sync::Mutex,
};

use super::task_graph::is_normalized_ownership;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResourceLeaseToken {
    id: u64,
    task_id: String,
    scopes: BTreeSet<String>,
}

impl ResourceLeaseToken {
    pub fn task_id(&self) -> &str {
        &self.task_id
    }

    pub fn scopes(&self) -> &BTreeSet<String> {
        &self.scopes
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LeaseDecision {
    Granted(ResourceLeaseToken),
    Contended(BTreeSet<String>),
    Invalid,
}

#[derive(Default)]
struct LeaseState {
    next_id: u64,
    active: HashMap<u64, ResourceLeaseToken>,
    by_scope: BTreeMap<String, BTreeSet<u64>>,
}

#[derive(Default)]
pub struct ResourceLeaseRegistry {
    state: Mutex<LeaseState>,
}

impl ResourceLeaseRegistry {
    pub fn active_lease_count(&self) -> usize {
        self.state
            .lock()
            .expect("lease registry lock poisoned")
            .active
            .len()
    }

    pub fn acquire(
        &self,
        task_id: impl Into<String>,
        requested_scopes: impl IntoIterator<Item = String>,
    ) -> LeaseDecision {
        let task_id = task_id.into();
        let scopes = requested_scopes.into_iter().collect::<BTreeSet<_>>();
        if task_id.trim().is_empty()
            || scopes.is_empty()
            || scopes.iter().any(|scope| !is_normalized_ownership(scope))
        {
            return LeaseDecision::Invalid;
        }
        let mut state = self.state.lock().expect("lease registry lock poisoned");
        let mut conflicting_lease_ids = BTreeSet::new();
        for scope in &scopes {
            for prefix in parent_scopes(scope) {
                if let Some(ids) = state.by_scope.get(&prefix) {
                    conflicting_lease_ids.extend(ids.iter().copied());
                }
            }
            let descendants = format!("{scope}/");
            for (active_scope, ids) in state.by_scope.range(descendants.clone()..) {
                if !active_scope.starts_with(&descendants) {
                    break;
                }
                conflicting_lease_ids.extend(ids.iter().copied());
            }
        }
        if !conflicting_lease_ids.is_empty() {
            return LeaseDecision::Contended(
                conflicting_lease_ids
                    .iter()
                    .filter_map(|id| state.active.get(id).map(|lease| lease.task_id.clone()))
                    .collect(),
            );
        }
        state.next_id += 1;
        let token = ResourceLeaseToken {
            id: state.next_id,
            task_id,
            scopes,
        };
        for scope in &token.scopes {
            state
                .by_scope
                .entry(scope.clone())
                .or_default()
                .insert(token.id);
        }
        state.active.insert(token.id, token.clone());
        LeaseDecision::Granted(token)
    }

    pub fn release(&self, token: &ResourceLeaseToken) -> bool {
        let mut state = self.state.lock().expect("lease registry lock poisoned");
        if state.active.get(&token.id) != Some(token) {
            return false;
        }
        state.active.remove(&token.id);
        for scope in &token.scopes {
            if let Some(ids) = state.by_scope.get_mut(scope) {
                ids.remove(&token.id);
                if ids.is_empty() {
                    state.by_scope.remove(scope);
                }
            }
        }
        true
    }
}

fn parent_scopes(resource: &str) -> impl Iterator<Item = String> + '_ {
    let mut slash_offsets = resource
        .match_indices('/')
        .map(|(offset, _)| offset)
        .collect::<Vec<_>>();
    slash_offsets.push(resource.len());
    slash_offsets
        .into_iter()
        .map(|end| resource[..end].to_owned())
}
