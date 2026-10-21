//! ACP operation adapters used by the first-party ReAct runtime.

use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    future::Future,
    path::{Component, Path, PathBuf},
    sync::{Arc, RwLock},
};

use agent_client_protocol::{
    Client, ConnectionTo,
    schema::v1::{
        PermissionOption, PermissionOptionId, PermissionOptionKind, ReadTextFileRequest,
        RequestPermissionOutcome, RequestPermissionRequest, ToolCallUpdate, ToolCallUpdateFields,
        ToolKind,
    },
};
use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;

use crate::{
    application::AgentSession,
    cancellation::AgentCancellationToken,
    contracts::JsonObject,
    orchestration::{ReActToolRuntime, RuntimeEffectState, RuntimeToolError, ToolObservation},
    policy::{ExecutionPolicy, PermissionGrant, PermissionGrantStore, ToolRoot},
    protocol::types::{
        VityoWorkspaceChangeOutcome, VityoWorkspaceChangeProposal,
        VityoWorkspaceChangeProposalRequest, WorkspaceSnapshot, workspace_snapshot_from_error_data,
        workspace_snapshot_from_meta,
    },
    sessions::{
        EffectBeginOutcome, EffectCommitOutcome, EffectExecutionOutcome, EffectExecutionReceipt,
        EffectRequest, utc_now_rfc3339,
    },
    tools::{
        EffectState, ToolAdapter, ToolAdapterError, ToolCall, ToolCatalog, ToolDescriptor,
        ToolExecutionContext, ToolExecutionLimits, ToolExecutor, ToolPathDomain, ToolPathRequest,
        ToolPathResolution, ToolPathResolver, ToolPreflight, ToolRisk, ToolSourceKind,
    },
};

use super::terminal::build_terminal_tools;

pub const VITYO_HOST_ROOT_ID: &str = "flow-hero";
const TOOL_CATALOG_VERSION: &str = "vityo-acp-v1";
const MAX_SNAPSHOTS: usize = 128;
const MAX_TOOL_RESULT_BYTES: usize = 256 * 1024;

const READ_FILE: &str = "fs/read_text_file";
const WRITE_FILE: &str = "fs/write_text_file";
const CHANGE_PROPOSAL: &str = "_vityo.dev/workspace-change-proposal";

#[derive(Clone)]
pub(crate) struct SessionOperations {
    executor: ToolExecutor,
    grants: Arc<RwLock<PermissionGrantStore>>,
    path_resolver: Arc<SessionPathResolver>,
    roots: Vec<ToolRoot>,
    connection: ConnectionTo<Client>,
    session_id: String,
    proposal_enabled: bool,
    definitions: Vec<crate::providers::ModelToolDefinition>,
}

impl SessionOperations {
    pub(crate) fn new(
        connection: ConnectionTo<Client>,
        session_id: String,
        cwd: PathBuf,
        additional_directories: Vec<PathBuf>,
        filesystem_read: bool,
        filesystem_write: bool,
        terminal_enabled: bool,
        proposal_enabled: bool,
        restored_grants: Vec<PermissionGrant>,
    ) -> Result<Self, OperationSetupError> {
        let mut workspace_roots = Vec::with_capacity(additional_directories.len() + 1);
        workspace_roots.push(cwd.clone());
        workspace_roots.extend(additional_directories);
        if workspace_roots.iter().any(|path| !path.is_absolute()) {
            return Err(OperationSetupError::InvalidWorkspaceRoot);
        }
        let path_resolver = Arc::new(SessionPathResolver {
            roots: workspace_roots,
            root_id: VITYO_HOST_ROOT_ID.to_owned(),
        });
        let root = ToolRoot::host_managed(VITYO_HOST_ROOT_ID)
            .ok_or(OperationSetupError::InvalidWorkspaceRoot)?;
        let roots = vec![root];
        let mut grant_store =
            PermissionGrantStore::new(64).ok_or(OperationSetupError::InvalidPolicy)?;
        for grant in restored_grants {
            if grant.session_id == session_id {
                grant_store.grant(grant);
            }
        }
        let grants = Arc::new(RwLock::new(grant_store));
        let snapshots = Arc::new(Mutex::new(WorkspaceSnapshots::default()));
        let proposal_enabled = proposal_enabled && filesystem_read && filesystem_write;
        let operation_catalog =
            operation_catalog(filesystem_read, filesystem_write, proposal_enabled)?;
        let operation_adapter = Arc::new(AcpOperationAdapter {
            connection: connection.clone(),
            session_id: session_id.clone(),
            snapshots: snapshots.clone(),
        });
        let mut descriptors = Vec::new();
        let mut adapters: BTreeMap<String, Arc<dyn ToolAdapter>> = BTreeMap::new();
        for descriptor in operation_catalog {
            adapters.insert(descriptor.id.clone(), operation_adapter.clone());
            descriptors.push(descriptor);
        }
        if terminal_enabled {
            for (descriptor, adapter) in
                build_terminal_tools(connection.clone(), session_id.clone(), cwd)
                    .map_err(|_| OperationSetupError::InvalidSchema)?
            {
                adapters.insert(descriptor.id.clone(), adapter);
                descriptors.push(descriptor);
            }
        }
        let catalog = ToolCatalog::new(TOOL_CATALOG_VERSION, descriptors, false)
            .map_err(|_| OperationSetupError::InvalidSchema)?;
        let definitions = catalog
            .tools()
            .map(|descriptor| crate::providers::ModelToolDefinition {
                name: descriptor.id.clone(),
                description: descriptor.description.clone(),
                input_schema: descriptor.input_schema.clone(),
            })
            .collect();
        let executor = ToolExecutor::new(
            catalog,
            adapters,
            Vec::new(),
            ToolExecutionLimits::new(8, 128, 256 * 1024)
                .ok_or(OperationSetupError::InvalidPolicy)?,
        );
        Ok(Self {
            executor,
            grants,
            path_resolver,
            roots,
            connection,
            session_id,
            proposal_enabled,
            definitions,
        })
    }

