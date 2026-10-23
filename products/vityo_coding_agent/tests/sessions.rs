use std::{fs, io::Write};

use serde_json::{Value, json};
use vityo_coding_agent::sessions::{
    EffectBeginOutcome, EffectCommitOutcome, EffectExecutionOutcome, EffectExecutionReceipt,
    EffectReceiptJournal, EffectRequest, FileSessionEventStore, InMemorySessionEventStore,
    SessionAppendOutcome, SessionCheckpoint, SessionCorrelation, SessionEvent, SessionEventDraft,
    SessionEventKind, SessionEventStore, SessionPermissionGrant, SessionProjection,
    SessionProjector, SessionRecovery, SessionRecoveryStatus, SessionRedactor, canonical_json,
    compute_projection_digest,
};

const WHEN: &str = "2026-01-01T00:00:00.000Z";

#[test]
fn event_wire_names_and_digest_match_the_existing_dart_journal() {
    let draft = draft(
        SessionCorrelation::new("task", "persisted-session"),
        SessionEventKind::TurnRecorded,
        json!({ "value": "kept" }),
    );
    let event = SessionEvent::commit(1, &draft, "", &SessionRedactor::default());

    assert_eq!(
        event.digest,
        "4284c3c9ce64d7f92fe2222ebfdb46276c1501b69d5ec0052939a47873c62bbe"
    );
    let wire = serde_json::to_value(&event).unwrap();
    assert_eq!(wire["kind"], "turnRecorded");
    assert_eq!(wire["occurredAt"], WHEN);
    assert!(wire.get("session_id").is_none());
    let projection = SessionProjector::new(4)
        .unwrap()
        .project("persisted-session", [event], None, std::iter::empty())
        .unwrap();
    assert_eq!(
        compute_projection_digest(&projection),
        "211364af891ac49127996b219cc187e50863ec8641ed616fec0666b7de86707c"
    );
    assert_eq!(
        canonical_json(&json!({ "z": 1, "nested": { "y": 2, "a": 3 } })),
        r#"{"nested":{"a":3,"y":2},"z":1}"#
    );
}

#[tokio::test]
async fn append_redacts_payloads_orders_events_and_rejects_stale_writers() {
    let store = InMemorySessionEventStore::new(SessionRedactor::default(), 4, 1_024);
    let correlation = SessionCorrelation::new("task", "session");
    let first = store
        .append(
            "session",
            0,
            &[
                draft(
                    correlation.clone(),
                    SessionEventKind::GoalRecorded,
                    json!({ "token": "private", "nested": { "password": "private", "safe": "kept" } }),
                ),
                draft(
                    correlation.clone(),
                    SessionEventKind::TurnRecorded,
                    json!({ "turn": 1 }),
                ),
            ],
        )
        .await
        .unwrap();
    let stale = store
        .append(
            "session",
            0,
            &[draft(
                correlation,
                SessionEventKind::TurnRecorded,
                json!({ "turn": "stale" }),
            )],
        )
        .await
        .unwrap();

    assert_eq!(first.outcome, SessionAppendOutcome::Committed);
    assert_eq!(stale.outcome, SessionAppendOutcome::SequenceConflict);
    assert!(first.committed_events[0].has_valid_digest());
    assert_eq!(first.committed_events[0].payload["token"], "<redacted>");
    assert_eq!(
        first.committed_events[0].payload["nested"]["password"],
        "<redacted>"
    );
    assert_eq!(first.committed_events[0].payload["nested"]["safe"], "kept");

    let page = store.load("session", 0, 1).await.unwrap();
    assert_eq!(page.events.len(), 1);
    assert!(page.has_more);
    assert_eq!(page.current_sequence, 2);
    assert_eq!(page.events[0].sequence, 1);
}

#[test]
fn recovery_keeps_the_valid_prefix_and_reports_corrupt_or_excessive_tails() {
    let correlation = SessionCorrelation::new("task", "session");
    let redactor = SessionRedactor::default();
    let first_draft = draft(
        correlation.clone(),
        SessionEventKind::TurnRecorded,
        json!({ "value": "one" }),
    );
    let first = SessionEvent::commit(1, &first_draft, "", &redactor);
    let second = SessionEvent::commit(
        2,
        &draft(
            correlation,
            SessionEventKind::TurnRecorded,
            json!({ "value": "two" }),
        ),
        first.digest.clone(),
        &redactor,
    );
    let checkpoint_projection = SessionProjector::new(1)
        .unwrap()
        .project("session", [first.clone()], None, std::iter::empty())
        .unwrap();
    let checkpoint = SessionCheckpoint::from_projection(checkpoint_projection);
    let corrupt = SessionEvent {
        payload: json!({ "value": "tampered" }),
        ..second.clone()
    };

    let recovery = SessionRecovery::new(1, 4).unwrap();
    let recovered = recovery.recover(&checkpoint, [corrupt], std::iter::empty());
    assert_eq!(recovered.status, SessionRecoveryStatus::TailCorrupted);
    assert_eq!(recovered.projection.applied_sequence, 1);
    assert_eq!(recovered.failure_sequence, Some(2));

    let replay_limited = SessionRecovery::new(1, 0);
    assert!(replay_limited.is_err());
    let one_record_checkpoint =
        SessionCheckpoint::from_projection(SessionProjection::empty("session"));
    let limited = SessionRecovery::new(1, 1).unwrap().recover(
        &one_record_checkpoint,
        [first, second],
        std::iter::empty(),
    );
    assert_eq!(limited.status, SessionRecoveryStatus::ReplayLimitExceeded);
    assert_eq!(limited.projection.applied_sequence, 1);
    assert_eq!(limited.failure_sequence, Some(2));
}

