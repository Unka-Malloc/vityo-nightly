//! Stable evidence ranking with one normalization pass per candidate.

use std::collections::HashSet;

use super::evidence::{ContextEvidence, ContextQuery};

#[derive(Clone, Debug, PartialEq)]
pub struct RankedContextEvidence {
    pub evidence: ContextEvidence,
    pub score: f64,
    pub explicit: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ContextRanking {
    pub candidates: Vec<RankedContextEvidence>,
    pub deduplicated_count: usize,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ContextRanker;

impl ContextRanker {
    pub fn rank(
        &self,
        evidence: impl IntoIterator<Item = ContextEvidence>,
        query: &ContextQuery,
    ) -> ContextRanking {
        let normalized_terms = query
            .terms
            .iter()
            .map(|term| term.to_lowercase())
            .collect::<Vec<_>>();
        let mut canonical = evidence.into_iter().collect::<Vec<_>>();
        canonical.sort_by(canonical_compare);

        let mut seen = HashSet::with_capacity(canonical.len());
        let mut candidates = Vec::with_capacity(canonical.len());
        let mut deduplicated_count = 0;
        for item in canonical {
            let key = DedupKey {
                resource: item.resource.clone(),
                start: item.range.start,
                end: item.range.end,
                content_digest: item.content_digest.clone(),
            };
            if !seen.insert(key) {
                deduplicated_count += 1;
                continue;
            }
            let normalized_content = item.content.to_lowercase();
            let term_score = normalized_terms
                .iter()
                .filter(|term| normalized_content.contains(term.as_str()))
                .count() as f64;
            candidates.push(RankedContextEvidence {
                explicit: query.explicit_evidence_ids.contains(&item.id),
                score: item.base_score + term_score,
                evidence: item,
            });
        }
        candidates.sort_by(|left, right| {
            right
                .explicit
                .cmp(&left.explicit)
                .then_with(|| right.score.total_cmp(&left.score))
                .then_with(|| canonical_compare(&left.evidence, &right.evidence))
        });
        ContextRanking {
            candidates,
            deduplicated_count,
        }
    }
}

#[derive(Hash, PartialEq, Eq)]
struct DedupKey {
    resource: String,
    start: usize,
    end: usize,
    content_digest: String,
}

fn canonical_compare(left: &ContextEvidence, right: &ContextEvidence) -> std::cmp::Ordering {
    source_priority(&left.source)
        .cmp(&source_priority(&right.source))
        .then_with(|| left.resource.cmp(&right.resource))
        .then_with(|| left.range.start.cmp(&right.range.start))
        .then_with(|| left.range.end.cmp(&right.range.end))
        .then_with(|| left.id.cmp(&right.id))
        .then_with(|| left.source.cmp(&right.source))
        .then_with(|| left.content_digest.cmp(&right.content_digest))
        .then_with(|| left.revision.cmp(&right.revision))
        .then_with(|| left.base_score.total_cmp(&right.base_score))
        .then_with(|| left.token_cost.cmp(&right.token_cost))
        .then_with(|| left.sensitivity.cmp(&right.sensitivity))
        .then_with(|| left.truncated.cmp(&right.truncated))
        .then_with(|| left.provenance.source_id.cmp(&right.provenance.source_id))
        .then_with(|| left.provenance.retrieval.cmp(&right.provenance.retrieval))
        .then_with(|| {
            left.provenance
                .source_revision
                .cmp(&right.provenance.source_revision)
        })
}

fn source_priority(source: &str) -> u8 {
    match source {
        "attachment" => 0,
        "diagnostics" => 1,
        "changed" => 2,
        "symbols" => 3,
        "search" => 4,
        _ => 100,
    }
}