    pub(crate) fn runtime(&self, session: Arc<AgentSession>, turn_id: String) -> AcpToolRuntime {
        AcpToolRuntime {
            operations: self.clone(),
            session,
            turn_id,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum OperationSetupError {
    InvalidWorkspaceRoot,
    InvalidPolicy,
    InvalidSchema,
}

pub(crate) struct AcpToolRuntime {
    operations: SessionOperations,
    session: Arc<AgentSession>,
    turn_id: String,
}

#[async_trait]
impl ReActToolRuntime for AcpToolRuntime {
    fn definitions(&self) -> Vec<crate::providers::ModelToolDefinition> {
        self.operations.definitions.clone()
    }

    async fn invoke(
        &self,
        mut call: crate::providers::ModelToolCall,
        cancellation: AgentCancellationToken,
    ) -> Result<ToolObservation, RuntimeToolError> {
        if !self.operations.proposal_enabled && call.name == CHANGE_PROPOSAL {
            return Err(RuntimeToolError::CapabilityUnavailable);
        }
        if call.name == "terminal/create" {
            call.arguments
                .entry("cwd".to_owned())
                .or_insert_with(|| json!(self.operations.path_resolver.roots[0]));
        }
        let model_call = ToolCall {
            call_id: call.id.clone(),
            tool_id: call.name.clone(),
            catalog_version: TOOL_CATALOG_VERSION.to_owned(),
            arguments: call.arguments.clone(),
            idempotency_key: Some(call.id.clone()),
        };
        let context = self.execution_context(cancellation.clone());
        let preflight = match self
            .operations
            .executor
            .preflight(model_call.clone(), &context)
            .await
        {
            Ok(preflight) => preflight,
            Err(failure) => {
                return Ok(no_effect_observation(
                    json!({"ok":false,"code":failure_code(failure.code)}),
                    failure.safe_message(),
                ));
            }
        };

        let approval: Option<crate::tools::ToolOneShotApproval> = if let Some(requirement) =
            preflight.permission_requirement()
        {
            match self
                .request_permission(
                    &preflight,
                    &call,
                    requirement.root_id.as_str(),
                    &cancellation,
                )
                .await?
            {
                PermissionDecision::AllowOnce => Some(
                    self.operations
                        .executor
                        .bind_one_shot_approval(&preflight, &self.operations.session_id, &call.id)
                        .map_err(|_| RuntimeToolError::PermissionDenied)?,
                ),
                PermissionDecision::AllowAlways => {
                    self.grant_permission(&preflight).await?;
                    None
                }
                PermissionDecision::Cancelled if cancellation.is_cancelled() => {
                    return Err(RuntimeToolError::Cancelled);
                }
                PermissionDecision::Reject | PermissionDecision::Cancelled => {
                    return Ok(no_effect_observation(
                        json!({"ok":false,"code":"permission_denied"}),
                        "Permission was not granted.",
                    ));
                }
            }
        } else {
            None
        };

        let durable = call.name != READ_FILE;
        let reservation = if durable {
            match self.begin_effect(&model_call).await? {
                EffectStart::Started(reservation) => Some(reservation),
                EffectStart::Replay(receipt) => {
                    let succeeded = receipt.outcome == EffectExecutionOutcome::Committed;
                    return Ok(ToolObservation {
                        content: receipt.metadata.to_string(),
                        successful: succeeded,
                        effect_state: RuntimeEffectState::Committed,
                        summary: if succeeded {
                            "Operation completed.".to_owned()
                        } else {
                            "Operation was not applied.".to_owned()
                        },
                    });
                }
                EffectStart::NoEffect(code) => {
                    return Ok(no_effect_observation(
                        json!({"ok":false,"code":code}),
                        "Operation was not applied.",
                    ));
                }
                EffectStart::Uncertain => {
                    return Ok(uncertain_observation());
                }
            }
        } else {
            None
        };

        let receipt = match approval {
            Some(approval) => {
                self.operations
                    .executor
                    .execute_prepared_once(preflight, approval, context)
                    .await
            }
            None => {
                self.operations
                    .executor
                    .execute_prepared(preflight, context)
                    .await
            }
        };
        let output = Value::Object(receipt.output.clone());
        let output_ok = output
            .get("ok")
            .and_then(Value::as_bool)
            .unwrap_or(receipt.succeeded());

        if !durable {
            if cancellation.is_cancelled() {
                return Err(RuntimeToolError::Cancelled);
            }
            return Ok(ToolObservation {
                content: output.to_string(),
                successful: output_ok,
                effect_state: effect_state(receipt.effect_state),
                summary: if output_ok {
                    "Workspace state was read.".to_owned()
                } else {
                    "Workspace read was rejected.".to_owned()
                },
            });
        }

        let reservation = reservation.expect("durable operations reserve before dispatch");
        if receipt.effect_state == EffectState::Uncertain {
            return Ok(uncertain_observation());
        }
        let outcome = if receipt.effect_state == EffectState::Committed && output_ok {
            EffectExecutionOutcome::Committed
        } else {
            EffectExecutionOutcome::Rejected
        };
        let completed = match self
            .complete_effect(reservation, &model_call, outcome, output.clone())
            .await
        {
            Ok(completed) => completed,
            Err(_) => return Ok(uncertain_observation()),
        };
        match completed {
            EffectCommitOutcome::Committed | EffectCommitOutcome::Rejected => Ok(ToolObservation {
                content: output.to_string(),
                successful: outcome == EffectExecutionOutcome::Committed,
                effect_state: RuntimeEffectState::Committed,
                summary: if outcome == EffectExecutionOutcome::Committed {
                    "Operation completed.".to_owned()
                } else {
                    "Operation was not applied.".to_owned()
                },
            }),
            EffectCommitOutcome::Uncertain
            | EffectCommitOutcome::SequenceConflict
            | EffectCommitOutcome::CorruptedTail => Ok(uncertain_observation()),
            EffectCommitOutcome::IdempotencyConflict | EffectCommitOutcome::Invalid => {
                Ok(uncertain_observation())
            }
        }
    }
}

impl AcpToolRuntime {
    fn execution_context(&self, cancellation: CancellationToken) -> ToolExecutionContext {
        ToolExecutionContext {
            session_id: self.operations.session_id.clone(),
            cancellation,
            deadline: None,
            roots: self.operations.roots.clone(),
            policy: ExecutionPolicy::new(
                1,
                [ToolRisk::Read, ToolRisk::Write, ToolRisk::Process],
                std::iter::empty(),
                MAX_TOOL_RESULT_BYTES,
            )
            .expect("positive policy limits"),
            grants: self.operations.grants.clone(),
            path_resolver: Some(self.operations.path_resolver.clone()),
            secret_resolver: None,
        }
    }

    async fn request_permission(
        &self,
        _preflight: &ToolPreflight,
        call: &crate::providers::ModelToolCall,
        _root_id: &str,
        cancellation: &AgentCancellationToken,
    ) -> Result<PermissionDecision, RuntimeToolError> {
        let (title, kind) = permission_presentation(&call.name);
        let options = vec![
            PermissionOption::new(
                PermissionOptionId::new("allow-once"),
                "Allow once",
                PermissionOptionKind::AllowOnce,
            ),
            PermissionOption::new(
                PermissionOptionId::new("allow-always"),
                "Allow for this session",
                PermissionOptionKind::AllowAlways,
            ),
            PermissionOption::new(
                PermissionOptionId::new("reject-once"),
                "Reject",
                PermissionOptionKind::RejectOnce,
            ),
        ];
        let path = call.arguments.get("path").and_then(Value::as_str);
        let mut fields = ToolCallUpdateFields::new()
            .title(title)
            .name(call.name.clone())
            .kind(kind);
        if let Some(path) = path {
            fields = fields.raw_input(json!({"path":path}));
        }
        let request = RequestPermissionRequest::new(
            self.operations.session_id.clone(),
            ToolCallUpdate::new(call.id.clone(), fields),
            options,
        );
        let pending = self
            .operations
            .connection
            .send_request(request)
            .block_task();
        let response = match permission_response_or_cancel(cancellation, pending).await {
            Ok(Some(response)) => response,
            Ok(None) => return Ok(PermissionDecision::Cancelled),
            Err(_) => return Err(RuntimeToolError::HostUnavailable),
        };
        match response.outcome {
            RequestPermissionOutcome::Cancelled => Ok(PermissionDecision::Cancelled),
            RequestPermissionOutcome::Selected(selected) => match selected.option_id.0.as_ref() {
                "allow-once" => Ok(PermissionDecision::AllowOnce),
                "allow-always" => Ok(PermissionDecision::AllowAlways),
                "reject-once" => Ok(PermissionDecision::Reject),
                _ => Err(RuntimeToolError::PermissionDenied),
            },
            _ => Err(RuntimeToolError::PermissionDenied),
        }
    }

    async fn grant_permission(&self, preflight: &ToolPreflight) -> Result<(), RuntimeToolError> {
        let requirement = preflight
            .permission_requirement()
            .ok_or(RuntimeToolError::PermissionDenied)?;
        let grant = PermissionGrant::new(
            uuid::Uuid::new_v4().to_string(),
            self.operations.session_id.clone(),
            requirement.tool_id.clone(),
            [requirement.risk],
            [requirement.root_id.clone()],
        )
        .ok_or(RuntimeToolError::PermissionDenied)?;
        self.session
            .record_permission_grant(&grant, &self.turn_id)
            .await
            .map_err(|_| RuntimeToolError::StorageUnavailable)?;
        self.operations
            .grants
            .write()
            .map_err(|_| RuntimeToolError::PermissionDenied)?
            .grant(grant)
            .then_some(())
            .ok_or(RuntimeToolError::PermissionDenied)
    }

    async fn begin_effect(&self, call: &ToolCall) -> Result<EffectStart, RuntimeToolError> {
        let expected = self
            .session
            .refresh_sequence()
            .await
            .map_err(|_| RuntimeToolError::StorageUnavailable)?;
        let request = EffectRequest {
            session_id: self.operations.session_id.clone(),
            idempotency_key: call.call_id.clone(),
            effect_kind: call.tool_id.clone(),
            parameters: json!({
                "toolId":call.tool_id,
                "argumentsDigest":argument_digest(&call.arguments),
            }),
        };
        let correlation = self.session.correlation(self.turn_id.clone());
        let result = self
            .session
            .effect_journal()
            .begin_effect(request, correlation, expected, utc_now_rfc3339())
            .await
            .map_err(|_| RuntimeToolError::StorageUnavailable)?;
        self.session.observe_sequence(result.current_sequence);
        Ok(match result.outcome {
            EffectBeginOutcome::Started => result
                .reservation
                .map(EffectStart::Started)
                .unwrap_or(EffectStart::Uncertain),
            EffectBeginOutcome::Replay => result
                .receipt
                .map(EffectStart::Replay)
                .unwrap_or(EffectStart::Uncertain),
            EffectBeginOutcome::InProgress => EffectStart::Uncertain,
            EffectBeginOutcome::SequenceConflict => EffectStart::NoEffect("sequence_conflict"),
            EffectBeginOutcome::IdempotencyConflict => {
                EffectStart::NoEffect("idempotency_conflict")
            }
            EffectBeginOutcome::Rejected => EffectStart::NoEffect("operation_rejected"),
            EffectBeginOutcome::CorruptedTail => EffectStart::Uncertain,
        })
    }

    async fn complete_effect(
        &self,
        reservation: crate::sessions::EffectReservation,
        call: &ToolCall,
        outcome: EffectExecutionOutcome,
        metadata: Value,
    ) -> Result<EffectCommitOutcome, RuntimeToolError> {
        let execution = EffectExecutionReceipt {
            effect_id: call.call_id.clone(),
            outcome,
            metadata,
        };
        let result = self
            .session
            .effect_journal()
            .complete_effect(reservation, execution, utc_now_rfc3339())
            .await
            .map_err(|_| RuntimeToolError::StorageUnavailable)?;
        self.session.observe_sequence(result.current_sequence);
        Ok(result.outcome)
    }
}

enum PermissionDecision {
    AllowOnce,
    AllowAlways,
    Reject,
    Cancelled,
}

fn permission_presentation(tool_name: &str) -> (&'static str, ToolKind) {
    match tool_name {
        READ_FILE => ("Read workspace file", ToolKind::Read),
        CHANGE_PROPOSAL => ("Review workspace changes", ToolKind::Edit),
        name if name.starts_with("terminal/") => ("Run terminal operation", ToolKind::Execute),
        _ => ("Write workspace file", ToolKind::Edit),
    }
}

async fn permission_response_or_cancel<T, E>(
    cancellation: &AgentCancellationToken,
    pending: impl Future<Output = Result<T, E>>,
) -> Result<Option<T>, E> {
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => Ok(None),
        response = pending => response.map(Some),
    }
}

enum EffectStart {
    Started(crate::sessions::EffectReservation),
    Replay(crate::sessions::EffectReceipt),
    NoEffect(&'static str),
    Uncertain,
}

#[derive(Default)]
struct WorkspaceSnapshots {
    by_resource: HashMap<String, WorkspaceSnapshot>,
    order: VecDeque<String>,
}

impl WorkspaceSnapshots {
    fn insert(&mut self, snapshot: WorkspaceSnapshot) {
        self.order
            .retain(|resource| resource != &snapshot.resource_id);
        self.order.push_back(snapshot.resource_id.clone());
        self.by_resource
            .insert(snapshot.resource_id.clone(), snapshot);
        while self.by_resource.len() > MAX_SNAPSHOTS {
            if let Some(oldest) = self.order.pop_front() {
                self.by_resource.remove(&oldest);
            }
        }
    }

    fn get(&self, resource_id: &str) -> Option<&WorkspaceSnapshot> {
        self.by_resource.get(resource_id)
    }
}

struct SessionPathResolver {
    roots: Vec<PathBuf>,
    root_id: String,
}

#[async_trait]
impl ToolPathResolver for SessionPathResolver {
    async fn resolve(
        &self,
        request: ToolPathRequest,
        cancellation: CancellationToken,
    ) -> Result<ToolPathResolution, ()> {
        if cancellation.is_cancelled() || request.domain != ToolPathDomain::HostManaged {
            return Err(());
        }
        let path = Path::new(&request.original_path);
        if !path.is_absolute() {
            return Err(());
        }
        let normalized_path = normalize_absolute(path).ok_or(())?;
        for root in &self.roots {
            let normalized_root = normalize_absolute(root).ok_or(())?;
            if let Ok(relative) = normalized_path.strip_prefix(&normalized_root) {
                return Ok(ToolPathResolution::HostManaged {
                    root_id: self.root_id.clone(),
                    relative_path: relative.to_string_lossy().replace('\\', "/"),
                });
            }
        }
        Err(())
    }
}

fn normalize_absolute(path: &Path) -> Option<PathBuf> {
    if !path.is_absolute() {
        return None;
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return None;
                }
            }
            Component::Normal(part) => normalized.push(part),
        }
    }
    normalized.is_absolute().then_some(normalized)
}