#[tokio::test]
async fn file_store_preserves_and_reads_existing_v1_records_before_appending() {
    let root = tempfile::tempdir().unwrap();
    let session_id = "persisted-session";
    let file_key = "e2c78d7a55bc4745849ae0a7adc5a269bdc50413b3d61ee47bb32ad43aeefd2b";
    let original_line = br#"{"schemaVersion":1,"type":"eventBatch","events":[{"sessionId":"persisted-session","sequence":1,"kind":"turnRecorded","correlation":{"taskId":"task","sessionId":"persisted-session"},"occurredAt":"2026-01-01T00:00:00.000Z","payload":{"value":"kept"},"previousDigest":"","digest":"4284c3c9ce64d7f92fe2222ebfdb46276c1501b69d5ec0052939a47873c62bbe"}]}"#;
    let path = root.path().join(format!("{file_key}.session.jsonl"));
    fs::write(&path, [original_line.as_slice(), b"\n"].concat()).unwrap();
    let store = FileSessionEventStore::new(root.path(), 8, 4_096);
    let existing = store.load(session_id, 0, 8).await.unwrap();
    assert_eq!(existing.current_sequence, 1);
    assert_eq!(existing.events[0].payload["value"], "kept");

    let appended = store
        .append(
            session_id,
            1,
            &[draft(
                SessionCorrelation::new("task", session_id),
                SessionEventKind::TerminalRecorded,
                json!({ "state": "completed" }),
            )],
        )
        .await
        .unwrap();
    assert_eq!(appended.outcome, SessionAppendOutcome::Committed);
    let durable = fs::read(&path).unwrap();
    assert!(durable.starts_with(original_line));

    let projected = SessionProjector::new(4)
        .unwrap()
        .project(
            session_id,
            existing.events.into_iter().chain(appended.committed_events),
            None,
            std::iter::empty(),
        )
        .unwrap();
    let checkpoint = SessionCheckpoint::from_projection(projected);
    store.save_checkpoint(checkpoint.clone()).await.unwrap();
    let reopened = FileSessionEventStore::new(root.path(), 8, 4_096);
    assert_eq!(
        reopened.load_checkpoint(session_id).await.unwrap(),
        Some(checkpoint)
    );
}

#[tokio::test]
async fn concurrent_file_appends_serialize_by_session() {
    let root = tempfile::tempdir().unwrap();
    let first_store = FileSessionEventStore::new(root.path(), 4, 4_096);
    let second_store = FileSessionEventStore::new(root.path(), 4, 4_096);
    let correlation = SessionCorrelation::new("task", "concurrent");
    let first_draft = [draft(
        correlation.clone(),
        SessionEventKind::TurnRecorded,
        json!({ "writer": "first" }),
    )];
    let second_draft = [draft(
        correlation,
        SessionEventKind::TurnRecorded,
        json!({ "writer": "second" }),
    )];
    let first = first_store.append("concurrent", 0, &first_draft);
    let second = second_store.append("concurrent", 0, &second_draft);
    let (first, second) = tokio::join!(first, second);
    let outcomes = [first.unwrap().outcome, second.unwrap().outcome];
    assert_eq!(
        outcomes
            .iter()
            .filter(|outcome| **outcome == SessionAppendOutcome::Committed)
            .count(),
        1
    );
    assert_eq!(
        outcomes
            .iter()
            .filter(|outcome| **outcome == SessionAppendOutcome::SequenceConflict)
            .count(),
        1
    );
    assert_eq!(
        first_store
            .load("concurrent", 0, 4)
            .await
            .unwrap()
            .current_sequence,
        1
    );
}

