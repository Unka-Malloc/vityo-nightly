use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{
        Arc, Mutex as StdMutex, RwLock,
        atomic::{AtomicUsize, Ordering},
    },
};

use async_trait::async_trait;
use futures::poll;
use serde_json::{Value, json};
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;
use vityo_coding_agent::{
    contracts::JsonObject,
    policy::{ExecutionPolicy, PermissionGrant, PermissionGrantStore, ToolRoot},
    tools::{
        ExecutionHook, McpClient, McpFailure, McpFailureCode, McpToolMetadata, McpToolPolicy,
        McpToolSource, SecretResolver, ToolAdapter, ToolAdapterError, ToolCall, ToolCatalog,
        ToolDescriptor, ToolExecutionContext, ToolExecutionLimits, ToolExecutor, ToolPathDomain,
        ToolPathRequest, ToolPathResolution, ToolPathResolver, ToolRisk, ToolSchema,
        ToolSourceKind,
    },
};

fn schema(properties: Value, required: &[&str], additional_properties: bool) -> JsonObject {
    serde_json::from_value(json!({
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": additional_properties,
    }))
    .unwrap()
}

fn descriptor(
    id: &str,
    input_schema: JsonObject,
    output_schema: JsonObject,
    risk: ToolRisk,
    max_result_bytes: usize,
    path_argument: Option<&str>,
    secret_arguments: BTreeMap<String, String>,
) -> ToolDescriptor {
    ToolDescriptor::new(
        id,
        id,
        ToolSourceKind::Builtin,
        input_schema,
        output_schema,
        risk,
        ["test".to_owned()],
        path_argument.map(str::to_owned),
        None,
        secret_arguments,
        max_result_bytes,
    )
    .unwrap()
}

fn executor(
    descriptor: ToolDescriptor,
    adapter: Arc<dyn ToolAdapter>,
    hooks: Vec<Arc<dyn ExecutionHook>>,
) -> ToolExecutor {
    ToolExecutor::new(
        ToolCatalog::new("catalog-1", [descriptor.clone()], false).unwrap(),
        BTreeMap::from([(descriptor.id.clone(), adapter)]),
        hooks,
        ToolExecutionLimits::new(4, 2, 4096).unwrap(),
    )
}

fn context(
    session_id: &str,
    tool_id: &str,
    risk: ToolRisk,
    cancellation: CancellationToken,
) -> ToolExecutionContext {
    let mut grants = PermissionGrantStore::new(8).unwrap();
    grants.grant(
        PermissionGrant::new("grant", session_id, tool_id, [risk], ["root".to_owned()]).unwrap(),
    );
    ToolExecutionContext {
        session_id: session_id.to_owned(),
        cancellation,
        deadline: None,
        roots: vec![ToolRoot::resource_uri("root", "workspace://project/").unwrap()],
        policy: ExecutionPolicy::new(1, [risk], [], 4096).unwrap(),
        grants: Arc::new(RwLock::new(grants)),
        path_resolver: None,
        secret_resolver: None,
    }
}

fn call(arguments: JsonObject, idempotency_key: Option<&str>) -> ToolCall {
    ToolCall {
        call_id: "call".to_owned(),
        tool_id: "test.tool".to_owned(),
        catalog_version: "catalog-1".to_owned(),
        arguments,
        idempotency_key: idempotency_key.map(str::to_owned),
    }
}

fn object(values: Value) -> JsonObject {
    values.as_object().unwrap().clone()
}

#[test]
fn catalog_ranking_is_stable_and_schema_rejects_unknown_properties() {
    let mut first = descriptor(
        "z.search",
        schema(json!({}), &[], false),
        schema(json!({}), &[], true),
        ToolRisk::Read,
        256,
        None,
        BTreeMap::new(),
    );
    first.tags.insert("search".to_owned());
    let second = ToolDescriptor::new(
        "a.search",
        "search",
        ToolSourceKind::Builtin,
        schema(json!({}), &[], false),
        schema(json!({}), &[], true),
        ToolRisk::Read,
        ["search".to_owned(), "code".to_owned()],
        None,
        None,
        BTreeMap::new(),
        256,
    )
    .unwrap();
    let catalog = ToolCatalog::new("v1", [first, second], false).unwrap();
    let ranked = catalog.relevant_for(&BTreeSet::from(["search".to_owned()]), 2);
    assert_eq!(ranked[0].id, "a.search");
    assert_eq!(ranked[1].id, "z.search");
    assert!(!ToolSchema::accepts(
        &catalog.find("a.search").unwrap().input_schema,
        &json!({"unknown": true}),
    ));
}

