//! Parallel, bounded, revision-aware context selection.

use std::{collections::HashMap, sync::Arc};

use futures::future::join_all;
use reqwest::Url;

use crate::cancellation::AgentCancellationToken;

use super::{
    cache::{ContextCache, ContextCacheKey},
    evidence::{
        ContextBudget, ContextEngineFailure, ContextEngineFailureCode, ContextEvidence,
        ContextPage, ContextQuery, ContextSource, ContextSourceFailure, ContextSourceFailureCode,
    },
    ranker::ContextRanker,
};

#[derive(Clone, Debug, PartialEq)]
pub struct SelectedContextItem {
    pub evidence: ContextEvidence,
    pub score: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ContextBundle {
    pub items: Vec<SelectedContextItem>,
    pub total_bytes: usize,
    pub total_tokens: usize,
    pub deduplicated_count: usize,
    pub stale_count: usize,
    pub redacted_count: usize,
    pub root_denied_count: usize,
    pub truncated: bool,
    pub source_failures: Vec<ContextSourceFailure>,
}

pub struct ContextEngine {
    sources: Vec<Arc<dyn ContextSource>>,
    cache: ContextCache,
    max_candidates_per_source: usize,
    ranker: ContextRanker,
}

impl ContextEngine {
    pub fn new(
        sources: Vec<Arc<dyn ContextSource>>,
        cache: ContextCache,
        max_candidates_per_source: usize,
    ) -> Result<Self, ContextEngineFailure> {
        if max_candidates_per_source == 0 {
            return Err(ContextEngineFailure(
                ContextEngineFailureCode::InvalidBudget,
            ));
        }
        Ok(Self {
            sources,
            cache,
            max_candidates_per_source,
            ranker: ContextRanker,
        })
    }

    pub fn cache(&self) -> &ContextCache {
        &self.cache
    }

    pub fn cache_mut(&mut self) -> &mut ContextCache {
        &mut self.cache
    }