#[tokio::test]
async fn interrupted_effects_remain_uncertain_and_completed_effects_replay() {
    let root = tempfile::tempdir().unwrap();
    let session_id = "effect-session";
    let correlation = SessionCorrelation::new("task", session_id);
    let request = EffectRequest {
        session_id: session_id.to_owned(),
        idempotency_key: "stable-effect".to_owned(),
        effect_kind: "write".to_owned(),
        parameters: json!({ "resource": "src/main.sty", "token": "private" }),
    };

    let store = FileSessionEventStore::new(root.path(), 8, 4_096);
    let begun = store
        .begin_effect(request.clone(), correlation.clone(), 0, WHEN.to_owned())
        .await
        .unwrap();
    assert_eq!(begun.outcome, EffectBeginOutcome::Started);
    let reservation = begun.reservation.unwrap();
    let in_progress = store
        .begin_effect(request.clone(), correlation.clone(), 1, WHEN.to_owned())
        .await
        .unwrap();
    assert_eq!(in_progress.outcome, EffectBeginOutcome::InProgress);

    // A new store instance represents a process restart after the adapter may
    // have acted but before it wrote its durable receipt.
    let restarted = FileSessionEventStore::new(root.path(), 8, 4_096);
    let uncertain = restarted
        .begin_effect(request.clone(), correlation.clone(), 1, WHEN.to_owned())
        .await
        .unwrap();
    assert_eq!(uncertain.outcome, EffectBeginOutcome::InProgress);
    assert!(uncertain.receipt.is_none());

    let committed = restarted
        .complete_effect(
            reservation,
            EffectExecutionReceipt {
                effect_id: "effect-1".to_owned(),
                outcome: EffectExecutionOutcome::Committed,
                metadata: json!({ "token": "private", "adapter": "fixture" }),
            },
            WHEN.to_owned(),
        )
        .await
        .unwrap();
    assert_eq!(committed.outcome, EffectCommitOutcome::Committed);
    assert_eq!(
        committed.receipt.as_ref().unwrap().metadata["token"],
        "<redacted>"
    );

    let reopened = FileSessionEventStore::new(root.path(), 8, 4_096);
    let replay = reopened
        .begin_effect(request.clone(), correlation.clone(), 2, WHEN.to_owned())
        .await
        .unwrap();
    assert_eq!(replay.outcome, EffectBeginOutcome::Replay);
    assert_eq!(replay.receipt.as_ref().unwrap().event_sequence, 2);
    let mut changed_request = request;
    changed_request.parameters = json!({ "resource": "src/other.sty" });
    let conflict = reopened
        .begin_effect(changed_request, correlation, 2, WHEN.to_owned())
        .await
        .unwrap();
    assert_eq!(conflict.outcome, EffectBeginOutcome::IdempotencyConflict);
}

#[tokio::test]
async fn permission_grants_reopen_revoke_and_preserve_session_and_root_scope() {
    let root = tempfile::tempdir().unwrap();
    let store = FileSessionEventStore::new(root.path(), 8, 4_096);
    let first = store
        .append_permission_grant(
            permission_grant("shared-id", "session-a", "source.edit", "write", "root-a"),
            SessionCorrelation::new("task-a", "session-a"),
            0,
            WHEN.to_owned(),
        )
        .await
        .unwrap();
    assert_eq!(first.outcome, SessionAppendOutcome::Committed);
    assert_eq!(
        first.committed_events[0].kind,
        SessionEventKind::PermissionRecorded
    );
    assert_eq!(first.committed_events[0].payload["action"], "grant");

    let second = store
        .append_permission_grant(
            permission_grant("other-root", "session-a", "source.read", "read", "root-b"),
            SessionCorrelation::new("task-a", "session-a"),
            1,
            WHEN.to_owned(),
        )
        .await
        .unwrap();
    assert_eq!(second.current_sequence, 2);
    let regranted = store
        .append_permission_grant(
            permission_grant("shared-id", "session-a", "source.edit", "write", "root-a"),
            SessionCorrelation::new("task-a", "session-a"),
            2,
            WHEN.to_owned(),
        )
        .await
        .unwrap();
    assert_eq!(regranted.current_sequence, 3);
    let other_session = store
        .append_permission_grant(
            permission_grant("shared-id", "session-b", "source.read", "read", "root-b"),
            SessionCorrelation::new("task-b", "session-b"),
            0,
            WHEN.to_owned(),
        )
        .await
        .unwrap();
    assert_eq!(other_session.current_sequence, 1);

    let reopened = FileSessionEventStore::new(root.path(), 8, 4_096);
    let session_a = reopened.load_permission_grants("session-a").await.unwrap();
    assert_eq!(session_a.len(), 2);
    assert_eq!(session_a[0].grant.id, "other-root");
    assert_eq!(session_a[0].granted_sequence, 2);
    assert_eq!(
        session_a[0]
            .grant
            .root_ids
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        ["root-b"]
    );
    assert_eq!(session_a[1].grant.id, "shared-id");
    assert_eq!(session_a[1].granted_sequence, 3);
    assert_eq!(
        session_a[1]
            .grant
            .risks
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        ["write"]
    );
    assert_eq!(
        session_a[1]
            .grant
            .root_ids
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        ["root-a"]
    );
    let session_b = reopened.load_permission_grants("session-b").await.unwrap();
    assert_eq!(session_b.len(), 1);
    assert_eq!(session_b[0].grant.session_id, "session-b");
    assert_eq!(session_b[0].grant.id, "shared-id");
    assert_eq!(
        session_b[0]
            .grant
            .root_ids
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        ["root-b"]
    );

    let revoked = reopened
        .append_permission_revocation(
            "session-a",
            "shared-id",
            SessionCorrelation::new("task-a", "session-a"),
            3,
            WHEN.to_owned(),
        )
        .await
        .unwrap();
    assert_eq!(revoked.current_sequence, 4);
    let recovered = FileSessionEventStore::new(root.path(), 8, 4_096);
    let session_a_after_revoke = recovered.load_permission_grants("session-a").await.unwrap();
    assert_eq!(session_a_after_revoke.len(), 1);
    assert_eq!(session_a_after_revoke[0].grant.id, "other-root");
    assert_eq!(
        recovered.load_permission_grants("session-b").await.unwrap()[0]
            .grant
            .id,
        "shared-id"
    );
}