#[tokio::test]
async fn same_authorized_in_flight_effect_is_shared_and_cached() {
    let adapter = Arc::new(ControlledAdapter::new(json!({"ok": true}), true));
    let tool = descriptor(
        "test.tool",
        schema(json!({}), &[], false),
        schema(json!({"ok": {"type": "boolean"}}), &[], false),
        ToolRisk::Write,
        256,
        None,
        BTreeMap::new(),
    );
    let executor = executor(tool, adapter.clone(), Vec::new());
    let cancellation = CancellationToken::new();
    let first_started = adapter.started.notified();
    let first = tokio::spawn({
        let executor = executor.clone();
        let context = context(
            "session",
            "test.tool",
            ToolRisk::Write,
            cancellation.clone(),
        );
        async move {
            executor
                .execute(call(object(json!({})), Some("effect")), context)
                .await
        }
    });
    first_started.await;

    let second = executor.execute(
        call(object(json!({})), Some("effect")),
        context("session", "test.tool", ToolRisk::Write, cancellation),
    );
    tokio::pin!(second);
    assert!(poll!(second.as_mut()).is_pending());
    adapter.release.notify_one();

    let first_result = first.await.unwrap();
    let second_result = second.await;
    assert!(first_result.succeeded());
    assert!(!first_result.reused);
    assert!(second_result.succeeded());
    assert!(second_result.reused);
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 1);

    let cached = executor
        .execute(
            call(object(json!({})), Some("effect")),
            context(
                "session",
                "test.tool",
                ToolRisk::Write,
                CancellationToken::new(),
            ),
        )
        .await;
    assert!(cached.reused);
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn preflight_exposes_exact_permission_scope_and_executes_after_grant() {
    let adapter = Arc::new(ControlledAdapter::new(json!({"ok": true}), false));
    let tool = descriptor(
        "test.tool",
        schema(json!({}), &[], false),
        schema(json!({"ok": {"type": "boolean"}}), &[], false),
        ToolRisk::Write,
        256,
        None,
        BTreeMap::new(),
    );
    let executor = executor(tool, adapter.clone(), Vec::new());
    let context = context(
        "session",
        "test.tool",
        ToolRisk::Write,
        CancellationToken::new(),
    );
    context.grants.write().unwrap().revoke("grant");

    let preflight = executor
        .preflight(call(object(json!({})), Some("approved-effect")), &context)
        .await
        .unwrap();
    let requirement = preflight.permission_requirement().unwrap();
    assert_eq!(requirement.tool_id, "test.tool");
    assert_eq!(requirement.risk, ToolRisk::Write);
    assert_eq!(requirement.root_id, "root");
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 0);

    context.grants.write().unwrap().grant(
        PermissionGrant::new(
            "approved-grant",
            "session",
            "test.tool",
            [ToolRisk::Write],
            ["root".to_owned()],
        )
        .unwrap(),
    );
    let receipt = executor.execute_prepared(preflight, context).await;
    assert!(receipt.succeeded());
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn prepared_call_revalidates_live_workspace_resolution_before_effect() {
    let adapter = Arc::new(ControlledAdapter::new(json!({"ok": true}), false));
    let tool = descriptor(
        "test.tool",
        schema(json!({"path": {"type": "string"}}), &["path"], false),
        schema(json!({"ok": {"type": "boolean"}}), &[], false),
        ToolRisk::Write,
        256,
        Some("path"),
        BTreeMap::new(),
    );
    let executor = executor(tool, adapter.clone(), Vec::new());
    let mut context = context(
        "session",
        "test.tool",
        ToolRisk::Write,
        CancellationToken::new(),
    );
    context.grants.write().unwrap().revoke("grant");
    context.path_resolver = Some(Arc::new(StaticPathResolver(
        "workspace://project/src/main.sty".to_owned(),
    )));
    let preflight = executor
        .preflight(
            call(
                object(json!({"path": "workspace://project/src/link.sty"})),
                Some("approved-effect"),
            ),
            &context,
        )
        .await
        .unwrap();
    assert_eq!(preflight.permission_requirement().unwrap().root_id, "root");
    context.grants.write().unwrap().grant(
        PermissionGrant::new(
            "approved-grant",
            "session",
            "test.tool",
            [ToolRisk::Write],
            ["root".to_owned()],
        )
        .unwrap(),
    );
    context.path_resolver = Some(Arc::new(StaticPathResolver(
        "workspace://outside/secrets.sty".to_owned(),
    )));

    let receipt = executor.execute_prepared(preflight, context).await;
    assert_eq!(
        receipt.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::PolicyDenied
    );
    assert_eq!(
        receipt.effect_state,
        vityo_coding_agent::tools::EffectState::None
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn host_managed_write_keeps_the_absolute_acp_path_for_dispatch() {
    let raw_path = "/workspace/project/src/new-file.sty";
    let adapter = Arc::new(PathRecordingAdapter::default());
    let resolver = Arc::new(RecordingHostPathResolver {
        root_id: "flow-hero".to_owned(),
        relative_path: "src/new-file.sty".to_owned(),
        requests: StdMutex::new(Vec::new()),
    });
    let tool = descriptor(
        "fs.write",
        schema(json!({"path": {"type": "string"}}), &["path"], false),
        schema(json!({"path": {"type": "string"}}), &["path"], false),
        ToolRisk::Write,
        256,
        Some("path"),
        BTreeMap::new(),
    )
    .with_path_domain(ToolPathDomain::HostManaged)
    .unwrap();
    let executor = executor(tool, adapter.clone(), Vec::new());
    let mut context = context(
        "session",
        "fs.write",
        ToolRisk::Write,
        CancellationToken::new(),
    );
    context.roots = vec![ToolRoot::host_managed("flow-hero").unwrap()];
    context.grants.write().unwrap().revoke("grant");
    context.grants.write().unwrap().grant(
        PermissionGrant::new(
            "host-grant",
            "session",
            "fs.write",
            [ToolRisk::Write],
            ["flow-hero".to_owned()],
        )
        .unwrap(),
    );
    context.path_resolver = Some(resolver.clone());

    let mut call = call(object(json!({"path": raw_path})), None);
    call.tool_id = "fs.write".to_owned();
    call.call_id = "acp-call".to_owned();
    let receipt = executor.execute(call, context).await;

    assert!(receipt.succeeded());
    assert_eq!(
        receipt.output.get("path").and_then(Value::as_str),
        Some(raw_path)
    );
    let requests = resolver.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        3,
        "scope is checked during preflight and both execution validation steps"
    );
    for request in requests.iter() {
        assert_eq!(request.session_id, "session");
        assert_eq!(request.call_id, "acp-call");
        assert_eq!(request.domain, ToolPathDomain::HostManaged);
        assert_eq!(request.original_path, raw_path);
    }
}

#[tokio::test]
async fn host_managed_path_escape_is_denied_before_the_adapter_runs() {
    let adapter = Arc::new(PathRecordingAdapter::default());
    let tool = descriptor(
        "fs.write",
        schema(json!({"path": {"type": "string"}}), &["path"], false),
        schema(json!({"path": {"type": "string"}}), &["path"], false),
        ToolRisk::Write,
        256,
        Some("path"),
        BTreeMap::new(),
    )
    .with_path_domain(ToolPathDomain::HostManaged)
    .unwrap();
    let executor = executor(tool, adapter.clone(), Vec::new());
    let mut context = context(
        "session",
        "fs.write",
        ToolRisk::Write,
        CancellationToken::new(),
    );
    context.roots = vec![ToolRoot::host_managed("flow-hero").unwrap()];
    context.path_resolver = Some(Arc::new(RecordingHostPathResolver {
        root_id: "flow-hero".to_owned(),
        relative_path: "../outside.sty".to_owned(),
        requests: StdMutex::new(Vec::new()),
    }));

    let mut call = call(
        object(json!({"path": "/workspace/project/../outside.sty"})),
        None,
    );
    call.tool_id = "fs.write".to_owned();
    let receipt = executor.execute(call, context).await;

    assert_eq!(
        receipt.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::PolicyDenied
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn hooks_cannot_rewrite_the_absolute_host_managed_dispatch_path() {
    let adapter = Arc::new(PathRecordingAdapter::default());
    let tool = descriptor(
        "fs.read",
        schema(json!({"path": {"type": "string"}}), &["path"], false),
        schema(json!({"path": {"type": "string"}}), &["path"], false),
        ToolRisk::Read,
        256,
        Some("path"),
        BTreeMap::new(),
    )
    .with_path_domain(ToolPathDomain::HostManaged)
    .unwrap();
    let resolver = Arc::new(RecordingHostPathResolver {
        root_id: "flow-hero".to_owned(),
        relative_path: "src/main.sty".to_owned(),
        requests: StdMutex::new(Vec::new()),
    });
    let executor = ToolExecutor::new(
        ToolCatalog::new("catalog-1", [tool], false).unwrap(),
        BTreeMap::from([(
            "fs.read".to_owned(),
            adapter.clone() as Arc<dyn ToolAdapter>,
        )]),
        vec![Arc::new(RewritePathHook)],
        ToolExecutionLimits::new(2, 2, 1024).unwrap(),
    );
    let mut context = context(
        "session",
        "fs.read",
        ToolRisk::Read,
        CancellationToken::new(),
    );
    context.roots = vec![ToolRoot::host_managed("flow-hero").unwrap()];
    context.path_resolver = Some(resolver.clone());
    let mut call = call(
        object(json!({"path": "/workspace/project/src/main.sty"})),
        None,
    );
    call.tool_id = "fs.read".to_owned();

    let failure = match executor.preflight(call, &context).await {
        Err(failure) => failure,
        Ok(_) => panic!("host-managed hook rewrite should be rejected"),
    };

    assert_eq!(
        failure.code,
        vityo_coding_agent::tools::ToolFailureCode::HookRejected
    );
    assert!(resolver.requests.lock().unwrap().is_empty());
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn preflight_reports_hard_policy_denial_without_a_permission_prompt() {
    let adapter = Arc::new(ControlledAdapter::new(json!({"ok": true}), false));
    let tool = descriptor(
        "test.tool",
        schema(json!({}), &[], false),
        schema(json!({"ok": {"type": "boolean"}}), &[], false),
        ToolRisk::Write,
        256,
        None,
        BTreeMap::new(),
    );
    let executor = executor(tool, adapter.clone(), Vec::new());
    let mut context = context(
        "session",
        "test.tool",
        ToolRisk::Write,
        CancellationToken::new(),
    );
    context.policy.allowed_risks = BTreeSet::from([ToolRisk::Read]);

    let failure = executor
        .preflight(call(object(json!({})), None), &context)
        .await
        .err()
        .unwrap();
    assert_eq!(
        failure.code,
        vityo_coding_agent::tools::ToolFailureCode::PolicyDenied
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn prepared_call_rejects_a_replaced_catalog_before_effect() {
    let adapter = Arc::new(ControlledAdapter::new(json!({"ok": true}), false));
    let tool = descriptor(
        "test.tool",
        schema(json!({}), &[], false),
        schema(json!({"ok": {"type": "boolean"}}), &[], false),
        ToolRisk::Write,
        256,
        None,
        BTreeMap::new(),
    );
    let executor = executor(tool.clone(), adapter.clone(), Vec::new());
    let context = context(
        "session",
        "test.tool",
        ToolRisk::Write,
        CancellationToken::new(),
    );
    let preflight = executor
        .preflight(call(object(json!({})), None), &context)
        .await
        .unwrap();
    executor.replace_tools(
        ToolCatalog::new("catalog-2", [tool.clone()], false).unwrap(),
        BTreeMap::from([(
            "test.tool".to_owned(),
            adapter.clone() as Arc<dyn ToolAdapter>,
        )]),
    );

    let receipt = executor.execute_prepared(preflight, context).await;
    assert_eq!(
        receipt.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::ToolRemoved
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn idempotency_conflict_and_revocation_do_not_replay_effects() {
    let adapter = Arc::new(ControlledAdapter::new(json!({"ok": true}), false));
    let tool = descriptor(
        "test.tool",
        schema(json!({"value": {"type": "string"}}), &["value"], false),
        schema(json!({"ok": {"type": "boolean"}}), &[], false),
        ToolRisk::Write,
        256,
        None,
        BTreeMap::new(),
    );
    let executor = executor(tool, adapter.clone(), Vec::new());
    let denied_context = context(
        "session",
        "test.tool",
        ToolRisk::Write,
        CancellationToken::new(),
    );
    denied_context.grants.write().unwrap().revoke("grant");
    let denied = executor
        .execute(
            call(object(json!({"value": "one"})), Some("effect")),
            denied_context,
        )
        .await;
    assert_eq!(
        denied.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::PermissionDenied
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 0);

    let allowed = executor
        .execute(
            call(object(json!({"value": "one"})), Some("effect")),
            context(
                "session",
                "test.tool",
                ToolRisk::Write,
                CancellationToken::new(),
            ),
        )
        .await;
    assert!(allowed.succeeded());
    let conflict = executor
        .execute(
            call(object(json!({"value": "two"})), Some("effect")),
            context(
                "session",
                "test.tool",
                ToolRisk::Write,
                CancellationToken::new(),
            ),
        )
        .await;
    assert_eq!(
        conflict.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::IdempotencyConflict
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn stale_catalog_and_schema_fail_before_adapter_invocation() {
    let adapter = Arc::new(ControlledAdapter::new(json!({"ok": true}), false));
    let tool = descriptor(
        "test.tool",
        schema(json!({"value": {"type": "string"}}), &["value"], false),
        schema(json!({"ok": {"type": "boolean"}}), &[], false),
        ToolRisk::Read,
        256,
        None,
        BTreeMap::new(),
    );
    let executor = executor(tool.clone(), adapter.clone(), Vec::new());
    let invalid = executor
        .execute(
            call(object(json!({"unknown": true})), None),
            context(
                "session",
                "test.tool",
                ToolRisk::Read,
                CancellationToken::new(),
            ),
        )
        .await;
    assert_eq!(
        invalid.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::SchemaInvalid
    );

    executor.replace_tools(
        ToolCatalog::new("catalog-2", [tool.clone()], false).unwrap(),
        BTreeMap::from([(
            "test.tool".to_owned(),
            adapter.clone() as Arc<dyn ToolAdapter>,
        )]),
    );
    let stale = executor
        .execute(
            call(object(json!({"value": "ok"})), None),
            context(
                "session",
                "test.tool",
                ToolRisk::Read,
                CancellationToken::new(),
            ),
        )
        .await;
    assert_eq!(
        stale.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::ToolRemoved
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn hooks_and_resolved_workspace_paths_fail_closed() {
    let adapter = Arc::new(ControlledAdapter::new(json!({"ok": true}), false));
    let tool = descriptor(
        "test.tool",
        schema(json!({"path": {"type": "string"}}), &["path"], false),
        schema(json!({"ok": {"type": "boolean"}}), &[], false),
        ToolRisk::Read,
        256,
        Some("path"),
        BTreeMap::new(),
    );
    let rejecting_executor = executor(tool.clone(), adapter.clone(), vec![Arc::new(RejectHook)]);
    let rejected = rejecting_executor
        .execute(
            call(
                object(json!({"path": "workspace://project/src/main.sty"})),
                None,
            ),
            context(
                "session",
                "test.tool",
                ToolRisk::Read,
                CancellationToken::new(),
            ),
        )
        .await;
    assert_eq!(
        rejected.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::HookRejected
    );

    let executor = executor(tool, adapter.clone(), Vec::new());
    let mut context = context(
        "session",
        "test.tool",
        ToolRisk::Read,
        CancellationToken::new(),
    );
    context.path_resolver = Some(Arc::new(StaticPathResolver(
        "workspace://outside/secrets.sty".to_owned(),
    )));
    let denied = executor
        .execute(
            call(
                object(json!({"path": "workspace://project/src/link.sty"})),
                None,
            ),
            context,
        )
        .await;
    assert_eq!(
        denied.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::PolicyDenied
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn cancellation_and_uncertain_effects_are_not_retried() {
    let adapter = Arc::new(ControlledAdapter::new(json!({"ok": true}), true));
    let tool = descriptor(
        "test.tool",
        schema(json!({}), &[], false),
        schema(json!({"ok": {"type": "boolean"}}), &[], false),
        ToolRisk::Write,
        256,
        None,
        BTreeMap::new(),
    );
    let executor = executor(tool, adapter.clone(), Vec::new());
    let already_cancelled = CancellationToken::new();
    already_cancelled.cancel();
    let not_started = executor
        .execute(
            call(object(json!({})), Some("not-started")),
            context("session", "test.tool", ToolRisk::Write, already_cancelled),
        )
        .await;
    assert_eq!(
        not_started.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::Cancelled
    );
    assert_eq!(
        not_started.effect_state,
        vityo_coding_agent::tools::EffectState::None
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 0);

    let cancellation = CancellationToken::new();
    let started = adapter.started.notified();
    let first = tokio::spawn({
        let executor = executor.clone();
        let cancellation = cancellation.clone();
        async move {
            executor
                .execute(
                    call(object(json!({})), Some("effect")),
                    context("session", "test.tool", ToolRisk::Write, cancellation),
                )
                .await
        }
    });
    started.await;
    cancellation.cancel();
    let failed = first.await.unwrap();
    assert_eq!(
        failed.effect_state,
        vityo_coding_agent::tools::EffectState::Uncertain
    );
    let replayed = executor
        .execute(
            call(object(json!({})), Some("effect")),
            context(
                "session",
                "test.tool",
                ToolRisk::Write,
                CancellationToken::new(),
            ),
        )
        .await;
    assert!(replayed.reused);
    assert_eq!(
        replayed.effect_state,
        vityo_coding_agent::tools::EffectState::Uncertain
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn cancellation_after_adapter_commit_is_reported_as_committed() {
    let adapter = Arc::new(ControlledAdapter::new(json!({"ok": true}), false));
    let hook = Arc::new(BlockingAfterHook::default());
    let tool = descriptor(
        "test.tool",
        schema(json!({}), &[], false),
        schema(json!({"ok": {"type": "boolean"}}), &[], false),
        ToolRisk::Write,
        256,
        None,
        BTreeMap::new(),
    );
    let executor = executor(tool, adapter.clone(), vec![hook.clone()]);
    let cancellation = CancellationToken::new();
    let started = hook.started.notified();
    let execution = tokio::spawn({
        let executor = executor.clone();
        let cancellation = cancellation.clone();
        async move {
            executor
                .execute(
                    call(object(json!({})), None),
                    context("session", "test.tool", ToolRisk::Write, cancellation),
                )
                .await
        }
    });
    started.await;
    cancellation.cancel();
    let receipt = execution.await.unwrap();
    assert_eq!(
        receipt.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::Cancelled
    );
    assert_eq!(
        receipt.effect_state,
        vityo_coding_agent::tools::EffectState::Committed
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn secret_references_are_resolved_only_after_authorization_and_redacted() {
    let adapter = Arc::new(EchoAdapter::default());
    let tool = descriptor(
        "test.tool",
        schema(
            json!({"credential": {"type": "string"}}),
            &["credential"],
            false,
        ),
        schema(
            json!({
                "credential": {"type": "string"},
                "message": {"type": "string"}
            }),
            &["credential", "message"],
            false,
        ),
        ToolRisk::Credential,
        512,
        None,
        BTreeMap::from([("credential".to_owned(), "service".to_owned())]),
    );
    let executor = executor(tool, adapter.clone(), Vec::new());
    let mut context = context(
        "session",
        "test.tool",
        ToolRisk::Credential,
        CancellationToken::new(),
    );
    context.secret_resolver = Some(Arc::new(FixedSecret("synthetic-secret-value".to_owned()))); // placeholder fixture
    let receipt = executor
        .execute(
            call(
                object(json!({"credential": "secret://fixture?audience=service"})), // placeholder URI
                Some("secret-effect"),
            ),
            context,
        )
        .await;
    assert!(receipt.succeeded());
    assert_eq!(receipt.output["credential"], json!("[redacted]"));
    assert_eq!(receipt.output["message"], json!("[redacted]"));
    assert!(
        !serde_json::to_string(&receipt.output)
            .unwrap()
            .contains("synthetic-secret-value")
    );
}

#[tokio::test]
async fn prepared_call_rechecks_revocation_after_async_secret_resolution() {
    let adapter = Arc::new(ControlledAdapter::new(json!({"ok": true}), false));
    let tool = descriptor(
        "test.tool",
        schema(
            json!({"credential": {"type": "string"}}),
            &["credential"],
            false,
        ),
        schema(json!({"ok": {"type": "boolean"}}), &[], false),
        ToolRisk::Credential,
        256,
        None,
        BTreeMap::from([("credential".to_owned(), "service".to_owned())]),
    );
    let executor = executor(tool, adapter.clone(), Vec::new());
    let mut context = context(
        "session",
        "test.tool",
        ToolRisk::Credential,
        CancellationToken::new(),
    );
    let grants = context.grants.clone();
    let started = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());
    context.secret_resolver = Some(Arc::new(BlockingSecret {
        started: started.clone(),
        release: release.clone(),
    }));
    let preflight = executor
        .preflight(
            call(
                object(json!({"credential": "secret://fixture?audience=service"})), // placeholder URI
                Some("revocable-secret-effect"),
            ),
            &context,
        )
        .await
        .unwrap();
    assert!(preflight.permission_requirement().is_none());

    let execution = tokio::spawn({
        let executor = executor.clone();
        async move { executor.execute_prepared(preflight, context).await }
    });
    started.notified().await;
    grants.write().unwrap().revoke("grant");
    release.notify_one();

    let receipt = execution.await.unwrap();
    assert_eq!(
        receipt.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::PermissionDenied
    );
    assert_eq!(
        receipt.effect_state,
        vityo_coding_agent::tools::EffectState::None
    );
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn invalid_and_oversized_results_are_committed_receipts() {
    let adapter = Arc::new(ControlledAdapter::new(
        json!({"text": "large-result"}),
        false,
    ));
    let tool = descriptor(
        "test.tool",
        schema(json!({}), &[], false),
        schema(json!({"text": {"type": "string"}}), &["text"], false),
        ToolRisk::Write,
        12,
        None,
        BTreeMap::new(),
    );
    let executor = executor(tool, adapter.clone(), Vec::new());
    let first = executor
        .execute(
            call(object(json!({})), Some("effect")),
            context(
                "session",
                "test.tool",
                ToolRisk::Write,
                CancellationToken::new(),
            ),
        )
        .await;
    assert_eq!(
        first.failure.unwrap().code,
        vityo_coding_agent::tools::ToolFailureCode::ResultTooLarge
    );
    assert_eq!(
        first.effect_state,
        vityo_coding_agent::tools::EffectState::Committed
    );
    let retry = executor
        .execute(
            call(object(json!({})), Some("effect")),
            context(
                "session",
                "test.tool",
                ToolRisk::Write,
                CancellationToken::new(),
            ),
        )
        .await;
    assert!(retry.reused);
    assert_eq!(adapter.calls.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn mcp_metadata_defaults_to_destructive_and_uses_trusted_local_override() {
    let client = Arc::new(FakeMcpClient {
        tools: vec![McpToolMetadata {
            name: "lookup".to_owned(),
            description: "Lookup fixture".to_owned(),
            input_schema: schema(json!({"query": {"type": "string"}}), &["query"], false),
            output_schema: Some(schema(json!({"ok": {"type": "boolean"}}), &["ok"], false)),
        }],
        calls: AtomicUsize::new(0),
    });
    let source = McpToolSource::new(
        "fixture-server",
        client.clone(),
        4,
        1024,
        BTreeMap::from([(
            "lookup".to_owned(),
            McpToolPolicy {
                risk: Some(ToolRisk::Read),
                tags: BTreeSet::from(["search".to_owned()]),
                ..McpToolPolicy::default()
            },
        )]),
    )
    .unwrap();
    let snapshot = source.refresh(CancellationToken::new()).await.unwrap();
    let descriptor = snapshot.catalog.tools().next().unwrap();
    assert_eq!(descriptor.risk, ToolRisk::Read);
    assert!(descriptor.tags.contains("mcp"));
    assert!(descriptor.tags.contains("search"));
    let id = descriptor.id.clone();
    let context = context("session", &id, ToolRisk::Read, CancellationToken::new());
    let mut adapters = snapshot.adapters;
    let adapter = adapters.remove(&id).unwrap();
    let executor = ToolExecutor::new(
        snapshot.catalog,
        BTreeMap::from([(id.clone(), adapter)]),
        Vec::new(),
        ToolExecutionLimits::new(2, 2, 1024).unwrap(),
    );
    let receipt = executor
        .execute(
            ToolCall {
                call_id: "mcp-call".to_owned(),
                tool_id: id,
                catalog_version: "mcp/fixture-server/1".to_owned(),
                arguments: object(json!({"query": "safe"})),
                idempotency_key: Some("mcp-effect".to_owned()),
            },
            context,
        )
        .await;
    assert!(receipt.succeeded());
    assert_eq!(receipt.output["ok"], json!(true));
    assert_eq!(client.calls.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn mcp_schema_and_result_bounds_fail_closed() {
    let invalid_client = Arc::new(FakeMcpClient {
        tools: vec![McpToolMetadata {
            name: "bad".to_owned(),
            description: "invalid schema".to_owned(),
            input_schema: object(json!({"type": "array"})),
            output_schema: None,
        }],
        calls: AtomicUsize::new(0),
    });
    let invalid_source =
        McpToolSource::new("server", invalid_client, 2, 1024, BTreeMap::new()).unwrap();
    match invalid_source.refresh(CancellationToken::new()).await {
        Err(error) => assert_eq!(error.code, McpFailureCode::SchemaInvalid),
        Ok(_) => panic!("invalid MCP schema was accepted"),
    }

    let large_client = Arc::new(FakeMcpClient {
        tools: vec![McpToolMetadata {
            name: "large".to_owned(),
            description: "large schema".to_owned(),
            input_schema: schema(json!({"query": {"type": "string"}}), &["query"], false),
            output_schema: None,
        }],
        calls: AtomicUsize::new(0),
    });
    let large_source = McpToolSource::new("server", large_client, 2, 8, BTreeMap::new()).unwrap();
    match large_source.refresh(CancellationToken::new()).await {
        Err(error) => assert_eq!(error.code, McpFailureCode::ResponseTooLarge),
        Ok(_) => panic!("oversized MCP schema was accepted"),
    }
}

#[derive(Default)]
struct EchoAdapter {
    calls: AtomicUsize,
}

#[async_trait]
impl ToolAdapter for EchoAdapter {
    async fn execute(
        &self,
        _descriptor: &ToolDescriptor,
        arguments: JsonObject,
        _cancellation: CancellationToken,
    ) -> Result<JsonObject, ToolAdapterError> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        let credential = arguments.get("credential").cloned().unwrap_or(Value::Null);
        let credential_text = credential.as_str().unwrap_or("").to_owned();
        Ok(object(json!({
            "credential": credential,
            "message": format!("prefix {credential_text} suffix"),
        })))
    }
}

struct ControlledAdapter {
    output: JsonObject,
    block: bool,
    calls: AtomicUsize,
    started: Notify,
    release: Notify,
}

#[derive(Default)]
struct PathRecordingAdapter {
    calls: AtomicUsize,
}

#[async_trait]
impl ToolAdapter for PathRecordingAdapter {
    async fn execute(
        &self,
        _descriptor: &ToolDescriptor,
        arguments: JsonObject,
        _cancellation: CancellationToken,
    ) -> Result<JsonObject, ToolAdapterError> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        Ok(object(
            json!({"path": arguments.get("path").cloned().unwrap_or(Value::Null)}),
        ))
    }
}

impl ControlledAdapter {
    fn new(output: Value, block: bool) -> Self {
        Self {
            output: output.as_object().unwrap().clone(),
            block,
            calls: AtomicUsize::new(0),
            started: Notify::new(),
            release: Notify::new(),
        }
    }
}

#[async_trait]
impl ToolAdapter for ControlledAdapter {
    async fn execute(
        &self,
        _descriptor: &ToolDescriptor,
        _arguments: JsonObject,
        _cancellation: CancellationToken,
    ) -> Result<JsonObject, ToolAdapterError> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        if self.block {
            let release = self.release.notified();
            self.started.notify_one();
            release.await;
        }
        Ok(self.output.clone())
    }
}

struct RejectHook;

#[async_trait]
impl ExecutionHook for RejectHook {
    async fn before(
        &self,
        _descriptor: &ToolDescriptor,
        _arguments: JsonObject,
        _cancellation: CancellationToken,
    ) -> Result<JsonObject, ()> {
        Err(())
    }

    async fn after(
        &self,
        _descriptor: &ToolDescriptor,
        output: JsonObject,
        _cancellation: CancellationToken,
    ) -> Result<JsonObject, ()> {
        Ok(output)
    }
}

struct RewritePathHook;

#[async_trait]
impl ExecutionHook for RewritePathHook {
    async fn before(
        &self,
        _descriptor: &ToolDescriptor,
        mut arguments: JsonObject,
        _cancellation: CancellationToken,
    ) -> Result<JsonObject, ()> {
        arguments.insert(
            "path".to_owned(),
            Value::String("/workspace/other-file.sty".to_owned()),
        );
        Ok(arguments)
    }

    async fn after(
        &self,
        _descriptor: &ToolDescriptor,
        output: JsonObject,
        _cancellation: CancellationToken,
    ) -> Result<JsonObject, ()> {
        Ok(output)
    }
}

#[derive(Default)]
struct BlockingAfterHook {
    started: Notify,
}

#[async_trait]
impl ExecutionHook for BlockingAfterHook {
    async fn before(
        &self,
        _descriptor: &ToolDescriptor,
        arguments: JsonObject,
        _cancellation: CancellationToken,
    ) -> Result<JsonObject, ()> {
        Ok(arguments)
    }

    async fn after(
        &self,
        _descriptor: &ToolDescriptor,
        output: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, ()> {
        self.started.notify_one();
        cancellation.cancelled().await;
        Ok(output)
    }
}

struct StaticPathResolver(String);

#[async_trait]
impl ToolPathResolver for StaticPathResolver {
    async fn resolve(
        &self,
        request: ToolPathRequest,
        _cancellation: CancellationToken,
    ) -> Result<ToolPathResolution, ()> {
        (request.domain == ToolPathDomain::ResourceUri)
            .then(|| ToolPathResolution::ResourceUri {
                resolved_uri: self.0.clone(),
            })
            .ok_or(())
    }
}

struct RecordingHostPathResolver {
    root_id: String,
    relative_path: String,
    requests: StdMutex<Vec<ToolPathRequest>>,
}

#[async_trait]
impl ToolPathResolver for RecordingHostPathResolver {
    async fn resolve(
        &self,
        request: ToolPathRequest,
        _cancellation: CancellationToken,
    ) -> Result<ToolPathResolution, ()> {
        if request.domain != ToolPathDomain::HostManaged {
            return Err(());
        }
        self.requests.lock().unwrap().push(request);
        Ok(ToolPathResolution::HostManaged {
            root_id: self.root_id.clone(),
            relative_path: self.relative_path.clone(),
        })
    }
}

struct FixedSecret(String);

#[async_trait]
impl SecretResolver for FixedSecret {
    async fn resolve(
        &self,
        _reference: &str,
        audience: &str,
        _cancellation: CancellationToken,
    ) -> Option<String> {
        (audience == "service").then(|| self.0.clone())
    }
}

struct BlockingSecret {
    started: Arc<Notify>,
    release: Arc<Notify>,
}

#[async_trait]
impl SecretResolver for BlockingSecret {
    async fn resolve(
        &self,
        _reference: &str,
        audience: &str,
        _cancellation: CancellationToken,
    ) -> Option<String> {
        self.started.notify_one();
        self.release.notified().await;
        (audience == "service").then(|| "synthetic-secret-value".to_owned()) // placeholder fixture
    }
}

struct FakeMcpClient {
    tools: Vec<McpToolMetadata>,
    calls: AtomicUsize,
}

#[async_trait]
impl McpClient for FakeMcpClient {
    async fn list_tools(
        &self,
        _max_tools: usize,
        _cancellation: CancellationToken,
    ) -> Result<Vec<McpToolMetadata>, McpFailure> {
        Ok(self.tools.clone())
    }

    async fn call_tool(
        &self,
        _name: &str,
        _arguments: JsonObject,
        _cancellation: CancellationToken,
    ) -> Result<JsonObject, McpFailure> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        Ok(object(json!({"ok": true})))
    }
}
