use std::{
    collections::{HashMap, HashSet},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use futures::{FutureExt, future::BoxFuture};
use vityo_coding_agent::{
    cancellation::AgentCancellationToken,
    context::{
        ContextBudget, ContextCache, ContextCacheKey, ContextEngine, ContextEngineFailureCode,
        ContextEvidence, ContextPage, ContextProvenance, ContextQuery, ContextRange, ContextRanker,
        ContextSensitivity, ContextSource, ContextSourceFailure, ContextSourceFailureCode,
        ConversationCompactor, ConversationTurn,
    },
};

const ROOT: &str = "workspace://root/project";

#[tokio::test]
async fn expired_deadline_fails_before_fetching_any_source() {
    let calls = Arc::new(AtomicUsize::new(0));
    let mut engine = engine(vec![Arc::new(FixtureSource::new(
        "fixture",
        vec![],
        false,
        Arc::clone(&calls),
    ))]);
    let mut query = query();
    query.deadline = Some(tokio::time::Instant::now() - Duration::from_millis(1));
    let failure = engine
        .select(&query, &budget(), AgentCancellationToken::new())
        .await
        .unwrap_err();
    assert_eq!(failure.0, ContextEngineFailureCode::Deadline);
    assert_eq!(calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn a_hanging_source_becomes_an_attributed_deadline_failure() {
    let mut engine = engine(vec![Arc::new(HangingSource { id: "slow-search" })]);
    let mut query = query();
    query.deadline = Some(tokio::time::Instant::now() + Duration::from_millis(10));
    let result = engine
        .select(&query, &budget(), AgentCancellationToken::new())
        .await
        .unwrap();
    assert_eq!(result.source_failures.len(), 1);
    assert_eq!(result.source_failures[0].source_id, "slow-search");
    assert_eq!(
        result.source_failures[0].code,
        ContextSourceFailureCode::Deadline
    );
}

#[test]
fn evidence_records_byte_cost_digest_range_and_source_truncation() {
    let evidence = evidence(
        "snippet",
        "search",
        "workspace://root/project/a.sty",
        4,
        ContextRange::new(3, 9).unwrap(),
        ContextSensitivity::Public,
        1.0,
        "évidence".to_owned(),
        2,
        true,
    );
    assert_eq!(evidence.range, ContextRange { start: 3, end: 9 });
    assert_eq!(evidence.byte_cost, "évidence".len());
    assert_eq!(evidence.content_digest.len(), 64);
    assert!(evidence.truncated);
}

#[test]
fn revision_invalidation_removes_only_stale_entries_for_one_resource() {
    let mut cache = ContextCache::new(4, 64);
    let stale = cache_key("old", "workspace://root/project/a.sty", 1);
    let current = cache_key("new", "workspace://root/project/a.sty", 2);
    let other = cache_key("other", "workspace://root/project/b.sty", 1);
    cache.put(stale.clone(), "stale value".to_owned());
    cache.put(current.clone(), "current value".to_owned());
    cache.put(other.clone(), "other resource".to_owned());

    cache.invalidate_resource("workspace://root/project/a.sty", 2);

    assert_eq!(cache.get(&stale), None);
    assert_eq!(cache.get(&current), Some("current value"));
    assert_eq!(cache.get(&other), Some("other resource"));
    assert_eq!(cache.entry_count(), 2);
    assert_eq!(
        cache.byte_count(),
        "current value".len() + "other resource".len()
    );
}

#[test]
fn conversation_compaction_bounds_the_hot_tail_and_redacts_secrets() {
    let turns = vec![
        turn(
            "old-secret",
            "never-copy-this",
            5,
            ContextSensitivity::Secret,
        ),
        turn("old", "retained context", 3, ContextSensitivity::Internal),
        turn("hot-secret", "also-private", 4, ContextSensitivity::Secret),
        turn("hot", "current question", 2, ContextSensitivity::Public),
    ];
    let result = ConversationCompactor.compact(&turns, 2, 8);
    assert_eq!(result.hot_turns.len(), 2);
    assert_eq!(result.hot_turns[0].text, "[redacted]");
    assert_eq!(result.hot_turns[1].id, "hot");
    assert!(result.summary.contains("old-secret@1: [redacted]"));
    assert!(!result.summary.contains("never-copy-this"));
    assert!(
        !result
            .hot_turns
            .iter()
            .any(|turn| turn.text == "also-private")
    );
    assert_eq!(result.redacted_turn_count, 2);
    assert!(result.truncated);
}

#[tokio::test]
async fn context_filters_evidence_ranks_deduplicates_and_obeys_budget() {
    let explicit = evidence(
        "explicit",
        "search",
        "workspace://root/project/explicit.sty",
        7,
        ContextRange::new(0, 8).unwrap(),
        ContextSensitivity::Public,
        0.1,
        "explicit code".to_owned(),
        3,
        false,
    );
    let match_item = evidence(
        "match",
        "changed",
        "workspace://root/project/match.sty",
        2,
        ContextRange::new(0, 12).unwrap(),
        ContextSensitivity::Internal,
        1.0,
        "Needle in code".to_owned(),
        4,
        false,
    );
    let duplicate = evidence(
        "duplicate",
        "search",
        &match_item.resource,
        match_item.revision,
        match_item.range,
        match_item.sensitivity,
        0.0,
        match_item.content.clone(),
        4,
        false,
    );
    let stale = evidence(
        "stale",
        "changed",
        "workspace://root/project/stale.sty",
        1,
        ContextRange::new(0, 4).unwrap(),
        ContextSensitivity::Public,
        5.0,
        "needle old".to_owned(),
        2,
        false,
    );
    let secret = evidence(
        "secret",
        "attachment",
        "workspace://root/project/secret.sty",
        3,
        ContextRange::new(0, 6).unwrap(),
        ContextSensitivity::Confidential,
        10.0,
        "needle".to_owned(),
        1,
        false,
    );
    let outside = evidence(
        "outside",
        "attachment",
        "workspace://elsewhere/project/outside.sty",
        1,
        ContextRange::new(0, 7).unwrap(),
        ContextSensitivity::Public,
        20.0,
        "needle".to_owned(),
        1,
        false,
    );
    let page = vec![explicit, match_item, duplicate, stale, secret, outside];
    let mut engine = engine(vec![Arc::new(FixtureSource::new(
        "fixture",
        page,
        false,
        Arc::new(AtomicUsize::new(0)),
    ))]);
    let mut query = query();
    query.terms = vec!["NEEDLE".to_owned()];
    query.explicit_evidence_ids.insert("explicit".to_owned());
    query.maximum_sensitivity = ContextSensitivity::Internal;
    query.expected_revisions.extend([
        ("workspace://root/project/explicit.sty".to_owned(), 7),
        ("workspace://root/project/match.sty".to_owned(), 2),
        ("workspace://root/project/stale.sty".to_owned(), 2),
        ("workspace://root/project/secret.sty".to_owned(), 3),
    ]);
    let result = engine
        .select(
            &query,
            &budget_with_limits(2, 64, 12, 2),
            AgentCancellationToken::new(),
        )
        .await
        .unwrap();

    assert_eq!(result.items.len(), 2);
    assert_eq!(result.items[0].evidence.id, "explicit");
    assert_eq!(result.items[1].evidence.id, "match");
    assert_eq!(result.deduplicated_count, 1);
    assert_eq!(result.stale_count, 1);
    assert_eq!(result.redacted_count, 1);
    assert_eq!(result.root_denied_count, 1);
    assert_eq!(result.total_tokens, 7);
    assert!(result.truncated);
}

#[test]
fn rank_ties_follow_source_priority_independent_of_input_order() {
    let preferred = evidence(
        "attachment-item",
        "attachment",
        "workspace://root/project/shared.sty",
        1,
        ContextRange::new(0, 10).unwrap(),
        ContextSensitivity::Public,
        1.0,
        "attachment content".to_owned(),
        2,
        false,
    );
    let lower_priority = evidence(
        "search-item",
        "search",
        "workspace://root/project/shared.sty",
        1,
        ContextRange::new(0, 10).unwrap(),
        ContextSensitivity::Public,
        1.0,
        "search content".to_owned(),
        2,
        false,
    );
    let query = query();
    let first = ContextRanker.rank([lower_priority.clone(), preferred.clone()], &query);
    let second = ContextRanker.rank([preferred, lower_priority], &query);
    assert_eq!(first.candidates[0].evidence.id, "attachment-item");
    assert_eq!(
        first.candidates[0].evidence.id,
        second.candidates[0].evidence.id
    );
}

#[tokio::test]
async fn source_page_is_clamped_to_its_candidate_limit() {
    let items = (0..5)
        .map(|index| {
            evidence(
                &format!("item-{index}"),
                "search",
                &format!("workspace://root/project/{index}.sty"),
                1,
                ContextRange::new(0, 1).unwrap(),
                ContextSensitivity::Public,
                1.0,
                "x".to_owned(),
                1,
                false,
            )
        })
        .collect();
    let mut engine = ContextEngine::new(
        vec![Arc::new(FixtureSource::new(
            "oversized",
            items,
            false,
            Arc::new(AtomicUsize::new(0)),
        ))],
        ContextCache::new(16, 1024),
        2,
    )
    .unwrap();
    let mut query = query();
    for index in 0..5 {
        query
            .expected_revisions
            .insert(format!("workspace://root/project/{index}.sty"), 1);
    }
    let result = engine
        .select(
            &query,
            &budget_with_limits(8, 64, 16, 0),
            AgentCancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(result.items.len(), 2);
    assert!(result.truncated);
}

#[tokio::test]
async fn representative_context_batch_stays_within_candidate_cache_and_selection_bounds() {
    let items = (0..512)
        .map(|index| {
            evidence(
                &format!("evidence-{index:04}"),
                "search",
                &format!("workspace://root/project/item-{index:04}.sty"),
                3,
                ContextRange::new(0, 12).unwrap(),
                ContextSensitivity::Public,
                (index % 10) as f64,
                format!("needle item {index}"),
                4,
                false,
            )
        })
        .collect::<Vec<_>>();
    let calls = Arc::new(AtomicUsize::new(0));
    let source = Arc::new(FixtureSource::new(
        "search",
        items,
        false,
        Arc::clone(&calls),
    ));
    let mut engine =
        ContextEngine::new(vec![source], ContextCache::new(64, 4 * 1024), 128).unwrap();
    let mut query = query();
    query.terms = vec!["needle".to_owned()];
    for index in 0..512 {
        query
            .expected_revisions
            .insert(format!("workspace://root/project/item-{index:04}.sty"), 3);
    }
    let mut limits = budget_with_limits(16, 4096, 512, 128);
    limits.per_source_caps.insert("search".to_owned(), 16);

    let result = engine
        .select(&query, &limits, AgentCancellationToken::new())
        .await
        .unwrap();

    assert_eq!(calls.load(Ordering::Relaxed), 1);
    assert_eq!(result.items.len(), 16);
    assert_eq!(result.total_tokens, 64);
    assert!(result.truncated);
    assert_eq!(engine.cache().entry_count(), 64);
    assert!(engine.cache().byte_count() <= 4 * 1024);
    assert_eq!(engine.cache().metrics().evictions, 64);
}

fn engine(sources: Vec<Arc<dyn ContextSource>>) -> ContextEngine {
    ContextEngine::new(sources, ContextCache::new(128, 64 * 1024), 32).unwrap()
}

fn query() -> ContextQuery {
    ContextQuery {
        terms: Vec::new(),
        roots: vec![ROOT.to_owned()],
        expected_revisions: HashMap::new(),
        explicit_evidence_ids: HashSet::new(),
        maximum_sensitivity: ContextSensitivity::Confidential,
        deadline: None,
    }
}

fn budget() -> ContextBudget {
    budget_with_limits(8, 4096, 256, 16)
}

fn budget_with_limits(
    max_items: usize,
    max_bytes: usize,
    max_tokens: usize,
    reserved_output_tokens: usize,
) -> ContextBudget {
    ContextBudget {
        max_items,
        max_bytes,
        max_tokens,
        reserved_output_tokens,
        per_source_caps: HashMap::new(),
    }
}

fn evidence(
    id: &str,
    source: &str,
    resource: &str,
    revision: u64,
    range: ContextRange,
    sensitivity: ContextSensitivity,
    base_score: f64,
    content: String,
    token_cost: usize,
    truncated: bool,
) -> ContextEvidence {
    ContextEvidence::new(
        id.to_owned(),
        source.to_owned(),
        resource.to_owned(),
        revision,
        range,
        sensitivity,
        base_score,
        content,
        token_cost,
        ContextProvenance {
            source_id: source.to_owned(),
            retrieval: "fixture".to_owned(),
            source_revision: revision,
        },
        truncated,
    )
    .unwrap()
}

fn cache_key(evidence_id: &str, resource: &str, revision: u64) -> ContextCacheKey {
    ContextCacheKey {
        evidence_id: evidence_id.to_owned(),
        resource: resource.to_owned(),
        revision,
    }
}

fn turn(
    id: &str,
    text: &str,
    token_cost: usize,
    sensitivity: ContextSensitivity,
) -> ConversationTurn {
    ConversationTurn {
        id: id.to_owned(),
        revision: 1,
        text: text.to_owned(),
        token_cost,
        sensitivity,
    }
}

struct FixtureSource {
    id: String,
    items: Vec<ContextEvidence>,
    has_more: bool,
    calls: Arc<AtomicUsize>,
}

impl FixtureSource {
    fn new(id: &str, items: Vec<ContextEvidence>, has_more: bool, calls: Arc<AtomicUsize>) -> Self {
        Self {
            id: id.to_owned(),
            items,
            has_more,
            calls,
        }
    }
}

impl ContextSource for FixtureSource {
    fn id(&self) -> &str {
        &self.id
    }

    fn fetch<'a>(
        &'a self,
        _query: &'a ContextQuery,
        _limit: usize,
        _cancellation: AgentCancellationToken,
    ) -> BoxFuture<'a, Result<ContextPage, ContextSourceFailure>> {
        async move {
            self.calls.fetch_add(1, Ordering::Relaxed);
            Ok(ContextPage {
                items: self.items.clone(),
                has_more: self.has_more,
            })
        }
        .boxed()
    }
}

struct HangingSource {
    id: &'static str,
}

impl ContextSource for HangingSource {
    fn id(&self) -> &str {
        self.id
    }

    fn fetch<'a>(
        &'a self,
        _query: &'a ContextQuery,
        _limit: usize,
        _cancellation: AgentCancellationToken,
    ) -> BoxFuture<'a, Result<ContextPage, ContextSourceFailure>> {
        std::future::pending().boxed()
    }
}
