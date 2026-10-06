//! Durable coding-agent session records and recovery.

mod events;
mod store;

pub use events::{
    EventValidationError, RecoveredSession, SessionCheckpoint, SessionCorrelation, SessionEvent,
    SessionEventDraft, SessionEventKind, SessionPermissionGrant, SessionPermissionGrantSnapshot,
    SessionProjection, SessionProjector, SessionRecovery, SessionRecoveryStatus, SessionRedactor,
    canonical_json, canonical_utf8_len, compute_projection_digest, utc_now_rfc3339,
};
pub use store::{
    EffectBeginOutcome, EffectBeginResult, EffectCommitOutcome, EffectCommitResult,
    EffectExecutionOutcome, EffectExecutionReceipt, EffectReceipt, EffectReceiptJournal,
    EffectRequest, EffectReservation, FileSessionEventStore, InMemorySessionEventStore,
    SessionAppendOutcome, SessionAppendResult, SessionEventBatch, SessionEventStore,
    SessionStoreError,
};
