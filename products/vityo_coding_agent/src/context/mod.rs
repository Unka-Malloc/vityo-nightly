//! Revision-bound context retrieval, ranking, caching, and compaction.

mod cache;
mod compactor;
mod engine;
mod evidence;
mod ranker;

pub use cache::{ContextCache, ContextCacheKey, ContextCacheMetrics};
pub use compactor::{ConversationCompaction, ConversationCompactor, ConversationTurn};
pub use engine::{ContextBundle, ContextEngine, SelectedContextItem};
pub use evidence::{
    ContextBudget, ContextEngineFailure, ContextEngineFailureCode, ContextEvidence,
    ContextEvidenceError, ContextPage, ContextProvenance, ContextQuery, ContextRange,
    ContextSensitivity, ContextSource, ContextSourceFailure, ContextSourceFailureCode,
};
pub use ranker::{ContextRanker, ContextRanking, RankedContextEvidence};
