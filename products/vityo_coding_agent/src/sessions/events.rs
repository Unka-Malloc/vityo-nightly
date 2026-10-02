//! Append-only event and projection types shared by the Agent runtime.
//!
//! The JSON field names and canonical digest input match the existing Dart
//! session journal so the Rust runtime can continue reading persisted records.

use std::collections::{BTreeMap, VecDeque};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::EffectReceipt;

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionEventKind {
    GoalRecorded,
    TurnRecorded,
    PlanRecorded,
    StepRecorded,
    ToolCallRecorded,
    PermissionRecorded,
    ChangeCommitted,
    ValidationRecorded,
    BudgetRecorded,
    TerminalRecorded,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCorrelation {
    pub task_id: String,
    pub session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub step_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
}

impl SessionCorrelation {
    pub fn new(task_id: impl Into<String>, session_id: impl Into<String>) -> Self {
        Self {
            task_id: task_id.into(),
            session_id: session_id.into(),
            turn_id: None,
            plan_id: None,
            step_id: None,
            operation_id: None,
        }
    }

    pub fn is_valid(&self) -> bool {
        !self.task_id.trim().is_empty() && !self.session_id.trim().is_empty()
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEventDraft {
    pub kind: SessionEventKind,
    pub correlation: SessionCorrelation,
    /// RFC 3339 timestamp normalized to UTC, matching Dart `toUtc().toIso8601String()`.
    pub occurred_at: String,
    pub payload: Value,
}

impl SessionEventDraft {
    pub fn new(
        kind: SessionEventKind,
        correlation: SessionCorrelation,
        occurred_at: impl Into<String>,
        payload: Value,
    ) -> Result<Self, EventValidationError> {
        if !correlation.is_valid() || !payload.is_object() {
            return Err(EventValidationError::InvalidDraft);
        }
        let occurred_at = occurred_at.into();
        if occurred_at.trim().is_empty() {
            return Err(EventValidationError::InvalidDraft);
        }
        Ok(Self {
            kind,
            correlation,
            occurred_at,
            payload,
        })
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEvent {
    pub session_id: String,
    pub sequence: u64,
    pub kind: SessionEventKind,
    pub correlation: SessionCorrelation,
    pub occurred_at: String,
    pub payload: Value,
    pub previous_digest: String,
    pub digest: String,
}

impl SessionEvent {
    pub fn commit(
        sequence: u64,
        draft: &SessionEventDraft,
        previous_digest: impl Into<String>,
        redactor: &SessionRedactor,
    ) -> Self {
        let previous_digest = previous_digest.into();
        let payload = redactor.redact(&draft.payload);
        let mut event = Self {
            session_id: draft.correlation.session_id.clone(),
            sequence,
            kind: draft.kind,
            correlation: draft.correlation.clone(),
            occurred_at: draft.occurred_at.clone(),
            payload,
            previous_digest,
            digest: String::new(),
        };
        event.digest = event.compute_digest();
        event
    }

    pub fn has_valid_digest(&self) -> bool {
        self.digest == self.compute_digest()
    }

    fn compute_digest(&self) -> String {
        let value = json!({
            "sessionId": self.session_id,
            "sequence": self.sequence,
            "kind": self.kind,
            "correlation": self.correlation,
            "occurredAt": self.occurred_at,
            "payload": self.payload,
            "previousDigest": self.previous_digest,
        });
        sha256_hex(canonical_json(&value).as_bytes())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EventValidationError {
    InvalidDraft,
    InvalidChain,
    InvalidProjection,
}

#[derive(Clone, Debug)]
pub struct SessionRedactor {
    sensitive_keys: Vec<String>,
}

impl Default for SessionRedactor {
    fn default() -> Self {
        Self::new([
            "authorization",
            "password",
            "token",
            "secret",
            "credential",
            "api_key",
        ])
    }
}

impl SessionRedactor {
    pub fn new(keys: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            sensitive_keys: keys.into_iter().map(Into::into).collect(),
        }
    }

    pub fn redact(&self, value: &Value) -> Value {
        self.redact_value(value)
    }

    fn redact_value(&self, value: &Value) -> Value {
        match value {
            Value::Object(map) => {
                let mut redacted = Map::new();
                for (key, value) in map {
                    redacted.insert(
                        key.clone(),
                        if self.is_sensitive(key) {
                            Value::String("<redacted>".to_owned())
                        } else {
                            self.redact_value(value)
                        },
                    );
                }
                Value::Object(redacted)
            }
            Value::Array(values) => Value::Array(
                values
                    .iter()
                    .map(|value| self.redact_value(value))
                    .collect(),
            ),
            _ => value.clone(),
        }
    }

    fn is_sensitive(&self, key: &str) -> bool {
        let key = normalize_sensitive_key(key);
        self.sensitive_keys.iter().any(|candidate| {
            let candidate = normalize_sensitive_key(candidate);
            key == candidate || key.ends_with(&candidate)
        })
    }
}

fn normalize_sensitive_key(key: &str) -> String {
    key.chars()
        .filter(|character| !matches!(character, '-' | '_') && !character.is_whitespace())
        .flat_map(char::to_lowercase)
        .collect()
}

pub fn canonical_json(value: &Value) -> String {
    serde_json::to_string(&canonicalize(value)).expect("JSON values always serialize")
}

fn canonicalize(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let sorted = map.iter().collect::<BTreeMap<_, _>>();
            let mut output = Map::new();
            for (key, value) in sorted {
                output.insert(key.clone(), canonicalize(value));
            }
            Value::Object(output)
        }
        Value::Array(values) => Value::Array(values.iter().map(canonicalize).collect()),
        _ => value.clone(),
    }
}

pub fn canonical_utf8_len(value: &Value) -> usize {
    canonical_json(value).len()
}

pub fn utc_now_rfc3339() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let seconds = now.as_secs() as i64;
    let days = seconds.div_euclid(86_400);
    let day_seconds = seconds.rem_euclid(86_400);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 }.div_euclid(146_097);
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    let hour = day_seconds / 3_600;
    let minute = day_seconds % 3_600 / 60;
    let second = day_seconds % 60;
    format!(
        "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{millis:03}Z",
        millis = now.subsec_millis()
    )
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        write!(&mut output, "{byte:02x}").expect("writing into String cannot fail");
    }
    output
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionProjection {
    pub session_id: String,
    pub applied_sequence: u64,
    pub last_event_digest: String,
    pub latest_by_kind: BTreeMap<SessionEventKind, SessionEvent>,
    pub hot_events: VecDeque<SessionEvent>,
    pub effect_receipts: BTreeMap<String, EffectReceipt>,
}

impl SessionProjection {
    pub fn empty(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            applied_sequence: 0,
            last_event_digest: String::new(),
            latest_by_kind: BTreeMap::new(),
            hot_events: VecDeque::new(),
            effect_receipts: BTreeMap::new(),
        }
    }

    fn digest_value(&self) -> Value {
        let latest = self
            .latest_by_kind
            .iter()
            .map(|(kind, event)| (kind.as_str().to_owned(), json!(event.digest)))
            .collect::<Map<_, _>>();
        let effects = self
            .effect_receipts
            .iter()
            .map(|(key, receipt)| {
                (
                    key.clone(),
                    json!({
                        "effectId": receipt.effect_id,
                        "eventSequence": receipt.event_sequence,
                        "outcome": receipt.outcome,
                    }),
                )
            })
            .collect::<Map<_, _>>();
        json!({
            "sessionId": self.session_id,
            "appliedSequence": self.applied_sequence,
            "lastEventDigest": self.last_event_digest,
            "latestByKind": latest,
            "hotEvents": self.hot_events.iter().map(|event| event.digest.clone()).collect::<Vec<_>>(),
            "effectReceipts": effects,
        })
    }
}

impl SessionEventKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::GoalRecorded => "goalRecorded",
            Self::TurnRecorded => "turnRecorded",
            Self::PlanRecorded => "planRecorded",
            Self::StepRecorded => "stepRecorded",
            Self::ToolCallRecorded => "toolCallRecorded",
            Self::PermissionRecorded => "permissionRecorded",
            Self::ChangeCommitted => "changeCommitted",
            Self::ValidationRecorded => "validationRecorded",
            Self::BudgetRecorded => "budgetRecorded",
            Self::TerminalRecorded => "terminalRecorded",
        }
    }
}