    pub async fn select(
        &mut self,
        query: &ContextQuery,
        budget: &ContextBudget,
        cancellation: AgentCancellationToken,
    ) -> Result<ContextBundle, ContextEngineFailure> {
        validate_budget(budget)?;
        throw_if_cancelled(&cancellation)?;
        throw_if_deadline(query.deadline)?;

        let results = join_all(self.sources.iter().map(|source| {
            fetch_one(
                Arc::clone(source),
                query,
                self.max_candidates_per_source,
                cancellation.clone(),
            )
        }))
        .await;
        throw_if_cancelled(&cancellation)?;

        let mut failures = Vec::new();
        let mut candidates = Vec::new();
        let mut source_truncated = false;
        for result in results {
            match result? {
                Ok(page) => {
                    source_truncated |= page.has_more;
                    candidates.extend(page.items);
                }
                Err(failure) => failures.push(failure),
            }
        }

        let roots = query
            .roots
            .iter()
            .filter_map(|root| parse_root(root))
            .collect::<Vec<_>>();
        let mut eligible = Vec::with_capacity(candidates.len());
        let mut stale_count = 0;
        let mut redacted_count = 0;
        let mut root_denied_count = 0;
        for evidence in candidates {
            if !inside_any_root(&evidence.resource, &roots) {
                root_denied_count += 1;
                continue;
            }
            if evidence.sensitivity > query.maximum_sensitivity {
                redacted_count += 1;
                continue;
            }
            if query.expected_revisions.get(&evidence.resource) != Some(&evidence.revision) {
                stale_count += 1;
                continue;
            }
            let key = ContextCacheKey {
                evidence_id: evidence.id.clone(),
                resource: evidence.resource.clone(),
                revision: evidence.revision,
            };
            if self.cache.get(&key).is_none() {
                self.cache.put(key, evidence.content.clone());
            }
            eligible.push(evidence);
        }

        let ranking = self.ranker.rank(eligible, query);
        let available_tokens = budget.max_tokens - budget.reserved_output_tokens;
        let mut selected = Vec::new();
        let mut source_counts: HashMap<String, usize> = HashMap::new();
        let mut total_bytes = 0_usize;
        let mut total_tokens = 0_usize;
        let mut packing_truncated = false;
        for candidate in ranking.candidates {
            let evidence = candidate.evidence;
            let source_count = source_counts.get(&evidence.source).copied().unwrap_or(0);
            let source_cap = budget.per_source_caps.get(&evidence.source);
            let fits = selected.len() < budget.max_items
                && total_bytes.saturating_add(evidence.byte_cost) <= budget.max_bytes
                && total_tokens.saturating_add(evidence.token_cost) <= available_tokens
                && source_cap.is_none_or(|cap| source_count < *cap);
            if !fits {
                packing_truncated = true;
                continue;
            }
            total_bytes = total_bytes.saturating_add(evidence.byte_cost);
            total_tokens = total_tokens.saturating_add(evidence.token_cost);
            *source_counts.entry(evidence.source.clone()).or_default() += 1;
            selected.push(SelectedContextItem {
                evidence,
                score: candidate.score,
            });
        }

        Ok(ContextBundle {
            truncated: source_truncated
                || packing_truncated
                || stale_count > 0
                || redacted_count > 0
                || root_denied_count > 0
                || ranking.deduplicated_count > 0
                || selected.iter().any(|item| item.evidence.truncated),
            items: selected,
            total_bytes,
            total_tokens,
            deduplicated_count: ranking.deduplicated_count,
            stale_count,
            redacted_count,
            root_denied_count,
            source_failures: failures,
        })
    }
}

async fn fetch_one(
    source: Arc<dyn ContextSource>,
    query: &ContextQuery,
    limit: usize,
    cancellation: AgentCancellationToken,
) -> Result<Result<ContextPage, ContextSourceFailure>, ContextEngineFailure> {
    throw_if_cancelled(&cancellation)?;
    let fetch = source.fetch(query, limit, cancellation.clone());
    let result = if let Some(deadline) = query.deadline {
        tokio::select! {
            biased;
            _ = cancellation.cancelled() => return Err(ContextEngineFailure(ContextEngineFailureCode::Cancelled)),
            _ = tokio::time::sleep_until(deadline) => {
                return Ok(Err(ContextSourceFailure { code: ContextSourceFailureCode::Deadline, source_id: source.id().to_owned() }));
            }
            result = fetch => result,
        }
    } else {
        tokio::select! {
            biased;
            _ = cancellation.cancelled() => return Err(ContextEngineFailure(ContextEngineFailureCode::Cancelled)),
            result = fetch => result,
        }
    };
    Ok(match result {
        Ok(mut page) => {
            if page.items.len() > limit {
                page.items.truncate(limit);
                page.has_more = true;
            }
            Ok(page)
        }
        Err(failure) => Err(failure.attributed_to(source.id())),
    })
}

fn validate_budget(budget: &ContextBudget) -> Result<(), ContextEngineFailure> {
    if budget.reserved_output_tokens > budget.max_tokens {
        return Err(ContextEngineFailure(
            ContextEngineFailureCode::InvalidBudget,
        ));
    }
    Ok(())
}

fn throw_if_cancelled(cancellation: &AgentCancellationToken) -> Result<(), ContextEngineFailure> {
    if cancellation.is_cancelled() {
        Err(ContextEngineFailure(ContextEngineFailureCode::Cancelled))
    } else {
        Ok(())
    }
}

fn throw_if_deadline(deadline: Option<tokio::time::Instant>) -> Result<(), ContextEngineFailure> {
    if deadline.is_some_and(|deadline| deadline <= tokio::time::Instant::now()) {
        Err(ContextEngineFailure(ContextEngineFailureCode::Deadline))
    } else {
        Ok(())
    }
}

struct ResourceRoot {
    scheme: String,
    host: String,
    port: Option<u16>,
    segments: Vec<String>,
}

fn parse_root(resource: &str) -> Option<ResourceRoot> {
    let root = Url::parse(resource).ok()?;
    if root.host_str().is_none()
        || !root.username().is_empty()
        || root.password().is_some()
        || root.query().is_some()
        || root.fragment().is_some()
    {
        return None;
    }
    Some(ResourceRoot {
        scheme: root.scheme().to_owned(),
        host: root.host_str()?.to_owned(),
        port: root.port_or_known_default(),
        segments: normalized_segments(&root)?,
    })
}

fn inside_any_root(resource: &str, roots: &[ResourceRoot]) -> bool {
    let Ok(candidate) = Url::parse(resource) else {
        return false;
    };
    let Some(candidate_segments) = normalized_segments(&candidate) else {
        return false;
    };
    if candidate.host_str().is_none()
        || !candidate.username().is_empty()
        || candidate.password().is_some()
        || candidate.query().is_some()
        || candidate.fragment().is_some()
    {
        return false;
    }
    roots.iter().any(|root| {
        if root.scheme != candidate.scheme()
            || Some(root.host.as_str()) != candidate.host_str()
            || root.port != candidate.port_or_known_default()
        {
            return false;
        }
        candidate_segments.starts_with(&root.segments)
    })
}

fn normalized_segments(url: &Url) -> Option<Vec<String>> {
    url.path_segments().map(|segments| {
        segments
            .filter(|segment| !segment.is_empty() && *segment != ".")
            .map(ToOwned::to_owned)
            .collect()
    })
}
