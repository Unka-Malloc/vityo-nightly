//! In-memory and append-only JSONL session stores.

use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Mutex as AsyncMutex;

use super::events::{
    SessionCheckpoint, SessionCorrelation, SessionEvent, SessionEventDraft, SessionEventKind,
    SessionPermissionGrant, SessionPermissionGrantSnapshot, SessionRedactor, canonical_json,
    canonical_utf8_len, replay_permission_event, sha256_hex,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionAppendOutcome {
    Committed,
    SequenceConflict,
    InvalidEvent,
    CorruptedTail,
}

#[derive(Clone, Debug)]
pub struct SessionAppendResult {
    pub outcome: SessionAppendOutcome,
    pub current_sequence: u64,
    pub committed_events: Vec<SessionEvent>,
}

#[derive(Clone, Debug)]
pub struct SessionEventBatch {
    pub session_id: String,
    pub current_sequence: u64,
    pub events: Vec<SessionEvent>,
    pub corrupted_tail: bool,
    pub has_more: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionStoreError {
    Io,
    Encoding,
    InvalidLimit,
    WorkerFailed,
}

#[async_trait]
pub trait SessionEventStore: EffectReceiptJournal + Send + Sync {
    async fn append(
        &self,
        session_id: &str,
        expected_sequence: u64,
        events: &[SessionEventDraft],
    ) -> Result<SessionAppendResult, SessionStoreError>;

    async fn load(
        &self,
        session_id: &str,
        after_sequence: u64,
        max_events: usize,
    ) -> Result<SessionEventBatch, SessionStoreError>;

    async fn load_permission_grants(
        &self,
        session_id: &str,
    ) -> Result<Vec<SessionPermissionGrantSnapshot>, SessionStoreError>;

    async fn append_permission_grant(
        &self,
        grant: SessionPermissionGrant,
        correlation: SessionCorrelation,
        expected_sequence: u64,
        occurred_at: String,
    ) -> Result<SessionAppendResult, SessionStoreError> {
        if !grant.is_valid() || grant.session_id != correlation.session_id {
            return Err(SessionStoreError::Encoding);
        }
        let session_id = grant.session_id.clone();
        let draft = SessionEventDraft::new(
            SessionEventKind::PermissionRecorded,
            correlation,
            occurred_at,
            json!({ "action": "grant", "grant": grant }),
        )
        .map_err(|_| SessionStoreError::Encoding)?;
        self.append(&session_id, expected_sequence, &[draft]).await
    }

    async fn append_permission_revocation(
        &self,
        session_id: &str,
        grant_id: &str,
        correlation: SessionCorrelation,
        expected_sequence: u64,
        occurred_at: String,
    ) -> Result<SessionAppendResult, SessionStoreError> {
        if session_id.trim().is_empty()
            || grant_id.trim().is_empty()
            || correlation.session_id != session_id
        {
            return Err(SessionStoreError::Encoding);
        }
        let draft = SessionEventDraft::new(
            SessionEventKind::PermissionRecorded,
            correlation,
            occurred_at,
            json!({ "action": "revoke", "grantId": grant_id }),
        )
        .map_err(|_| SessionStoreError::Encoding)?;
        self.append(session_id, expected_sequence, &[draft]).await
    }

    async fn save_checkpoint(&self, checkpoint: SessionCheckpoint)
    -> Result<(), SessionStoreError>;

    async fn load_checkpoint(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionCheckpoint>, SessionStoreError>;
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum EffectExecutionOutcome {
    Committed,
    Rejected,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EffectRequest {
    pub session_id: String,
    pub idempotency_key: String,
    pub effect_kind: String,
    pub parameters: Value,
}

impl EffectRequest {
    pub fn is_valid(&self) -> bool {
        !self.session_id.trim().is_empty()
            && !self.idempotency_key.trim().is_empty()
            && !self.effect_kind.trim().is_empty()
            && self.parameters.is_object()
    }

    fn digest(&self) -> String {
        let value = json!({
            "effectKind": self.effect_kind,
            "parameters": self.parameters,
        });
        sha256_hex(canonical_json(&value).as_bytes())
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EffectExecutionReceipt {
    pub effect_id: String,
    pub outcome: EffectExecutionOutcome,
    pub metadata: Value,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EffectReceipt {
    pub session_id: String,
    pub idempotency_key: String,
    pub effect_kind: String,
    pub effect_id: String,
    pub event_sequence: u64,
    pub outcome: EffectExecutionOutcome,
    pub metadata: Value,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EffectReservation {
    pub session_id: String,
    pub idempotency_key: String,
    pub request_digest: String,
    pub intent_sequence: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EffectBeginOutcome {
    Started,
    Replay,
    InProgress,
    SequenceConflict,
    IdempotencyConflict,
    Rejected,
    CorruptedTail,
}

#[derive(Clone, Debug)]
pub struct EffectBeginResult {
    pub outcome: EffectBeginOutcome,
    pub current_sequence: u64,
    pub reservation: Option<EffectReservation>,
    pub receipt: Option<EffectReceipt>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EffectCommitOutcome {
    Committed,
    Rejected,
    SequenceConflict,
    IdempotencyConflict,
    Uncertain,
    CorruptedTail,
    Invalid,
}

#[derive(Clone, Debug)]
pub struct EffectCommitResult {
    pub outcome: EffectCommitOutcome,
    pub current_sequence: u64,
    pub replayed_from_journal: bool,
    pub receipt: Option<EffectReceipt>,
}

#[async_trait]
pub trait EffectReceiptJournal: Send + Sync {
    /// Persist intent before invoking an external effect. A matching pending
    /// intent after restart is returned as `InProgress` and must not be rerun.
    async fn begin_effect(
        &self,
        request: EffectRequest,
        correlation: SessionCorrelation,
        expected_sequence: u64,
        occurred_at: String,
    ) -> Result<EffectBeginResult, SessionStoreError>;

    /// Persist a known adapter result. Adapter errors or process interruption
    /// leave the durable intent pending, which accurately represents an
    /// uncertain external effect.
    async fn complete_effect(
        &self,
        reservation: EffectReservation,
        execution: EffectExecutionReceipt,
        occurred_at: String,
    ) -> Result<EffectCommitResult, SessionStoreError>;

    async fn find_effect_receipt(
        &self,
        session_id: &str,
        idempotency_key: &str,
    ) -> Result<Option<EffectReceipt>, SessionStoreError>;

    async fn load_effect_receipts(
        &self,
        session_id: &str,
        max_receipts: usize,
    ) -> Result<Vec<EffectReceipt>, SessionStoreError>;
}

#[derive(Clone, Debug)]
struct PendingEffect {
    request_digest: String,
    intent_sequence: u64,
}

#[derive(Default)]
struct MemorySession {
    events: Vec<SessionEvent>,
    receipts: BTreeMap<String, EffectReceipt>,
    pending: HashMap<String, PendingEffect>,
    request_digests: HashMap<String, String>,
    permission_grants: BTreeMap<String, SessionPermissionGrantSnapshot>,
    checkpoint: Option<SessionCheckpoint>,
}

pub struct InMemorySessionEventStore {
    redactor: SessionRedactor,
    max_batch_events: usize,
    max_event_bytes: usize,
    sessions: AsyncMutex<HashMap<String, MemorySession>>,
}

impl Default for InMemorySessionEventStore {
    fn default() -> Self {
        Self::new(SessionRedactor::default(), 256, 65_536)
    }
}

impl InMemorySessionEventStore {
    pub fn new(redactor: SessionRedactor, max_batch_events: usize, max_event_bytes: usize) -> Self {
        assert!(max_batch_events > 0 && max_event_bytes > 0);
        Self {
            redactor,
            max_batch_events,
            max_event_bytes,
            sessions: AsyncMutex::new(HashMap::new()),
        }
    }
}

#[async_trait]
impl SessionEventStore for InMemorySessionEventStore {
    async fn append(
        &self,
        session_id: &str,
        expected_sequence: u64,
        drafts: &[SessionEventDraft],
    ) -> Result<SessionAppendResult, SessionStoreError> {
        let mut sessions = self.sessions.lock().await;
        let log = sessions.entry(session_id.to_owned()).or_default();
        let current = log.events.len() as u64;
        if expected_sequence != current {
            return Ok(append_result(
                SessionAppendOutcome::SequenceConflict,
                current,
            ));
        }
        if !valid_drafts(
            session_id,
            drafts,
            self.max_batch_events,
            self.max_event_bytes,
            &self.redactor,
        ) {
            return Ok(append_result(SessionAppendOutcome::InvalidEvent, current));
        }
        let mut previous_digest = log
            .events
            .last()
            .map(|event| event.digest.as_str())
            .unwrap_or("")
            .to_owned();
        let committed_events = drafts
            .iter()
            .enumerate()
            .map(|(offset, draft)| {
                let event = SessionEvent::commit(
                    current + offset as u64 + 1,
                    draft,
                    previous_digest.clone(),
                    &self.redactor,
                );
                previous_digest = event.digest.clone();
                event
            })
            .collect::<Vec<_>>();
        for event in &committed_events {
            replay_permission_event(&mut log.permission_grants, event);
        }
        log.events.extend(committed_events.clone());
        Ok(SessionAppendResult {
            outcome: SessionAppendOutcome::Committed,
            current_sequence: log.events.len() as u64,
            committed_events,
        })
    }

    async fn load(
        &self,
        session_id: &str,
        after_sequence: u64,
        max_events: usize,
    ) -> Result<SessionEventBatch, SessionStoreError> {
        if max_events == 0 {
            return Err(SessionStoreError::InvalidLimit);
        }
        let sessions = self.sessions.lock().await;
        let log = sessions.get(session_id);
        let current = log.map_or(0, |log| log.events.len() as u64);
        let start = after_sequence.min(current) as usize;
        let events = log.map_or_else(Vec::new, |log| {
            log.events
                .iter()
                .skip(start)
                .take(max_events)
                .cloned()
                .collect()
        });
        Ok(SessionEventBatch {
            session_id: session_id.to_owned(),
            current_sequence: current,
            has_more: start + events.len() < current as usize,
            events,
            corrupted_tail: false,
        })
    }

    async fn load_permission_grants(
        &self,
        session_id: &str,
    ) -> Result<Vec<SessionPermissionGrantSnapshot>, SessionStoreError> {
        let sessions = self.sessions.lock().await;
        let mut grants = sessions
            .get(session_id)
            .map(|log| log.permission_grants.values().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        grants.sort_by_key(|snapshot| snapshot.granted_sequence);
        Ok(grants)
    }

    async fn save_checkpoint(
        &self,
        checkpoint: SessionCheckpoint,
    ) -> Result<(), SessionStoreError> {
        let mut sessions = self.sessions.lock().await;
        let log = sessions.entry(checkpoint.session_id.clone()).or_default();
        if !checkpoint.is_valid() || checkpoint.applied_sequence > log.events.len() as u64 {
            return Err(SessionStoreError::Encoding);
        }
        log.checkpoint = Some(checkpoint);
        Ok(())
    }

    async fn load_checkpoint(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionCheckpoint>, SessionStoreError> {
        Ok(self
            .sessions
            .lock()
            .await
            .get(session_id)
            .and_then(|log| log.checkpoint.clone()))
    }
}

#[async_trait]
impl EffectReceiptJournal for InMemorySessionEventStore {
    async fn begin_effect(
        &self,
        request: EffectRequest,
        correlation: SessionCorrelation,
        expected_sequence: u64,
        occurred_at: String,
    ) -> Result<EffectBeginResult, SessionStoreError> {
        let mut sessions = self.sessions.lock().await;
        let log = sessions.entry(request.session_id.clone()).or_default();
        Ok(begin_effect(
            log,
            request,
            correlation,
            expected_sequence,
            occurred_at,
            self.max_event_bytes,
            &self.redactor,
        ))
    }

    async fn complete_effect(
        &self,
        reservation: EffectReservation,
        execution: EffectExecutionReceipt,
        occurred_at: String,
    ) -> Result<EffectCommitResult, SessionStoreError> {
        let mut sessions = self.sessions.lock().await;
        let log = sessions.entry(reservation.session_id.clone()).or_default();
        Ok(complete_effect(
            log,
            reservation,
            execution,
            occurred_at,
            self.max_event_bytes,
            &self.redactor,
        ))
    }

    async fn find_effect_receipt(
        &self,
        session_id: &str,
        idempotency_key: &str,
    ) -> Result<Option<EffectReceipt>, SessionStoreError> {
        Ok(self
            .sessions
            .lock()
            .await
            .get(session_id)
            .and_then(|log| log.receipts.get(idempotency_key).cloned()))
    }

    async fn load_effect_receipts(
        &self,
        session_id: &str,
        max_receipts: usize,
    ) -> Result<Vec<EffectReceipt>, SessionStoreError> {
        if max_receipts == 0 {
            return Err(SessionStoreError::InvalidLimit);
        }
        Ok(self
            .sessions
            .lock()
            .await
            .get(session_id)
            .map(|log| log.receipts.values().take(max_receipts).cloned().collect())
            .unwrap_or_default())
    }
}

fn append_result(outcome: SessionAppendOutcome, current_sequence: u64) -> SessionAppendResult {
    SessionAppendResult {
        outcome,
        current_sequence,
        committed_events: Vec::new(),
    }
}

fn valid_drafts(
    session_id: &str,
    drafts: &[SessionEventDraft],
    max_batch_events: usize,
    max_event_bytes: usize,
    redactor: &SessionRedactor,
) -> bool {
    !session_id.trim().is_empty()
        && !drafts.is_empty()
        && drafts.len() <= max_batch_events
        && drafts.iter().all(|draft| {
            draft.correlation.session_id == session_id
                && draft.correlation.is_valid()
                && draft.payload.is_object()
                && canonical_utf8_len(&redactor.redact(&draft.payload)) <= max_event_bytes
        })
}

fn begin_effect(
    log: &mut MemorySession,
    request: EffectRequest,
    correlation: SessionCorrelation,
    expected_sequence: u64,
    occurred_at: String,
    max_event_bytes: usize,
    redactor: &SessionRedactor,
) -> EffectBeginResult {
    let current = log.events.len() as u64;
    let invalid = !request.is_valid()
        || !correlation.is_valid()
        || request.session_id != correlation.session_id
        || canonical_utf8_len(&redactor.redact(&request.parameters)) > max_event_bytes;
    if invalid {
        return effect_begin_result(EffectBeginOutcome::Rejected, current);
    }
    let digest = request.digest();
    if let Some(receipt) = log.receipts.get(&request.idempotency_key) {
        if log
            .request_digests
            .get(&request.idempotency_key)
            .is_some_and(|existing| existing != &digest)
        {
            return effect_begin_result(EffectBeginOutcome::IdempotencyConflict, current);
        }
        return EffectBeginResult {
            outcome: EffectBeginOutcome::Replay,
            current_sequence: current,
            reservation: None,
            receipt: Some(receipt.clone()),
        };
    }
    if let Some(pending) = log.pending.get(&request.idempotency_key) {
        return effect_begin_result(
            if pending.request_digest == digest {
                EffectBeginOutcome::InProgress
            } else {
                EffectBeginOutcome::IdempotencyConflict
            },
            current,
        );
    }
    if expected_sequence != current {
        return effect_begin_result(EffectBeginOutcome::SequenceConflict, current);
    }
    let payload = json!({
        "_effectReservation": {
            "idempotencyKey": request.idempotency_key,
            "requestDigest": digest,
            "effectKind": request.effect_kind,
            "parameters": request.parameters,
        }
    });
    let Ok(draft) = SessionEventDraft::new(
        SessionEventKind::ToolCallRecorded,
        correlation,
        occurred_at,
        payload,
    ) else {
        return effect_begin_result(EffectBeginOutcome::Rejected, current);
    };
    if canonical_utf8_len(&redactor.redact(&draft.payload)) > max_event_bytes {
        return effect_begin_result(EffectBeginOutcome::Rejected, current);
    }
    let previous = log
        .events
        .last()
        .map(|event| event.digest.as_str())
        .unwrap_or("");
    let event = SessionEvent::commit(current + 1, &draft, previous, redactor);
    let reservation = EffectReservation {
        session_id: request.session_id,
        idempotency_key: request.idempotency_key.clone(),
        request_digest: digest.clone(),
        intent_sequence: event.sequence,
    };
    log.events.push(event);
    log.pending.insert(
        request.idempotency_key,
        PendingEffect {
            request_digest: digest,
            intent_sequence: reservation.intent_sequence,
        },
    );
    EffectBeginResult {
        outcome: EffectBeginOutcome::Started,
        current_sequence: current + 1,
        reservation: Some(reservation),
        receipt: None,
    }
}

fn effect_begin_result(outcome: EffectBeginOutcome, current_sequence: u64) -> EffectBeginResult {
    EffectBeginResult {
        outcome,
        current_sequence,
        reservation: None,
        receipt: None,
    }
}

fn complete_effect(
    log: &mut MemorySession,
    reservation: EffectReservation,
    execution: EffectExecutionReceipt,
    occurred_at: String,
    max_event_bytes: usize,
    redactor: &SessionRedactor,
) -> EffectCommitResult {
    let current = log.events.len() as u64;
    if let Some(receipt) = log.receipts.get(&reservation.idempotency_key) {
        let matches = log
            .request_digests
            .get(&reservation.idempotency_key)
            .is_none_or(|digest| digest == &reservation.request_digest);
        return EffectCommitResult {
            outcome: if matches {
                commit_outcome(receipt.outcome)
            } else {
                EffectCommitOutcome::IdempotencyConflict
            },
            current_sequence: current,
            replayed_from_journal: matches,
            receipt: Some(receipt.clone()),
        };
    }
    let Some(pending) = log.pending.get(&reservation.idempotency_key) else {
        return EffectCommitResult {
            outcome: EffectCommitOutcome::Uncertain,
            current_sequence: current,
            replayed_from_journal: false,
            receipt: None,
        };
    };
    if pending.request_digest != reservation.request_digest
        || pending.intent_sequence != reservation.intent_sequence
    {
        return EffectCommitResult {
            outcome: EffectCommitOutcome::IdempotencyConflict,
            current_sequence: current,
            replayed_from_journal: false,
            receipt: None,
        };
    }
    if execution.effect_id.trim().is_empty()
        || !execution.metadata.is_object()
        || canonical_utf8_len(&redactor.redact(&execution.metadata)) > max_event_bytes
    {
        return EffectCommitResult {
            outcome: EffectCommitOutcome::Invalid,
            current_sequence: current,
            replayed_from_journal: false,
            receipt: None,
        };
    }
    let Some(intent) = log
        .events
        .get(reservation.intent_sequence.saturating_sub(1) as usize)
    else {
        return EffectCommitResult {
            outcome: EffectCommitOutcome::Uncertain,
            current_sequence: current,
            replayed_from_journal: false,
            receipt: None,
        };
    };
    let Some(intent_data) = intent.payload.get("_effectReservation") else {
        return EffectCommitResult {
            outcome: EffectCommitOutcome::Uncertain,
            current_sequence: current,
            replayed_from_journal: false,
            receipt: None,
        };
    };
    let effect_kind = intent_data
        .get("effectKind")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let kind = match execution.outcome {
        EffectExecutionOutcome::Committed => SessionEventKind::ChangeCommitted,
        EffectExecutionOutcome::Rejected => SessionEventKind::TerminalRecorded,
    };
    let draft = SessionEventDraft {
        kind,
        correlation: intent.correlation.clone(),
        occurred_at,
        payload: json!({
            "effectKind": effect_kind,
            "effectId": execution.effect_id,
            "outcome": execution.outcome,
            "metadata": execution.metadata,
        }),
    };
    let previous_digest = log
        .events
        .last()
        .map(|event| event.digest.as_str())
        .unwrap_or("");
    let event = SessionEvent::commit(current + 1, &draft, previous_digest, redactor);
    let receipt = EffectReceipt {
        session_id: reservation.session_id.clone(),
        idempotency_key: reservation.idempotency_key.clone(),
        effect_kind,
        effect_id: execution.effect_id,
        event_sequence: event.sequence,
        outcome: execution.outcome,
        metadata: redactor.redact(&execution.metadata),
    };
    log.events.push(event);
    log.pending.remove(&reservation.idempotency_key);
    log.request_digests.insert(
        reservation.idempotency_key.clone(),
        reservation.request_digest,
    );
    log.receipts
        .insert(reservation.idempotency_key, receipt.clone());
    EffectCommitResult {
        outcome: commit_outcome(receipt.outcome),
        current_sequence: current + 1,
        replayed_from_journal: false,
        receipt: Some(receipt),
    }
}

#[derive(Clone, Debug)]
struct EventRecordIndex {
    start_sequence: u64,
    end_sequence: u64,
    offset: u64,
    length: u64,
}

#[derive(Default)]
struct FileSessionIndex {
    scanned_bytes: u64,
    current_sequence: u64,
    last_digest: String,
    event_records: Vec<EventRecordIndex>,
    checkpoint: Option<SessionCheckpoint>,
    receipts: BTreeMap<String, EffectReceipt>,
    pending: HashMap<String, PendingEffect>,
    request_digests: HashMap<String, String>,
    permission_grants: BTreeMap<String, SessionPermissionGrantSnapshot>,
    corrupted_tail: bool,
}

pub struct FileSessionEventStore {
    root: PathBuf,
    redactor: SessionRedactor,
    max_batch_events: usize,
    max_event_bytes: usize,
    indexes: Mutex<HashMap<String, Arc<AsyncMutex<FileSessionIndex>>>>,
}

impl FileSessionEventStore {
    pub fn new(root: impl Into<PathBuf>, max_batch_events: usize, max_event_bytes: usize) -> Self {
        assert!(max_batch_events > 0 && max_event_bytes > 0);
        Self {
            root: root.into(),
            redactor: SessionRedactor::default(),
            max_batch_events,
            max_event_bytes,
            indexes: Mutex::new(HashMap::new()),
        }
    }

    fn index_for(&self, file_key: &str) -> Arc<AsyncMutex<FileSessionIndex>> {
        self.indexes
            .lock()
            .expect("session index lock poisoned")
            .entry(file_key.to_owned())
            .or_insert_with(|| Arc::new(AsyncMutex::new(FileSessionIndex::default())))
            .clone()
    }

    async fn with_session<T, F>(
        &self,
        session_id: String,
        create_root: bool,
        action: F,
    ) -> Result<T, SessionStoreError>
    where
        T: Send + 'static,
        F: FnOnce(&mut FileSessionIndex, &Path, &Path) -> Result<T, SessionStoreError>
            + Send
            + 'static,
    {
        let file_key = sha256_hex(session_id.as_bytes());
        let journal_path = self.root.join(format!("{file_key}.session.jsonl"));
        let lock_path = self.root.join(format!("{file_key}.lock"));
        let root = self.root.clone();
        let index = self.index_for(&file_key);
        tokio::task::spawn_blocking(move || {
            let mut index = index.blocking_lock();
            if create_root {
                fs::create_dir_all(&root).map_err(|_| SessionStoreError::Io)?;
            } else if !root.exists() {
                if index.scanned_bytes != 0 {
                    index.corrupted_tail = true;
                }
                return action(&mut index, &journal_path, &lock_path);
            }
            let lock_file = OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .open(&lock_path)
                .map_err(|_| SessionStoreError::Io)?;
            lock_file
                .lock_exclusive()
                .map_err(|_| SessionStoreError::Io)?;
            let result = (|| {
                index.refresh(&journal_path, &session_id)?;
                action(&mut index, &journal_path, &lock_path)
            })();
            let unlock_result = FileExt::unlock(&lock_file).map_err(|_| SessionStoreError::Io);
            match result {
                Err(error) => Err(error),
                Ok(value) => {
                    unlock_result?;
                    Ok(value)
                }
            }
        })
        .await
        .map_err(|_| SessionStoreError::WorkerFailed)?
    }
}

impl Default for FileSessionEventStore {
    fn default() -> Self {
        Self::new("sessions", 256, 65_536)
    }
}

#[async_trait]
impl SessionEventStore for FileSessionEventStore {
    async fn append(
        &self,
        session_id: &str,
        expected_sequence: u64,
        drafts: &[SessionEventDraft],
    ) -> Result<SessionAppendResult, SessionStoreError> {
        let session_id = session_id.to_owned();
        let drafts = drafts.to_vec();
        let redactor = self.redactor.clone();
        let max_batch_events = self.max_batch_events;
        let max_event_bytes = self.max_event_bytes;
        self.with_session(session_id.clone(), true, move |index, path, _| {
            let current = index.current_sequence;
            if index.corrupted_tail {
                return Ok(append_result(SessionAppendOutcome::CorruptedTail, current));
            }
            if expected_sequence != current {
                return Ok(append_result(
                    SessionAppendOutcome::SequenceConflict,
                    current,
                ));
            }
            if !valid_drafts(
                &session_id,
                &drafts,
                max_batch_events,
                max_event_bytes,
                &redactor,
            ) {
                return Ok(append_result(SessionAppendOutcome::InvalidEvent, current));
            }
            let mut previous_digest = index.last_digest.clone();
            let committed_events = drafts
                .iter()
                .enumerate()
                .map(|(offset, draft)| {
                    let event = SessionEvent::commit(
                        current + offset as u64 + 1,
                        draft,
                        previous_digest.clone(),
                        &redactor,
                    );
                    previous_digest = event.digest.clone();
                    event
                })
                .collect::<Vec<_>>();
            let record = json!({
                "schemaVersion": 1,
                "type": "eventBatch",
                "events": committed_events,
            });
            let (offset, length) = append_record(path, &record)?;
            index.apply_events(&session_id, &committed_events, offset, length)?;
            index.scanned_bytes = offset + length;
            Ok(SessionAppendResult {
                outcome: SessionAppendOutcome::Committed,
                current_sequence: index.current_sequence,
                committed_events,
            })
        })
        .await
    }

    async fn load(
        &self,
        session_id: &str,
        after_sequence: u64,
        max_events: usize,
    ) -> Result<SessionEventBatch, SessionStoreError> {
        if max_events == 0 {
            return Err(SessionStoreError::InvalidLimit);
        }
        let session_id = session_id.to_owned();
        self.with_session(session_id.clone(), false, move |index, path, _| {
            let current = index.current_sequence;
            let start_sequence = after_sequence.min(current);
            let mut events = Vec::new();
            if path.exists() {
                let mut file = File::open(path).map_err(|_| SessionStoreError::Io)?;
                for record_index in index
                    .event_records
                    .iter()
                    .filter(|record| record.end_sequence > start_sequence)
                {
                    file.seek(SeekFrom::Start(record_index.offset))
                        .map_err(|_| SessionStoreError::Io)?;
                    let mut line = vec![0; record_index.length as usize];
                    file.read_exact(&mut line)
                        .map_err(|_| SessionStoreError::Io)?;
                    let record: Value =
                        serde_json::from_slice(&line).map_err(|_| SessionStoreError::Encoding)?;
                    let record_events = parse_events(&record)?;
                    for event in record_events {
                        if event.sequence > start_sequence {
                            events.push(event);
                            if events.len() == max_events {
                                break;
                            }
                        }
                    }
                    if events.len() == max_events {
                        break;
                    }
                }
            }
            let next_sequence = start_sequence + events.len() as u64;
            Ok(SessionEventBatch {
                session_id,
                current_sequence: current,
                has_more: next_sequence < current,
                events,
                corrupted_tail: index.corrupted_tail,
            })
        })
        .await
    }

    async fn load_permission_grants(
        &self,
        session_id: &str,
    ) -> Result<Vec<SessionPermissionGrantSnapshot>, SessionStoreError> {
        self.with_session(session_id.to_owned(), false, move |index, _, _| {
            if index.corrupted_tail {
                // A damaged tail may hide a revocation; do not restore any
                // authority from the otherwise-valid prefix.
                return Err(SessionStoreError::Encoding);
            }
            let mut grants = index
                .permission_grants
                .values()
                .cloned()
                .collect::<Vec<_>>();
            grants.sort_by_key(|snapshot| snapshot.granted_sequence);
            Ok(grants)
        })
        .await
    }

    async fn save_checkpoint(
        &self,
        checkpoint: SessionCheckpoint,
    ) -> Result<(), SessionStoreError> {
        self.with_session(
            checkpoint.session_id.clone(),
            true,
            move |index, path, _| {
                if !checkpoint.is_valid()
                    || checkpoint.applied_sequence > index.current_sequence
                    || index.corrupted_tail
                {
                    return Err(SessionStoreError::Encoding);
                }
                let record = json!({
                    "schemaVersion": 1,
                    "type": "checkpoint",
                    "checkpoint": checkpoint,
                });
                let (offset, length) = append_record(path, &record)?;
                index.scanned_bytes = offset + length;
                index.checkpoint = Some(checkpoint);
                Ok(())
            },
        )
        .await
    }

    async fn load_checkpoint(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionCheckpoint>, SessionStoreError> {
        let session_id = session_id.to_owned();
        self.with_session(session_id, false, move |index, _, _| {
            Ok(index.checkpoint.clone())
        })
        .await
    }
}

#[async_trait]
impl EffectReceiptJournal for FileSessionEventStore {
    async fn begin_effect(
        &self,
        request: EffectRequest,
        correlation: SessionCorrelation,
        expected_sequence: u64,
        occurred_at: String,
    ) -> Result<EffectBeginResult, SessionStoreError> {
        let session_id = request.session_id.clone();
        let redactor = self.redactor.clone();
        let max_event_bytes = self.max_event_bytes;
        self.with_session(session_id.clone(), true, move |index, path, _| {
            let current = index.current_sequence;
            if index.corrupted_tail {
                return Ok(effect_begin_result(
                    EffectBeginOutcome::CorruptedTail,
                    current,
                ));
            }
            if !request.is_valid()
                || !correlation.is_valid()
                || request.session_id != correlation.session_id
                || canonical_utf8_len(&redactor.redact(&request.parameters)) > max_event_bytes
            {
                return Ok(effect_begin_result(EffectBeginOutcome::Rejected, current));
            }
            let digest = request.digest();
            if let Some(receipt) = index.receipts.get(&request.idempotency_key) {
                if index
                    .request_digests
                    .get(&request.idempotency_key)
                    .is_some_and(|existing| existing != &digest)
                {
                    return Ok(effect_begin_result(
                        EffectBeginOutcome::IdempotencyConflict,
                        current,
                    ));
                }
                return Ok(EffectBeginResult {
                    outcome: EffectBeginOutcome::Replay,
                    current_sequence: current,
                    reservation: None,
                    receipt: Some(receipt.clone()),
                });
            }
            if let Some(pending) = index.pending.get(&request.idempotency_key) {
                return Ok(effect_begin_result(
                    if pending.request_digest == digest {
                        EffectBeginOutcome::InProgress
                    } else {
                        EffectBeginOutcome::IdempotencyConflict
                    },
                    current,
                ));
            }
            if current != expected_sequence {
                return Ok(effect_begin_result(
                    EffectBeginOutcome::SequenceConflict,
                    current,
                ));
            }
            let draft = SessionEventDraft {
                kind: SessionEventKind::ToolCallRecorded,
                correlation,
                occurred_at,
                payload: json!({
                    "_effectReservation": {
                        "idempotencyKey": request.idempotency_key,
                        "requestDigest": digest,
                        "effectKind": request.effect_kind,
                        "parameters": request.parameters,
                    }
                }),
            };
            if canonical_utf8_len(&redactor.redact(&draft.payload)) > max_event_bytes {
                return Ok(effect_begin_result(EffectBeginOutcome::Rejected, current));
            }
            let event =
                SessionEvent::commit(current + 1, &draft, index.last_digest.clone(), &redactor);
            let record = json!({
                "schemaVersion": 1,
                "type": "eventBatch",
                "events": [event],
            });
            let (offset, length) = append_record(path, &record)?;
            let event = parse_events(&record)?
                .pop()
                .ok_or(SessionStoreError::Encoding)?;
            index.apply_events(&session_id, &[event.clone()], offset, length)?;
            index.scanned_bytes = offset + length;
            let reservation = EffectReservation {
                session_id,
                idempotency_key: request.idempotency_key,
                request_digest: digest,
                intent_sequence: event.sequence,
            };
            Ok(EffectBeginResult {
                outcome: EffectBeginOutcome::Started,
                current_sequence: event.sequence,
                reservation: Some(reservation),
                receipt: None,
            })
        })
        .await
    }

    async fn complete_effect(
        &self,
        reservation: EffectReservation,
        execution: EffectExecutionReceipt,
        occurred_at: String,
    ) -> Result<EffectCommitResult, SessionStoreError> {
        let session_id = reservation.session_id.clone();
        let redactor = self.redactor.clone();
        let max_event_bytes = self.max_event_bytes;
        self.with_session(session_id.clone(), true, move |index, path, _| {
            let current = index.current_sequence;
            if index.corrupted_tail {
                return Ok(effect_commit_result(
                    EffectCommitOutcome::CorruptedTail,
                    current,
                ));
            }
            if let Some(receipt) = index.receipts.get(&reservation.idempotency_key) {
                let matches = index
                    .request_digests
                    .get(&reservation.idempotency_key)
                    .is_none_or(|digest| digest == &reservation.request_digest);
                return Ok(EffectCommitResult {
                    outcome: if matches {
                        commit_outcome(receipt.outcome)
                    } else {
                        EffectCommitOutcome::IdempotencyConflict
                    },
                    current_sequence: current,
                    replayed_from_journal: matches,
                    receipt: Some(receipt.clone()),
                });
            }
            let Some(pending) = index.pending.get(&reservation.idempotency_key) else {
                return Ok(effect_commit_result(
                    EffectCommitOutcome::Uncertain,
                    current,
                ));
            };
            if pending.request_digest != reservation.request_digest
                || pending.intent_sequence != reservation.intent_sequence
            {
                return Ok(effect_commit_result(
                    EffectCommitOutcome::IdempotencyConflict,
                    current,
                ));
            }
            if execution.effect_id.trim().is_empty()
                || !execution.metadata.is_object()
                || canonical_utf8_len(&redactor.redact(&execution.metadata)) > max_event_bytes
            {
                return Ok(effect_commit_result(EffectCommitOutcome::Invalid, current));
            }
            let intent = index.read_event(path, reservation.intent_sequence)?;
            let intent_data = intent
                .payload
                .get("_effectReservation")
                .ok_or(SessionStoreError::Encoding)?;
            let effect_kind = intent_data
                .get("effectKind")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let event_kind = match execution.outcome {
                EffectExecutionOutcome::Committed => SessionEventKind::ChangeCommitted,
                EffectExecutionOutcome::Rejected => SessionEventKind::TerminalRecorded,
            };
            let draft = SessionEventDraft {
                kind: event_kind,
                correlation: intent.correlation,
                occurred_at,
                payload: json!({
                    "effectKind": effect_kind,
                    "effectId": execution.effect_id,
                    "outcome": execution.outcome,
                    "metadata": execution.metadata,
                }),
            };
            if canonical_utf8_len(&redactor.redact(&draft.payload)) > max_event_bytes {
                return Ok(effect_commit_result(EffectCommitOutcome::Invalid, current));
            }
            let event =
                SessionEvent::commit(current + 1, &draft, index.last_digest.clone(), &redactor);
            let receipt = EffectReceipt {
                session_id: session_id.clone(),
                idempotency_key: reservation.idempotency_key.clone(),
                effect_kind,
                effect_id: execution.effect_id,
                event_sequence: event.sequence,
                outcome: execution.outcome,
                metadata: redactor.redact(&execution.metadata),
            };
            let record = json!({
                "schemaVersion": 1,
                "type": "effect",
                "events": [event],
                "receipt": receipt,
            });
            let (offset, length) = append_record(path, &record)?;
            let parsed = parse_record_events_and_receipt(&record)?;
            index.apply_events(&session_id, &parsed.0, offset, length)?;
            index.apply_receipt(&session_id, parsed.1)?;
            index.scanned_bytes = offset + length;
            let receipt = index
                .receipts
                .get(&reservation.idempotency_key)
                .cloned()
                .ok_or(SessionStoreError::Encoding)?;
            Ok(EffectCommitResult {
                outcome: commit_outcome(receipt.outcome),
                current_sequence: index.current_sequence,
                replayed_from_journal: false,
                receipt: Some(receipt),
            })
        })
        .await
    }

    async fn find_effect_receipt(
        &self,
        session_id: &str,
        idempotency_key: &str,
    ) -> Result<Option<EffectReceipt>, SessionStoreError> {
        let key = idempotency_key.to_owned();
        self.with_session(session_id.to_owned(), false, move |index, _, _| {
            Ok(index.receipts.get(&key).cloned())
        })
        .await
    }

    async fn load_effect_receipts(
        &self,
        session_id: &str,
        max_receipts: usize,
    ) -> Result<Vec<EffectReceipt>, SessionStoreError> {
        if max_receipts == 0 {
            return Err(SessionStoreError::InvalidLimit);
        }
        self.with_session(session_id.to_owned(), false, move |index, _, _| {
            let mut receipts = index.receipts.values().cloned().collect::<Vec<_>>();
            receipts.sort_by_key(|receipt| receipt.event_sequence);
            receipts.truncate(max_receipts);
            Ok(receipts)
        })
        .await
    }
}

fn effect_commit_result(outcome: EffectCommitOutcome, current_sequence: u64) -> EffectCommitResult {
    EffectCommitResult {
        outcome,
        current_sequence,
        replayed_from_journal: false,
        receipt: None,
    }
}

impl FileSessionIndex {
    fn refresh(&mut self, journal_path: &Path, session_id: &str) -> Result<(), SessionStoreError> {
        let metadata = match fs::metadata(journal_path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return if self.scanned_bytes == 0 {
                    Ok(())
                } else {
                    self.corrupted_tail = true;
                    Ok(())
                };
            }
            Err(_) => return Err(SessionStoreError::Io),
        };
        if metadata.len() < self.scanned_bytes {
            self.corrupted_tail = true;
        }
        if self.corrupted_tail || metadata.len() == self.scanned_bytes {
            return Ok(());
        }
        let file = File::open(journal_path).map_err(|_| SessionStoreError::Io)?;
        let mut reader = BufReader::new(file);
        reader
            .seek(SeekFrom::Start(self.scanned_bytes))
            .map_err(|_| SessionStoreError::Io)?;
        let mut offset = self.scanned_bytes;
        loop {
            let record_offset = offset;
            let mut bytes = Vec::new();
            let read = reader
                .read_until(b'\n', &mut bytes)
                .map_err(|_| SessionStoreError::Io)?;
            if read == 0 {
                break;
            }
            offset += read as u64;
            self.scanned_bytes = offset;
            if bytes.last() != Some(&b'\n') {
                self.corrupted_tail = true;
                break;
            }
            bytes.pop();
            if bytes.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            let result = serde_json::from_slice::<Value>(&bytes)
                .map_err(|_| SessionStoreError::Encoding)
                .and_then(|record| {
                    self.apply_record(session_id, &record, record_offset, read as u64)
                });
            if result.is_err() {
                self.corrupted_tail = true;
                break;
            }
        }
        Ok(())
    }

    fn apply_record(
        &mut self,
        session_id: &str,
        record: &Value,
        offset: u64,
        length: u64,
    ) -> Result<(), SessionStoreError> {
        if record.get("schemaVersion").and_then(Value::as_u64) != Some(1) {
            return Err(SessionStoreError::Encoding);
        }
        match record.get("type").and_then(Value::as_str) {
            Some("checkpoint") => {
                let checkpoint: SessionCheckpoint = serde_json::from_value(
                    record
                        .get("checkpoint")
                        .cloned()
                        .ok_or(SessionStoreError::Encoding)?,
                )
                .map_err(|_| SessionStoreError::Encoding)?;
                if !checkpoint.is_valid()
                    || checkpoint.session_id != session_id
                    || checkpoint.applied_sequence > self.current_sequence
                {
                    return Err(SessionStoreError::Encoding);
                }
                self.checkpoint = Some(checkpoint);
            }
            Some("eventBatch") | Some("effect") => {
                let (events, receipt) =
                    if record.get("type").and_then(Value::as_str) == Some("effect") {
                        let (events, receipt) = parse_record_events_and_receipt(record)?;
                        (events, Some(receipt))
                    } else {
                        (parse_events(record)?, None)
                    };
                if events.is_empty() {
                    return Err(SessionStoreError::Encoding);
                }
                self.apply_events(session_id, &events, offset, length)?;
                if let Some(receipt) = receipt {
                    self.apply_receipt(session_id, receipt)?;
                }
            }
            _ => return Err(SessionStoreError::Encoding),
        }
        Ok(())
    }

    fn apply_events(
        &mut self,
        session_id: &str,
        events: &[SessionEvent],
        offset: u64,
        length: u64,
    ) -> Result<(), SessionStoreError> {
        let mut expected_sequence = self.current_sequence;
        let mut previous_digest = self.last_digest.as_str();
        let mut new_reservations = HashSet::new();
        for event in events {
            if event.session_id != session_id
                || event.sequence != expected_sequence + 1
                || event.previous_digest != previous_digest
                || !event.has_valid_digest()
            {
                return Err(SessionStoreError::Encoding);
            }
            if let Some(intent) = event.payload.get("_effectReservation") {
                if let (Some(key), Some(_request_digest)) = (
                    intent.get("idempotencyKey").and_then(Value::as_str),
                    intent.get("requestDigest").and_then(Value::as_str),
                ) {
                    if self.pending.contains_key(key)
                        || self.receipts.contains_key(key)
                        || !new_reservations.insert(key.to_owned())
                    {
                        return Err(SessionStoreError::Encoding);
                    }
                }
            }
            expected_sequence = event.sequence;
            previous_digest = &event.digest;
        }
        if let (Some(first), Some(last)) = (events.first(), events.last()) {
            self.event_records.push(EventRecordIndex {
                start_sequence: first.sequence,
                end_sequence: last.sequence,
                offset,
                length,
            });
        }
        for event in events {
            self.current_sequence = event.sequence;
            self.last_digest.clone_from(&event.digest);
            replay_permission_event(&mut self.permission_grants, event);
            if let Some(intent) = event.payload.get("_effectReservation") {
                if let (Some(key), Some(request_digest)) = (
                    intent.get("idempotencyKey").and_then(Value::as_str),
                    intent.get("requestDigest").and_then(Value::as_str),
                ) {
                    self.pending.insert(
                        key.to_owned(),
                        PendingEffect {
                            request_digest: request_digest.to_owned(),
                            intent_sequence: event.sequence,
                        },
                    );
                    self.request_digests
                        .insert(key.to_owned(), request_digest.to_owned());
                }
            }
        }
        Ok(())
    }

    fn apply_receipt(
        &mut self,
        session_id: &str,
        receipt: EffectReceipt,
    ) -> Result<(), SessionStoreError> {
        if receipt.session_id != session_id
            || receipt.idempotency_key.trim().is_empty()
            || receipt.event_sequence != self.current_sequence
            || self.receipts.contains_key(&receipt.idempotency_key)
        {
            return Err(SessionStoreError::Encoding);
        }
        if let Some(pending) = self.pending.remove(&receipt.idempotency_key) {
            self.request_digests
                .insert(receipt.idempotency_key.clone(), pending.request_digest);
        }
        self.receipts
            .insert(receipt.idempotency_key.clone(), receipt);
        Ok(())
    }

    fn read_event(&self, path: &Path, sequence: u64) -> Result<SessionEvent, SessionStoreError> {
        let record_index = self
            .event_records
            .iter()
            .find(|record| record.start_sequence <= sequence && record.end_sequence >= sequence)
            .ok_or(SessionStoreError::Encoding)?;
        let mut file = File::open(path).map_err(|_| SessionStoreError::Io)?;
        file.seek(SeekFrom::Start(record_index.offset))
            .map_err(|_| SessionStoreError::Io)?;
        let mut bytes = vec![0; record_index.length as usize];
        file.read_exact(&mut bytes)
            .map_err(|_| SessionStoreError::Io)?;
        let record: Value =
            serde_json::from_slice(&bytes).map_err(|_| SessionStoreError::Encoding)?;
        parse_events(&record)?
            .into_iter()
            .find(|event| event.sequence == sequence)
            .ok_or(SessionStoreError::Encoding)
    }
}

fn parse_events(record: &Value) -> Result<Vec<SessionEvent>, SessionStoreError> {
    record
        .get("events")
        .and_then(Value::as_array)
        .ok_or(SessionStoreError::Encoding)?
        .iter()
        .cloned()
        .map(|event| serde_json::from_value(event).map_err(|_| SessionStoreError::Encoding))
        .collect()
}

fn parse_record_events_and_receipt(
    record: &Value,
) -> Result<(Vec<SessionEvent>, EffectReceipt), SessionStoreError> {
    let events = parse_events(record)?;
    let receipt = serde_json::from_value(
        record
            .get("receipt")
            .cloned()
            .ok_or(SessionStoreError::Encoding)?,
    )
    .map_err(|_| SessionStoreError::Encoding)?;
    if events.is_empty() {
        return Err(SessionStoreError::Encoding);
    }
    Ok((events, receipt))
}

fn append_record(path: &Path, record: &Value) -> Result<(u64, u64), SessionStoreError> {
    let encoded = canonical_json(record);
    let mut bytes = encoded.into_bytes();
    bytes.push(b'\n');
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|_| SessionStoreError::Io)?;
    let offset = file.metadata().map_err(|_| SessionStoreError::Io)?.len();
    file.write_all(&bytes).map_err(|_| SessionStoreError::Io)?;
    file.sync_data().map_err(|_| SessionStoreError::Io)?;
    Ok((offset, bytes.len() as u64))
}

fn commit_outcome(outcome: EffectExecutionOutcome) -> EffectCommitOutcome {
    match outcome {
        EffectExecutionOutcome::Committed => EffectCommitOutcome::Committed,
        EffectExecutionOutcome::Rejected => EffectCommitOutcome::Rejected,
    }
}