#[derive(Clone, Debug)]
pub struct SessionProjector {
    max_hot_events: usize,
}

impl SessionProjector {
    pub fn new(max_hot_events: usize) -> Result<Self, EventValidationError> {
        if max_hot_events == 0 {
            return Err(EventValidationError::InvalidProjection);
        }
        Ok(Self { max_hot_events })
    }

    pub fn project(
        &self,
        session_id: &str,
        events: impl IntoIterator<Item = SessionEvent>,
        base: Option<SessionProjection>,
        effect_receipts: impl IntoIterator<Item = EffectReceipt>,
    ) -> Result<SessionProjection, EventValidationError> {
        let mut projection = base.unwrap_or_else(|| SessionProjection::empty(session_id));
        if projection.session_id != session_id {
            return Err(EventValidationError::InvalidProjection);
        }
        for event in events {
            if event.session_id != session_id
                || event.sequence != projection.applied_sequence + 1
                || event.previous_digest != projection.last_event_digest
                || !event.has_valid_digest()
            {
                return Err(EventValidationError::InvalidChain);
            }
            projection.latest_by_kind.insert(event.kind, event.clone());
            projection.hot_events.push_back(event.clone());
            if projection.hot_events.len() > self.max_hot_events {
                projection.hot_events.pop_front();
            }
            projection.applied_sequence = event.sequence;
            projection.last_event_digest = event.digest;
        }
        for receipt in effect_receipts {
            if receipt.session_id == session_id
                && receipt.event_sequence <= projection.applied_sequence
            {
                projection
                    .effect_receipts
                    .insert(receipt.idempotency_key.clone(), receipt);
            }
        }
        Ok(projection)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCheckpoint {
    pub session_id: String,
    pub applied_sequence: u64,
    pub last_event_digest: String,
    pub projection: SessionProjection,
    pub projection_digest: String,
}

impl SessionCheckpoint {
    pub fn from_projection(projection: SessionProjection) -> Self {
        let projection_digest = compute_projection_digest(&projection);
        Self {
            session_id: projection.session_id.clone(),
            applied_sequence: projection.applied_sequence,
            last_event_digest: projection.last_event_digest.clone(),
            projection,
            projection_digest,
        }
    }

    pub fn is_valid(&self) -> bool {
        self.session_id == self.projection.session_id
            && self.applied_sequence == self.projection.applied_sequence
            && self.last_event_digest == self.projection.last_event_digest
            && self.projection_digest == compute_projection_digest(&self.projection)
    }
}

pub fn compute_projection_digest(projection: &SessionProjection) -> String {
    sha256_hex(canonical_json(&projection.digest_value()).as_bytes())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionRecoveryStatus {
    Recovered,
    TailCorrupted,
    CheckpointInvalid,
    SequenceConflict,
    ReplayLimitExceeded,
}

#[derive(Clone, Debug)]
pub struct RecoveredSession {
    pub status: SessionRecoveryStatus,
    pub projection: SessionProjection,
    pub failure_sequence: Option<u64>,
}

#[derive(Clone, Debug)]
pub struct SessionRecovery {
    max_hot_events: usize,
    max_replay_events: usize,
}

impl SessionRecovery {
    pub fn new(
        max_hot_events: usize,
        max_replay_events: usize,
    ) -> Result<Self, EventValidationError> {
        if max_hot_events == 0 || max_replay_events == 0 {
            return Err(EventValidationError::InvalidProjection);
        }
        Ok(Self {
            max_hot_events,
            max_replay_events,
        })
    }

    pub fn recover(
        &self,
        checkpoint: &SessionCheckpoint,
        event_tail: impl IntoIterator<Item = SessionEvent>,
        effect_receipts: impl IntoIterator<Item = EffectReceipt>,
    ) -> RecoveredSession {
        if !checkpoint.is_valid() {
            return RecoveredSession {
                status: SessionRecoveryStatus::CheckpointInvalid,
                projection: SessionProjection::empty(checkpoint.session_id.clone()),
                failure_sequence: None,
            };
        }
        let mut projection = checkpoint.projection.clone();
        let projector = SessionProjector::new(self.max_hot_events).expect("validated limit");
        let mut replayed = 0;
        for event in event_tail {
            if replayed >= self.max_replay_events {
                return RecoveredSession {
                    status: SessionRecoveryStatus::ReplayLimitExceeded,
                    projection,
                    failure_sequence: Some(event.sequence),
                };
            }
            if event.session_id != checkpoint.session_id
                || event.sequence != projection.applied_sequence + 1
            {
                return RecoveredSession {
                    status: SessionRecoveryStatus::SequenceConflict,
                    projection,
                    failure_sequence: Some(event.sequence),
                };
            }
            if event.previous_digest != projection.last_event_digest || !event.has_valid_digest() {
                return RecoveredSession {
                    status: SessionRecoveryStatus::TailCorrupted,
                    projection,
                    failure_sequence: Some(event.sequence),
                };
            }
            projection = projector
                .project(&checkpoint.session_id, [event], Some(projection), [])
                .expect("event validated above");
            replayed += 1;
        }
        projection = projector
            .project(
                &checkpoint.session_id,
                [],
                Some(projection),
                effect_receipts,
            )
            .expect("empty projection is valid");
        RecoveredSession {
            status: SessionRecoveryStatus::Recovered,
            projection,
            failure_sequence: None,
        }
    }
}