struct AcpOperationAdapter {
    connection: ConnectionTo<Client>,
    session_id: String,
    snapshots: Arc<Mutex<WorkspaceSnapshots>>,
}

#[async_trait]
impl ToolAdapter for AcpOperationAdapter {
    async fn execute(
        &self,
        descriptor: &ToolDescriptor,
        arguments: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, ToolAdapterError> {
        match descriptor.id.as_str() {
            READ_FILE => self.read_file(arguments, cancellation).await,
            WRITE_FILE => self.write_file(arguments, cancellation).await,
            CHANGE_PROPOSAL => self.propose_change(arguments, cancellation).await,
            _ => Err(ToolAdapterError {
                message: "operation is unavailable",
            }),
        }
    }
}

impl AcpOperationAdapter {
    async fn read_file(
        &self,
        arguments: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, ToolAdapterError> {
        let path = required_path(&arguments)?;
        let mut request = ReadTextFileRequest::new(self.session_id.clone(), path.clone());
        if let Some(line) = arguments.get("line").and_then(Value::as_u64) {
            request = request.line(u32::try_from(line).ok());
        }
        if let Some(limit) = arguments.get("limit").and_then(Value::as_u64) {
            request = request.limit(u32::try_from(limit).ok());
        }
        let request = self.connection.send_request(request);
        tokio::select! {
            _ = cancellation.cancelled() => Ok(output(json!({"ok":false,"code":"cancelled"}))),
            result = request.block_task() => match result {
                Ok(response) => {
                    let snapshot = workspace_snapshot_from_meta(response.meta.as_ref());
                    if let Some(snapshot) = &snapshot {
                        self.snapshots.lock().await.insert(snapshot.clone());
                    }
                    Ok(output(json!({
                        "ok":true,
                        "content":response.content,
                        "workspaceSnapshot":snapshot,
                    })))
                }
                Err(error) => {
                    if let Some(snapshot) = workspace_snapshot_from_error_data(error.data.as_ref()) {
                        self.snapshots.lock().await.insert(snapshot.clone());
                        Ok(output(json!({"ok":false,"code":"document_missing","workspaceSnapshot":snapshot})))
                    } else if is_peer_response_error(&error) {
                        Ok(output(json!({"ok":false,"code":"operation_rejected"})))
                    } else {
                        // A read has no external mutation, so a lost reply is a known
                        // non-effect observation and may be safely reported to the model.
                        Ok(output(json!({"ok":false,"code":"host_unavailable"})))
                    }
                }
            }
        }
    }

    async fn write_file(
        &self,
        arguments: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, ToolAdapterError> {
        let path = required_path(&arguments)?;
        let content = arguments
            .get("content")
            .and_then(Value::as_str)
            .ok_or(ToolAdapterError {
                message: "write arguments are invalid",
            })?;
        let request = self.connection.send_request(
            agent_client_protocol::schema::v1::WriteTextFileRequest::new(
                self.session_id.clone(),
                path,
                content,
            ),
        );
        tokio::select! {
            _ = cancellation.cancelled() => Err(ToolAdapterError { message: "write outcome is unknown" }),
            result = request.block_task() => match result {
                Ok(response) => {
                    let snapshot = workspace_snapshot_from_meta(response.meta.as_ref());
                    if let Some(snapshot) = &snapshot {
                        self.snapshots.lock().await.insert(snapshot.clone());
                    }
                    Ok(output(json!({"ok":true,"workspaceSnapshot":snapshot})))
                }
                Err(error) if is_peer_response_error(&error) => {
                    let code = if workspace_snapshot_from_error_data(error.data.as_ref())
                        .is_some_and(|snapshot| !snapshot.document_exists) {
                        "document_revision_conflict"
                    } else {
                        "operation_rejected"
                    };
                    Ok(output(json!({"ok":false,"code":code})))
                }
                Err(_) => Err(ToolAdapterError { message: "write outcome is unknown" }),
            }
        }
    }

    async fn propose_change(
        &self,
        arguments: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, ToolAdapterError> {
        let proposal_value = arguments.get("proposal").cloned().ok_or(ToolAdapterError {
            message: "proposal arguments are invalid",
        })?;
        let proposal: VityoWorkspaceChangeProposal = serde_json::from_value(proposal_value)
            .map_err(|_| ToolAdapterError {
                message: "proposal arguments are invalid",
            })?;
        proposal.validate().map_err(|_| ToolAdapterError {
            message: "proposal arguments are invalid",
        })?;
        {
            let snapshots = self.snapshots.lock().await;
            let mut common_workspace_revision = None;
            let mut common_workspace_id = None;
            let mut common_root_id = None;
            for resource in &proposal.resources {
                let snapshot = snapshots
                    .get(&resource.resource_id)
                    .ok_or(ToolAdapterError {
                        message: "proposal observation is missing",
                    })?;
                let Some((workspace_revision, document_revision)) = snapshot.proposal_base() else {
                    return Err(ToolAdapterError {
                        message: "proposal observation is not eligible",
                    });
                };
                if snapshot.root_id != VITYO_HOST_ROOT_ID
                    || workspace_revision != proposal.base_workspace_revision
                    || document_revision != resource.base_document_revision
                    || common_workspace_revision
                        .is_some_and(|revision| revision != workspace_revision)
                    || common_workspace_id
                        .as_ref()
                        .is_some_and(|id: &String| id != &snapshot.workspace_id)
                    || common_root_id
                        .as_ref()
                        .is_some_and(|id: &String| id != &snapshot.root_id)
                {
                    return Err(ToolAdapterError {
                        message: "proposal revisions are stale",
                    });
                }
                common_workspace_revision = Some(workspace_revision);
                common_workspace_id = Some(snapshot.workspace_id.clone());
                common_root_id = Some(snapshot.root_id.clone());
            }
        }

        let request = VityoWorkspaceChangeProposalRequest {
            session_id: self.session_id.clone(),
            proposal: proposal.clone(),
        };
        let sent = self.connection.send_request(request);
        tokio::select! {
            _ = cancellation.cancelled() => Err(ToolAdapterError { message: "proposal outcome is unknown" }),
            result = sent.block_task() => match result {
                Ok(response) if response.validates_for(&proposal) => {
                    let committed = response.outcome == VityoWorkspaceChangeOutcome::Committed;
                    if committed {
                        let workspace_revision = response.workspace_revision.expect("validated committed receipt");
                        let document_revisions = response.document_revisions.as_ref().expect("validated committed receipt");
                        let mut snapshots = self.snapshots.lock().await;
                        for resource in &proposal.resources {
                            let Some(previous) = snapshots.get(&resource.resource_id).cloned() else { continue };
                            if let Some(document_revision) = document_revisions.get(&resource.resource_id) {
                                snapshots.insert(WorkspaceSnapshot {
                                    workspace_revision,
                                    document_revision: Some(*document_revision),
                                    source_revision: None,
                                    source_kind: Some(crate::protocol::types::WorkspaceSourceKind::Workspace),
                                    source_dirty: Some(false),
                                    proposal_eligible: false,
                                    ..previous
                                });
                            }
                        }
                    }
                    let outcome = match response.outcome {
                        VityoWorkspaceChangeOutcome::Committed => "committed",
                        VityoWorkspaceChangeOutcome::Rejected => "rejected",
                        VityoWorkspaceChangeOutcome::Conflict => "conflict",
                        VityoWorkspaceChangeOutcome::Failed => "failed",
                    };
                    Ok(output(json!({
                        "ok":committed,
                        "proposalId":response.proposal_id,
                        "outcome":outcome,
                        "workspaceRevision":response.workspace_revision,
                        "documentRevisions":response.document_revisions,
                        "code":safe_result_code(response.code.as_deref()),
                    })))
                }
                Ok(_) => Err(ToolAdapterError { message: "proposal outcome is invalid" }),
                Err(error) if is_peer_response_error(&error) => {
                    // A correlated JSON-RPC rejection is a known host outcome.
                    Ok(output(json!({"ok":false,"outcome":"failed","code":"operation_rejected"})))
                }
                Err(_) => Err(ToolAdapterError { message: "proposal outcome is unknown" }),
            }
        }
    }
}

fn operation_catalog(
    filesystem_read: bool,
    filesystem_write: bool,
    proposal_enabled: bool,
) -> Result<Vec<ToolDescriptor>, OperationSetupError> {
    let proposal_enabled = proposal_enabled && filesystem_read && filesystem_write;
    let output_schema = object_schema(json!({"type":"object","additionalProperties":true}))?;
    let mut descriptors = Vec::new();
    if filesystem_read {
        let input = object_schema(json!({
            "type":"object",
            "properties":{
                "path":{"type":"string","minLength":1},
                "line":{"type":"integer","minimum":1},
                "limit":{"type":"integer","minimum":1}
            },
            "required":["path"],
            "additionalProperties":false
        }))?;
        descriptors.push(
            ToolDescriptor::new(
                READ_FILE,
                "Read a text file through the connected IDE workspace.",
                ToolSourceKind::Builtin,
                input,
                output_schema.clone(),
                ToolRisk::Read,
                ["workspace".to_owned(), "read".to_owned()],
                Some("path".to_owned()),
                None,
                BTreeMap::new(),
                MAX_TOOL_RESULT_BYTES,
            )
            .and_then(|descriptor| descriptor.with_path_domain(ToolPathDomain::HostManaged))
            .map_err(|_| OperationSetupError::InvalidSchema)?,
        );
    }
    if filesystem_write {
        let write = object_schema(json!({
            "type":"object",
            "properties":{
                "path":{"type":"string","minLength":1},
                "content":{"type":"string"}
            },
            "required":["path","content"],
            "additionalProperties":false
        }))?;
        descriptors.push(
            ToolDescriptor::new(
                WRITE_FILE,
                "Write text to a file through the connected IDE workspace.",
                ToolSourceKind::Builtin,
                write,
                output_schema.clone(),
                ToolRisk::Write,
                ["workspace".to_owned(), "write".to_owned()],
                Some("path".to_owned()),
                None,
                BTreeMap::new(),
                MAX_TOOL_RESULT_BYTES,
            )
            .and_then(|descriptor| descriptor.with_path_domain(ToolPathDomain::HostManaged))
            .map_err(|_| OperationSetupError::InvalidSchema)?,
        );
    }
    if proposal_enabled {
        let proposal = object_schema(json!({
            "type":"object",
            "properties":{
                "proposal":{
                    "type":"object",
                    "properties":{
                        "id":{"type":"string","minLength":1},
                        "baseWorkspaceRevision":{"type":"integer","minimum":0},
                        "resources":{"type":"array","minItems":1,"maxItems":64,"items":{
                            "type":"object",
                            "properties":{
                                "resourceId":{"type":"string","minLength":1},
                                "baseDocumentRevision":{"type":"integer","minimum":0},
                                "edits":{"type":"array","minItems":1,"maxItems":500,"items":{
                                    "type":"object",
                                    "properties":{
                                        "start":{"type":"integer","minimum":0},
                                        "end":{"type":"integer","minimum":0},
                                        "replacement":{"type":"string"}
                                    },
                                    "required":["start","end","replacement"],
                                    "additionalProperties":false
                                }}
                            },
                            "required":["resourceId","baseDocumentRevision","edits"],
                            "additionalProperties":false
                        }}
                    },
                    "required":["id","baseWorkspaceRevision","resources"],
                    "additionalProperties":false
                }
            },
            "required":["proposal"],
            "additionalProperties":false
        }))?;
        descriptors.push(
            ToolDescriptor::new(
                CHANGE_PROPOSAL,
                "Propose a revision-bound workspace edit for user review.",
                ToolSourceKind::Builtin,
                proposal,
                output_schema,
                ToolRisk::Write,
                ["workspace".to_owned(), "proposal".to_owned()],
                None,
                None,
                BTreeMap::new(),
                MAX_TOOL_RESULT_BYTES,
            )
            .and_then(ToolDescriptor::with_host_review)
            .map_err(|_| OperationSetupError::InvalidSchema)?,
        );
    }
    Ok(descriptors)
}

fn object_schema(value: Value) -> Result<JsonObject, OperationSetupError> {
    value
        .as_object()
        .cloned()
        .ok_or(OperationSetupError::InvalidSchema)
}

fn required_path(arguments: &JsonObject) -> Result<PathBuf, ToolAdapterError> {
    arguments
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .ok_or(ToolAdapterError {
            message: "path argument is invalid",
        })
}

fn output(value: Value) -> JsonObject {
    value.as_object().cloned().unwrap_or_default()
}

fn is_peer_response_error(error: &agent_client_protocol::Error) -> bool {
    error
        .data
        .as_ref()
        .and_then(|data| data.get("reason"))
        .and_then(Value::as_str)
        != Some("incoming_transport_closed")
}

fn safe_result_code(code: Option<&str>) -> Option<&str> {
    code.filter(|value| {
        !value.is_empty()
            && value.len() <= 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    })
}

fn argument_digest(arguments: &JsonObject) -> String {
    use sha2::{Digest, Sha256};
    let bytes = serde_json::to_vec(arguments).unwrap_or_default();
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn effect_state(state: EffectState) -> RuntimeEffectState {
    match state {
        EffectState::None => RuntimeEffectState::None,
        EffectState::Uncertain => RuntimeEffectState::Uncertain,
        EffectState::Committed => RuntimeEffectState::Committed,
    }
}

fn no_effect_observation(content: Value, summary: &str) -> ToolObservation {
    ToolObservation {
        content: content.to_string(),
        successful: false,
        effect_state: RuntimeEffectState::None,
        summary: summary.to_owned(),
    }
}

fn uncertain_observation() -> ToolObservation {
    ToolObservation {
        content: "{\"error\":\"operation_outcome_uncertain\"}".to_owned(),
        successful: false,
        effect_state: RuntimeEffectState::Uncertain,
        summary: "The operation outcome is uncertain.".to_owned(),
    }
}

fn failure_code(code: crate::tools::ToolFailureCode) -> &'static str {
    use crate::tools::ToolFailureCode as Failure;
    match code {
        Failure::InvalidCall => "invalid_call",
        Failure::SchemaInvalid => "invalid_arguments",
        Failure::ToolRemoved => "operation_unavailable",
        Failure::PolicyDenied => "policy_denied",
        Failure::PermissionDenied => "permission_denied",
        Failure::Cancelled => "cancelled",
        Failure::DeadlineReached => "deadline_reached",
        Failure::ResultInvalid => "invalid_result",
        Failure::ResultTooLarge => "result_too_large",
        Failure::HookRejected => "operation_rejected",
        Failure::AdapterUnavailable => "operation_unavailable",
        Failure::IdempotencyConflict => "idempotency_conflict",
        Failure::CapacityExceeded => "capacity_exceeded",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn ids(descriptors: Vec<ToolDescriptor>) -> std::collections::BTreeSet<String> {
        descriptors
            .into_iter()
            .map(|descriptor| descriptor.id)
            .collect()
    }

    #[test]
    fn permission_presentation_distinguishes_process_and_file_authority() {
        assert_eq!(
            permission_presentation("terminal/create").1,
            ToolKind::Execute
        );
        assert_eq!(permission_presentation(READ_FILE).1, ToolKind::Read);
        assert_eq!(permission_presentation(WRITE_FILE).1, ToolKind::Edit);
        assert_eq!(
            permission_presentation(CHANGE_PROPOSAL).0,
            "Review workspace changes"
        );
    }

    #[tokio::test]
    async fn runtime_terminal_creation_uses_session_cwd_and_authorizes_workspace_root() {
        use agent_client_protocol::schema::v1::{
            CreateTerminalRequest, CreateTerminalResponse, RequestPermissionResponse,
            SelectedPermissionOutcome,
        };
        use agent_client_protocol::{Agent, on_receive_request};
        let root = tempfile::tempdir().unwrap();
        let config = root.path().join("provider.json");
        std::fs::write(
            &config,
            json!({
                "adapter":"openai_compatible_chat", "endpointBase":"https://api.example.test/v1",
                "model":"fixture", "capabilities":{
                    "contextTokens":8192,"outputTokens":512,"supportsTools":true,"maxConcurrency":1
                },"limits":{"maxTotalTokens":9216},"auth":{"mode":"none"}
            })
            .to_string(),
        )
        .unwrap();
        let app =
            crate::application::AgentApplication::from_paths(&config, root.path().join("sessions"))
                .unwrap();
        let workspace = root.path().join("workspace");
        std::fs::create_dir(&workspace).unwrap();
        let session = Arc::new(
            app.new_session("terminal-session", workspace.clone(), &[])
                .await
                .unwrap(),
        );
        let expected_workspace = workspace.clone();
        let client = Client
            .builder()
            .on_receive_request(
                async |request: RequestPermissionRequest, responder, _| {
                    assert_eq!(request.tool_call.fields.kind, Some(ToolKind::Execute));
                    responder.respond(RequestPermissionResponse::new(
                        RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
                            "allow-once",
                        )),
                    ))
                },
                on_receive_request!(),
            )
            .on_receive_request(
                async move |request: CreateTerminalRequest, responder, _| {
                    assert!(
                        request
                            .cwd
                            .as_ref()
                            .is_some_and(|cwd| cwd == &expected_workspace
                                || cwd == &expected_workspace.join("src"))
                    );
                    responder.respond(CreateTerminalResponse::new("terminal-fixture"))
                },
                on_receive_request!(),
            );
        Agent
            .builder()
            .connect_with(client, async move |connection: ConnectionTo<Client>| {
                let operations = SessionOperations::new(
                    connection,
                    "terminal-session".to_owned(),
                    workspace.clone(),
                    vec![],
                    true,
                    false,
                    true,
                    false,
                    vec![],
                )
                .unwrap();
                let runtime = operations.runtime(session, "terminal-turn".to_owned());
                for (id, cwd) in [
                    ("default", None),
                    ("root", Some(workspace.clone())),
                    ("nested", Some(workspace.join("src"))),
                ] {
                    let mut arguments = output(json!({"command":"fixture-command"}));
                    if let Some(cwd) = cwd {
                        arguments.insert("cwd".to_owned(), json!(cwd));
                    }
                    let observed = runtime
                        .invoke(
                            crate::providers::ModelToolCall {
                                id: id.to_owned(),
                                name: "terminal/create".to_owned(),
                                arguments,
                            },
                            CancellationToken::new(),
                        )
                        .await
                        .unwrap();
                    assert!(observed.successful, "{id}: {}", observed.content);
                }
                for (id, name, arguments) in [
                    (
                        "escape",
                        "terminal/create",
                        json!({"command":"fixture-command","cwd":workspace.join("..")}),
                    ),
                    ("read-root", READ_FILE, json!({"path":workspace})),
                ] {
                    let observed = runtime
                        .invoke(
                            crate::providers::ModelToolCall {
                                id: id.to_owned(),
                                name: name.to_owned(),
                                arguments: output(arguments),
                            },
                            CancellationToken::new(),
                        )
                        .await
                        .unwrap();
                    assert!(!observed.successful, "{id}");
                }
                Ok::<(), agent_client_protocol::Error>(())
            })
            .await
            .unwrap();
    }

    #[test]
    fn standard_file_and_proposal_tools_follow_negotiated_client_capabilities() {
        assert!(ids(operation_catalog(false, false, true).unwrap()).is_empty());
        assert_eq!(
            ids(operation_catalog(true, false, true).unwrap()),
            [READ_FILE.to_owned()].into_iter().collect()
        );
        assert_eq!(
            ids(operation_catalog(false, true, true).unwrap()),
            [WRITE_FILE.to_owned()].into_iter().collect()
        );
        assert_eq!(
            ids(operation_catalog(true, true, true).unwrap()),
            [READ_FILE, WRITE_FILE, CHANGE_PROPOSAL]
                .into_iter()
                .map(str::to_owned)
                .collect()
        );
        assert_eq!(
            ids(operation_catalog(true, true, false).unwrap()),
            [READ_FILE, WRITE_FILE]
                .into_iter()
                .map(str::to_owned)
                .collect()
        );
    }

    #[tokio::test]
    async fn permission_wait_drops_the_pending_host_reply_when_cancelled() {
        let cancellation = AgentCancellationToken::new();
        let task_cancellation = cancellation.clone();
        let waiting = tokio::spawn(async move {
            permission_response_or_cancel(
                &task_cancellation,
                std::future::pending::<Result<(), ()>>(),
            )
            .await
        });
        cancellation.cancel();
        let result = tokio::time::timeout(Duration::from_secs(1), waiting)
            .await
            .expect("permission wait responds to cancellation")
            .unwrap();
        assert!(matches!(result, Ok(None)));
    }
}