#[tokio::test]
async fn in_memory_permission_grants_use_the_same_append_and_replay_contract() {
    let store = InMemorySessionEventStore::default();
    let appended = store
        .append_permission_grant(
            permission_grant("grant", "session", "source.write", "write", "root"),
            SessionCorrelation::new("task", "session"),
            0,
            WHEN.to_owned(),
        )
        .await
        .unwrap();
    assert_eq!(appended.outcome, SessionAppendOutcome::Committed);
    assert_eq!(
        store.load_permission_grants("session").await.unwrap().len(),
        1
    );

    let revoked = store
        .append_permission_revocation(
            "session",
            "grant",
            SessionCorrelation::new("task", "session"),
            1,
            WHEN.to_owned(),
        )
        .await
        .unwrap();
    assert_eq!(revoked.current_sequence, 2);
    assert!(
        store
            .load_permission_grants("session")
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn corrupt_final_record_is_reported_and_never_overwritten() {
    let root = tempfile::tempdir().unwrap();
    let store = FileSessionEventStore::new(root.path(), 4, 4_096);
    store
        .append(
            "safe-session",
            0,
            &[draft(
                SessionCorrelation::new("task", "safe-session"),
                SessionEventKind::GoalRecorded,
                json!({ "goal": "safe" }),
            )],
        )
        .await
        .unwrap();
    store
        .append_permission_grant(
            permission_grant("safe-grant", "safe-session", "source.read", "read", "root"),
            SessionCorrelation::new("task", "safe-session"),
            1,
            WHEN.to_owned(),
        )
        .await
        .unwrap();
    let file_key = "7f4adef3cae5e50f9ad9e60f06aa7adc44bf81bed0bb57438b8bf123c05fcdf6";
    let path = root.path().join(format!("{file_key}.session.jsonl"));
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    file.write_all(b"{\"schemaVersion\":1").unwrap();
    file.sync_data().unwrap();
    let corrupted_before = fs::read(&path).unwrap();

    let restarted = FileSessionEventStore::new(root.path(), 4, 4_096);
    let loaded = restarted.load("safe-session", 0, 4).await.unwrap();
    assert!(loaded.corrupted_tail);
    assert_eq!(loaded.current_sequence, 2);
    assert_eq!(
        restarted.load_permission_grants("safe-session").await,
        Err(vityo_coding_agent::sessions::SessionStoreError::Encoding)
    );
    let rejected = restarted
        .append(
            "safe-session",
            2,
            &[draft(
                SessionCorrelation::new("task", "safe-session"),
                SessionEventKind::TurnRecorded,
                json!({ "should": "not append" }),
            )],
        )
        .await
        .unwrap();
    assert_eq!(rejected.outcome, SessionAppendOutcome::CorruptedTail);
    assert_eq!(fs::read(path).unwrap(), corrupted_before);
}

fn permission_grant(
    id: &str,
    session_id: &str,
    tool_id: &str,
    risk: &str,
    root_id: &str,
) -> SessionPermissionGrant {
    SessionPermissionGrant {
        id: id.to_owned(),
        session_id: session_id.to_owned(),
        tool_id: tool_id.to_owned(),
        risks: [risk.to_owned()].into_iter().collect(),
        root_ids: [root_id.to_owned()].into_iter().collect(),
    }
}

fn draft(
    correlation: SessionCorrelation,
    kind: SessionEventKind,
    payload: Value,
) -> SessionEventDraft {
    SessionEventDraft::new(kind, correlation, WHEN, payload).unwrap()
}
