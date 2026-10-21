use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    sync::{
        Arc, RwLock,
        atomic::{AtomicBool, Ordering},
    },
};

use async_trait::async_trait;
use futures::FutureExt;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::{
    sync::{Mutex, oneshot},
    time::Instant,
};
use tokio_util::sync::CancellationToken;

use crate::{
    contracts::JsonObject,
    policy::{
        DefaultPolicyEvaluator, ExecutionPolicy, PermissionGrantStore, PolicyDecisionCode,
        ToolEffect, ToolPathScope, ToolPermissionRequirement, ToolRoot,
    },
};

use super::{ToolCatalog, ToolDescriptor, ToolPathDomain, ToolSchema};

#[derive(Clone, PartialEq)]
pub struct ToolCall {
    pub call_id: String,
    pub tool_id: String,
    pub catalog_version: String,
    pub arguments: JsonObject,
    pub idempotency_key: Option<String>,
}

#[derive(Clone)]
pub struct ToolExecutionContext {
    pub session_id: String,
    pub cancellation: CancellationToken,
    pub deadline: Option<Instant>,
    pub roots: Vec<ToolRoot>,
    pub policy: ExecutionPolicy,
    pub grants: Arc<RwLock<PermissionGrantStore>>,
    pub path_resolver: Option<Arc<dyn ToolPathResolver>>,
    pub secret_resolver: Option<Arc<dyn SecretResolver>>,
}

/// A validated, non-executing tool request for journal-before-effect orchestration.
///
/// The value is opaque so callers cannot forge descriptor, argument, or policy state.
pub struct ToolPreflight {
    call: ToolCall,
    session_id: String,
    prepared: PreparedCall,
}

/// A one-shot approval bound to exactly one opaque preflight call.
pub(crate) struct ToolOneShotApproval {
    session_id: String,
    call_id: String,
    call_fingerprint: String,
    requirement: ToolPermissionRequirement,
}

impl ToolOneShotApproval {
    fn matches(
        &self,
        session_id: &str,
        call: &ToolCall,
        requirement: &ToolPermissionRequirement,
    ) -> bool {
        self.session_id == session_id
            && self.call_id == call.call_id
            && self.call_fingerprint == fingerprint(call)
            && self.requirement == *requirement
    }
}

impl ToolPreflight {
    /// Returns the exact tool/risk/workspace scope that requires user approval.
    pub fn permission_requirement(&self) -> Option<&ToolPermissionRequirement> {
        self.prepared.permission_requirement.as_ref()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ToolExecutionLimits {
    pub max_in_flight: usize,
    pub max_receipt_entries: usize,
    pub max_argument_bytes: usize,
}

impl ToolExecutionLimits {
    pub fn new(
        max_in_flight: usize,
        max_receipt_entries: usize,
        max_argument_bytes: usize,
    ) -> Option<Self> {
        (max_in_flight > 0 && max_receipt_entries > 0 && max_argument_bytes > 0).then_some(Self {
            max_in_flight,
            max_receipt_entries,
            max_argument_bytes,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolFailureCode {
    InvalidCall,
    SchemaInvalid,
    ToolRemoved,
    PolicyDenied,
    PermissionDenied,
    Cancelled,
    DeadlineReached,
    ResultInvalid,
    ResultTooLarge,
    HookRejected,
    AdapterUnavailable,
    IdempotencyConflict,
    CapacityExceeded,
}

impl ToolFailureCode {
    pub const fn safe_message(self) -> &'static str {
        match self {
            Self::InvalidCall => "Tool call is invalid.",
            Self::SchemaInvalid => "Tool arguments do not match the current schema.",
            Self::ToolRemoved => "Tool catalog version is no longer current.",
            Self::PolicyDenied => "Tool effect was denied by the current execution policy.",
            Self::PermissionDenied => "Tool effect is not covered by a current permission grant.",
            Self::Cancelled => "Tool execution was cancelled.",
            Self::DeadlineReached => "Tool execution deadline was reached.",
            Self::ResultInvalid => "Tool result does not match the declared schema.",
            Self::ResultTooLarge => "Tool result exceeds its configured byte bound.",
            Self::HookRejected => "Tool execution hook rejected the call or result.",
            Self::AdapterUnavailable => "Tool adapter is unavailable.",
            Self::IdempotencyConflict => "Idempotency key was reused for a different call.",
            Self::CapacityExceeded => "Tool execution concurrency bound was reached.",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EffectState {
    None,
    Uncertain,
    Committed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ToolFailure {
    pub code: ToolFailureCode,
}

impl ToolFailure {
    fn new(code: ToolFailureCode) -> Self {
        Self { code }
    }

    pub fn safe_message(self) -> &'static str {
        self.code.safe_message()
    }
}

#[derive(Clone, PartialEq)]
pub struct ToolExecutionReceipt {
    pub call_id: String,
    pub tool_id: String,
    pub catalog_version: String,
    pub effect_id: String,
    pub output: JsonObject,
    pub output_bytes: usize,
    pub untrusted_evidence: bool,
    pub reused: bool,
    pub effect_state: EffectState,
    pub failure: Option<ToolFailure>,
}

impl ToolExecutionReceipt {
    pub fn succeeded(&self) -> bool {
        self.failure.is_none()
    }

    fn as_reused(&self, call_id: &str) -> Self {
        let mut receipt = self.clone();
        receipt.call_id = call_id.to_owned();
        receipt.reused = true;
        receipt
    }

    fn failure(call: &ToolCall, code: ToolFailureCode, effect_state: EffectState) -> Self {
        Self {
            call_id: call.call_id.clone(),
            tool_id: call.tool_id.clone(),
            catalog_version: call.catalog_version.clone(),
            effect_id: effect_id(call),
            output: JsonObject::new(),
            output_bytes: 0,
            untrusted_evidence: false,
            reused: false,
            effect_state,
            failure: Some(ToolFailure::new(code)),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ToolAdapterError {
    pub message: &'static str,
}

#[async_trait]
pub trait ToolAdapter: Send + Sync {
    async fn execute(
        &self,
        descriptor: &ToolDescriptor,
        arguments: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, ToolAdapterError>;
}

#[async_trait]
pub trait ExecutionHook: Send + Sync {
    /// Validates or transforms arguments before authorization; it must not perform tool effects.
    async fn before(
        &self,
        descriptor: &ToolDescriptor,
        arguments: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, ()>;

    async fn after(
        &self,
        descriptor: &ToolDescriptor,
        output: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, ()>;
}

#[async_trait]
pub trait ToolPathResolver: Send + Sync {
    /// Resolves a path in its declared domain using the session-bound authority.
    ///
    /// Host-managed ACP paths are checked lexically here; the IDE/daemon remains the
    /// authority for symlink containment and revision checks when the operation runs.
    async fn resolve(
        &self,
        request: ToolPathRequest,
        cancellation: CancellationToken,
    ) -> Result<ToolPathResolution, ()>;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolPathRequest {
    pub session_id: String,
    pub call_id: String,
    /// Kept byte-for-byte for ACP dispatch; the resolver must not rewrite it.
    pub original_path: String,
    pub domain: ToolPathDomain,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToolPathResolution {
    ResourceUri {
        resolved_uri: String,
    },
    HostManaged {
        root_id: String,
        relative_path: String,
    },
}

#[async_trait]
pub trait SecretResolver: Send + Sync {
    async fn resolve(
        &self,
        reference: &str,
        audience: &str,
        cancellation: CancellationToken,
    ) -> Option<String>;
}

struct ToolExecutorInner {
    registry: RwLock<ToolRegistry>,
    hooks: Vec<Arc<dyn ExecutionHook>>,
    limits: ToolExecutionLimits,
    state: Mutex<ExecutionState>,
}

struct ToolRegistry {
    catalog: ToolCatalog,
    adapters: BTreeMap<String, Arc<dyn ToolAdapter>>,
}

#[derive(Clone)]
pub struct ToolExecutor {
    inner: Arc<ToolExecutorInner>,
}

impl ToolExecutor {
    pub fn new(
        catalog: ToolCatalog,
        adapters: BTreeMap<String, Arc<dyn ToolAdapter>>,
        hooks: Vec<Arc<dyn ExecutionHook>>,
        limits: ToolExecutionLimits,
    ) -> Self {
        Self {
            inner: Arc::new(ToolExecutorInner {
                registry: RwLock::new(ToolRegistry { catalog, adapters }),
                hooks,
                limits,
                state: Mutex::new(ExecutionState::default()),
            }),
        }
    }

    pub fn replace_tools(
        &self,
        catalog: ToolCatalog,
        adapters: BTreeMap<String, Arc<dyn ToolAdapter>>,
    ) {
        *self
            .inner
            .registry
            .write()
            .expect("tool registry lock poisoned") = ToolRegistry { catalog, adapters };
    }

    pub async fn preflight(
        &self,
        call: ToolCall,
        context: &ToolExecutionContext,
    ) -> Result<ToolPreflight, ToolFailure> {
        let prepared = prepare(&self.inner, &call, context)
            .await
            .map_err(ToolFailure::new)?;
        Ok(ToolPreflight {
            call,
            session_id: context.session_id.clone(),
            prepared,
        })
    }

    /// Binds an already correlated ACP allow-once decision to this exact preflight.
    ///
    /// The caller must invoke this only after the host allowed the matching session/call
    /// permission request. The returned token cannot authorize another call.
    pub(crate) fn bind_one_shot_approval(
        &self,
        preflight: &ToolPreflight,
        approved_session_id: &str,
        approved_call_id: &str,
    ) -> Result<ToolOneShotApproval, ToolFailure> {
        if preflight.session_id != approved_session_id || preflight.call.call_id != approved_call_id
        {
            return Err(ToolFailure::new(ToolFailureCode::InvalidCall));
        }
        let requirement = preflight
            .permission_requirement()
            .cloned()
            .ok_or_else(|| ToolFailure::new(ToolFailureCode::PermissionDenied))?;
        Ok(ToolOneShotApproval {
            session_id: approved_session_id.to_owned(),
            call_id: approved_call_id.to_owned(),
            call_fingerprint: fingerprint(&preflight.call),
            requirement,
        })
    }

    /// Executes a preflighted call after the caller has resolved any permission prompt.
    ///
    /// Current catalog, descriptor, workspace resolution, policy, and grants are checked
    /// again immediately before the adapter can run.
    pub async fn execute_prepared(
        &self,
        preflight: ToolPreflight,
        context: ToolExecutionContext,
    ) -> ToolExecutionReceipt {
        self.execute_prepared_inner(preflight, None, context).await
    }

    /// Executes after a correlated allow-once response without persisting a grant.
    pub(crate) async fn execute_prepared_once(
        &self,
        preflight: ToolPreflight,
        approval: ToolOneShotApproval,
        context: ToolExecutionContext,
    ) -> ToolExecutionReceipt {
        self.execute_prepared_inner(preflight, Some(approval), context)
            .await
    }

    async fn execute_prepared_inner(
        &self,
        preflight: ToolPreflight,
        approval: Option<ToolOneShotApproval>,
        context: ToolExecutionContext,
    ) -> ToolExecutionReceipt {
        let call = preflight.call;
        if preflight.session_id != context.session_id {
            return ToolExecutionReceipt::failure(
                &call,
                ToolFailureCode::InvalidCall,
                EffectState::None,
            );
        }
        let mut prepared = preflight.prepared;
        if let Err(code) = revalidate(
            &self.inner,
            &call,
            &mut prepared,
            &context,
            approval.as_ref(),
        )
        .await
        {
            return ToolExecutionReceipt::failure(&call, code, EffectState::None);
        }
        let key = call.idempotency_key.as_ref().and_then(|key| {
            let key = key.trim();
            (!key.is_empty()).then(|| EffectKey {
                session_id: context.session_id.clone(),
                tool_id: call.tool_id.clone(),
                idempotency_key: key.to_owned(),
            })
        });
        let fingerprint = fingerprint(&call);
        let (sender, receiver) = oneshot::channel();
        let mut owned_sender = Some(sender);
        let mut leader = false;
        {
            let mut state = self.inner.state.lock().await;
            if let Some(key) = key.as_ref() {
                if let Some(receipt) = state.receipts.get(key).cloned() {
                    if receipt.fingerprint != fingerprint {
                        return ToolExecutionReceipt::failure(
                            &call,
                            ToolFailureCode::IdempotencyConflict,
                            EffectState::None,
                        );
                    }
                    state.touch_receipt(key);
                    return receipt.receipt.as_reused(&call.call_id);
                }
                if let Some(existing) = state.in_flight.get_mut(key) {
                    if existing.fingerprint != fingerprint {
                        return ToolExecutionReceipt::failure(
                            &call,
                            ToolFailureCode::IdempotencyConflict,
                            EffectState::None,
                        );
                    }
                    existing
                        .waiters
                        .push(owned_sender.take().expect("sender is owned before joining"));
                } else {
                    if state.active_executions >= self.inner.limits.max_in_flight {
                        return ToolExecutionReceipt::failure(
                            &call,
                            ToolFailureCode::CapacityExceeded,
                            EffectState::None,
                        );
                    }
                    state.active_executions += 1;
                    state.in_flight.insert(
                        key.clone(),
                        InFlightExecution {
                            fingerprint: fingerprint.clone(),
                            waiters: Vec::new(),
                        },
                    );
                    leader = true;
                }
            } else {
                if state.active_executions >= self.inner.limits.max_in_flight {
                    return ToolExecutionReceipt::failure(
                        &call,
                        ToolFailureCode::CapacityExceeded,
                        EffectState::None,
                    );
                }
                state.active_executions += 1;
                leader = true;
            }
        }

        if !leader {
            return await_shared_result(receiver, &call, &context, true).await;
        }

        let inner = self.inner.clone();
        let task_call = call.clone();
        let task_context = context.clone();
        let task_prepared = prepared;
        let task_approval = approval;
        let sender = owned_sender.expect("leader retains its result sender");
        tokio::spawn(async move {
            let receipt = std::panic::AssertUnwindSafe(run_prepared(
                &inner,
                &task_call,
                task_prepared,
                task_approval,
                &task_context,
            ))
            .catch_unwind()
            .await
            .unwrap_or_else(|_| {
                ToolExecutionReceipt::failure(
                    &task_call,
                    ToolFailureCode::AdapterUnavailable,
                    EffectState::Uncertain,
                )
            });
            finish_execution(&inner, key.as_ref(), &fingerprint, &receipt).await;
            let _ = sender.send(receipt.clone());
        });
        await_shared_result(receiver, &call, &context, false).await
    }

    pub async fn execute(
        &self,
        call: ToolCall,
        context: ToolExecutionContext,
    ) -> ToolExecutionReceipt {
        let preflight = match self.preflight(call.clone(), &context).await {
            Ok(preflight) => preflight,
            Err(failure) => {
                return ToolExecutionReceipt::failure(&call, failure.code, EffectState::None);
            }
        };
        if preflight.permission_requirement().is_some() {
            return ToolExecutionReceipt::failure(
                &call,
                ToolFailureCode::PermissionDenied,
                EffectState::None,
            );
        }
        self.execute_prepared(preflight, context).await
    }
}

#[derive(Default)]
struct ExecutionState {
    active_executions: usize,
    in_flight: HashMap<EffectKey, InFlightExecution>,
    receipts: HashMap<EffectKey, StoredReceipt>,
    receipt_order: VecDeque<EffectKey>,
}

impl ExecutionState {
    fn touch_receipt(&mut self, key: &EffectKey) {
        self.receipt_order.retain(|entry| entry != key);
        self.receipt_order.push_back(key.clone());
    }
}

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
struct EffectKey {
    session_id: String,
    tool_id: String,
    idempotency_key: String,
}

struct InFlightExecution {
    fingerprint: String,
    waiters: Vec<oneshot::Sender<ToolExecutionReceipt>>,
}

#[derive(Clone)]
struct StoredReceipt {
    fingerprint: String,
    receipt: ToolExecutionReceipt,
}

struct PreparedCall {
    descriptor: ToolDescriptor,
    adapter: Arc<dyn ToolAdapter>,
    arguments: JsonObject,
    secret_references: BTreeMap<String, SecretReference>,
    permission_requirement: Option<ToolPermissionRequirement>,
}

async fn prepare(
    inner: &ToolExecutorInner,
    call: &ToolCall,
    context: &ToolExecutionContext,
) -> Result<PreparedCall, ToolFailureCode> {
    if call.call_id.trim().is_empty()
        || call.tool_id.trim().is_empty()
        || call.catalog_version.trim().is_empty()
        || context.session_id.trim().is_empty()
    {
        return Err(ToolFailureCode::InvalidCall);
    }
    check_control(context)?;
    let (descriptor, adapter) = {
        let registry = inner
            .registry
            .read()
            .map_err(|_| ToolFailureCode::ToolRemoved)?;
        if registry.catalog.version() != call.catalog_version {
            return Err(ToolFailureCode::ToolRemoved);
        }
        let descriptor = registry
            .catalog
            .find(&call.tool_id)
            .cloned()
            .ok_or(ToolFailureCode::ToolRemoved)?;
        let adapter = registry
            .adapters
            .get(&descriptor.id)
            .cloned()
            .ok_or(ToolFailureCode::AdapterUnavailable)?;
        (descriptor, adapter)
    };
    let argument_bytes = ToolSchema::encoded_bytes(&Value::Object(call.arguments.clone()))
        .ok_or(ToolFailureCode::SchemaInvalid)?;
    if argument_bytes > inner.limits.max_argument_bytes
        || !ToolSchema::accepts(
            &descriptor.input_schema,
            &Value::Object(call.arguments.clone()),
        )
    {
        return Err(ToolFailureCode::SchemaInvalid);
    }

    let mut arguments = call.arguments.clone();
    for hook in &inner.hooks {
        arguments = match bounded(
            hook.before(&descriptor, arguments, context.cancellation.clone()),
            context,
        )
        .await
        {
            Ok(Ok(arguments)) => arguments,
            Ok(Err(())) | Err(BoundedError::Failed) => return Err(ToolFailureCode::HookRejected),
            Err(BoundedError::Cancelled) => return Err(ToolFailureCode::Cancelled),
            Err(BoundedError::Deadline) => return Err(ToolFailureCode::DeadlineReached),
        };
        if !ToolSchema::accepts(&descriptor.input_schema, &Value::Object(arguments.clone())) {
            return Err(ToolFailureCode::SchemaInvalid);
        }
        if ToolSchema::encoded_bytes(&Value::Object(arguments.clone()))
            .is_none_or(|bytes| bytes > inner.limits.max_argument_bytes)
        {
            return Err(ToolFailureCode::SchemaInvalid);
        }
    }

    if descriptor.path_domain == Some(ToolPathDomain::HostManaged)
        && descriptor
            .path_argument
            .as_ref()
            .is_some_and(|argument| arguments.get(argument) != call.arguments.get(argument))
    {
        return Err(ToolFailureCode::HookRejected);
    }

    let (permission_requirement, secret_references) =
        authorize_arguments(&descriptor, &arguments, call, context).await?;

    Ok(PreparedCall {
        descriptor,
        adapter,
        arguments,
        secret_references,
        permission_requirement,
    })
}

async fn revalidate(
    inner: &ToolExecutorInner,
    call: &ToolCall,
    prepared: &mut PreparedCall,
    context: &ToolExecutionContext,
    approval: Option<&ToolOneShotApproval>,
) -> Result<(), ToolFailureCode> {
    check_control(context)?;
    let (descriptor, adapter) = {
        let registry = inner
            .registry
            .read()
            .map_err(|_| ToolFailureCode::ToolRemoved)?;
        if registry.catalog.version() != call.catalog_version {
            return Err(ToolFailureCode::ToolRemoved);
        }
        let descriptor = registry
            .catalog
            .find(&call.tool_id)
            .cloned()
            .ok_or(ToolFailureCode::ToolRemoved)?;
        if descriptor != prepared.descriptor {
            return Err(ToolFailureCode::ToolRemoved);
        }
        let adapter = registry
            .adapters
            .get(&descriptor.id)
            .cloned()
            .ok_or(ToolFailureCode::AdapterUnavailable)?;
        if !Arc::ptr_eq(&adapter, &prepared.adapter) {
            return Err(ToolFailureCode::ToolRemoved);
        }
        (descriptor, adapter)
    };
    let (permission_requirement, secret_references) =
        authorize_arguments(&descriptor, &prepared.arguments, call, context).await?;
    if let Some(requirement) = permission_requirement.as_ref()
        && !approval
            .is_some_and(|approval| approval.matches(&context.session_id, call, requirement))
    {
        return Err(ToolFailureCode::PermissionDenied);
    }
    prepared.adapter = adapter;
    prepared.secret_references = secret_references;
    prepared.permission_requirement = None;
    Ok(())
}

async fn authorize_arguments(
    descriptor: &ToolDescriptor,
    arguments: &JsonObject,
    call: &ToolCall,
    context: &ToolExecutionContext,
) -> Result<
    (
        Option<ToolPermissionRequirement>,
        BTreeMap<String, SecretReference>,
    ),
    ToolFailureCode,
> {
    let requested_path = descriptor
        .path_argument
        .as_ref()
        .map(|argument| arguments.get(argument).and_then(Value::as_str));
    let path_scope = if let Some(Some(requested)) = requested_path {
        let resolver = context
            .path_resolver
            .as_ref()
            .ok_or(ToolFailureCode::PolicyDenied)?;
        let domain = descriptor
            .path_domain
            .ok_or(ToolFailureCode::PolicyDenied)?;
        let resolution = match bounded(
            resolver.resolve(
                ToolPathRequest {
                    session_id: context.session_id.clone(),
                    call_id: call.call_id.clone(),
                    original_path: requested.to_owned(),
                    domain,
                },
                context.cancellation.clone(),
            ),
            context,
        )
        .await
        {
            Ok(Ok(resolution)) => resolution,
            Ok(Err(())) | Err(BoundedError::Failed) => {
                return Err(ToolFailureCode::PolicyDenied);
            }
            Err(BoundedError::Cancelled) => return Err(ToolFailureCode::Cancelled),
            Err(BoundedError::Deadline) => return Err(ToolFailureCode::DeadlineReached),
        };
        Some(match (domain, resolution) {
            (ToolPathDomain::ResourceUri, ToolPathResolution::ResourceUri { resolved_uri }) => {
                ToolPathScope::ResourceUri {
                    requested_uri: requested.to_owned(),
                    resolved_uri,
                }
            }
            (
                ToolPathDomain::HostManaged,
                ToolPathResolution::HostManaged {
                    root_id,
                    relative_path,
                },
            ) => ToolPathScope::HostManaged {
                root_id,
                relative_path,
            },
            _ => return Err(ToolFailureCode::PolicyDenied),
        })
    } else if requested_path.is_some() {
        return Err(ToolFailureCode::SchemaInvalid);
    } else {
        None
    };

    let (secret_references, raw_credential_detected, secret_audience_valid) =
        classify_credentials(arguments, &descriptor.secret_arguments);
    let network_host = descriptor
        .network_host_argument
        .as_ref()
        .and_then(|argument| arguments.get(argument))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let effect = ToolEffect {
        tool_id: descriptor.id.clone(),
        risk: descriptor.risk,
        path_scope: path_scope.clone(),
        require_host_managed_root: descriptor.approval_mode
            == super::catalog::ToolApprovalMode::HostReview,
        network_host,
        raw_credential_detected,
        secret_audience_valid,
    };
    let grants = context
        .grants
        .read()
        .map_err(|_| ToolFailureCode::PermissionDenied)?;
    let decision = DefaultPolicyEvaluator.evaluate(
        &effect,
        &context.policy,
        &context.roots,
        &grants,
        &context.session_id,
    );
    match decision.code {
        PolicyDecisionCode::Allowed => Ok((None, secret_references)),
        PolicyDecisionCode::PermissionDenied
            if descriptor.approval_mode == super::catalog::ToolApprovalMode::HostReview =>
        {
            Ok((None, secret_references))
        }
        PolicyDecisionCode::PermissionDenied => Ok((
            Some(
                decision
                    .permission_requirement
                    .ok_or(ToolFailureCode::PermissionDenied)?,
            ),
            secret_references,
        )),
        _ => Err(ToolFailureCode::PolicyDenied),
    }
}

async fn run_prepared(
    inner: &ToolExecutorInner,
    call: &ToolCall,
    mut prepared: PreparedCall,
    approval: Option<ToolOneShotApproval>,
    context: &ToolExecutionContext,
) -> ToolExecutionReceipt {
    let id = effect_id(call);
    let mut resolved_secrets = Vec::new();
    let mut adapter_arguments = prepared.arguments.clone();
    for (argument, reference) in &prepared.secret_references {
        let Some(resolver) = context.secret_resolver.as_ref() else {
            return ToolExecutionReceipt::failure(
                call,
                ToolFailureCode::PolicyDenied,
                EffectState::None,
            );
        };
        let resolved = bounded(
            resolver.resolve(
                &reference.uri,
                &reference.audience,
                context.cancellation.clone(),
            ),
            context,
        )
        .await;
        let value = match resolved {
            Ok(Some(value)) => value,
            Ok(None) | Err(BoundedError::Failed) => {
                return ToolExecutionReceipt::failure(
                    call,
                    ToolFailureCode::PolicyDenied,
                    EffectState::None,
                );
            }
            Err(BoundedError::Cancelled) => {
                return ToolExecutionReceipt::failure(
                    call,
                    ToolFailureCode::Cancelled,
                    EffectState::None,
                );
            }
            Err(BoundedError::Deadline) => {
                return ToolExecutionReceipt::failure(
                    call,
                    ToolFailureCode::DeadlineReached,
                    EffectState::None,
                );
            }
        };
        if value.is_empty() {
            return ToolExecutionReceipt::failure(
                call,
                ToolFailureCode::PolicyDenied,
                EffectState::None,
            );
        }
        adapter_arguments.insert(argument.clone(), Value::String(value.clone()));
        resolved_secrets.push(value);
    }

    if let Err(code) = revalidate(inner, call, &mut prepared, context, approval.as_ref()).await {
        return ToolExecutionReceipt::failure(call, code, EffectState::None);
    }

    let adapter_started = Arc::new(AtomicBool::new(false));
    let mark_adapter_started = adapter_started.clone();
    let adapter = prepared.adapter.clone();
    let descriptor = prepared.descriptor.clone();
    let adapter_result = bounded(
        async move {
            mark_adapter_started.store(true, Ordering::Relaxed);
            adapter
                .execute(&descriptor, adapter_arguments, context.cancellation.clone())
                .await
        },
        context,
    )
    .await;
    let mut output = match adapter_result {
        Ok(Ok(output)) => output,
        Ok(Err(_)) | Err(BoundedError::Failed) => {
            return ToolExecutionReceipt::failure(
                call,
                ToolFailureCode::AdapterUnavailable,
                EffectState::Uncertain,
            );
        }
        Err(BoundedError::Cancelled) => {
            return ToolExecutionReceipt::failure(
                call,
                ToolFailureCode::Cancelled,
                if adapter_started.load(Ordering::Relaxed) {
                    EffectState::Uncertain
                } else {
                    EffectState::None
                },
            );
        }
        Err(BoundedError::Deadline) => {
            return ToolExecutionReceipt::failure(
                call,
                ToolFailureCode::DeadlineReached,
                if adapter_started.load(Ordering::Relaxed) {
                    EffectState::Uncertain
                } else {
                    EffectState::None
                },
            );
        }
    };

    for hook in &inner.hooks {
        output = match bounded(
            hook.after(&prepared.descriptor, output, context.cancellation.clone()),
            context,
        )
        .await
        {
            Ok(Ok(output)) => output,
            Ok(Err(())) | Err(BoundedError::Failed) => {
                return ToolExecutionReceipt::failure(
                    call,
                    ToolFailureCode::HookRejected,
                    EffectState::Committed,
                );
            }
            Err(BoundedError::Cancelled) => {
                return ToolExecutionReceipt::failure(
                    call,
                    ToolFailureCode::Cancelled,
                    EffectState::Committed,
                );
            }
            Err(BoundedError::Deadline) => {
                return ToolExecutionReceipt::failure(
                    call,
                    ToolFailureCode::DeadlineReached,
                    EffectState::Committed,
                );
            }
        };
    }

    if !ToolSchema::accepts(
        &prepared.descriptor.output_schema,
        &Value::Object(output.clone()),
    ) {
        return ToolExecutionReceipt::failure(
            call,
            ToolFailureCode::ResultInvalid,
            EffectState::Committed,
        );
    }
    let raw = Value::Object(output.clone());
    let Some(raw_bytes) = ToolSchema::encoded_bytes(&raw) else {
        return ToolExecutionReceipt::failure(
            call,
            ToolFailureCode::ResultInvalid,
            EffectState::Committed,
        );
    };
    let result_limit = prepared
        .descriptor
        .max_result_bytes
        .min(context.policy.max_result_bytes);
    if raw_bytes > result_limit {
        return ToolExecutionReceipt::failure(
            call,
            ToolFailureCode::ResultTooLarge,
            EffectState::Committed,
        );
    }
    output = redact_output(&Value::Object(output), &resolved_secrets)
        .as_object()
        .cloned()
        .unwrap_or_default();
    let output_bytes = ToolSchema::encoded_bytes(&Value::Object(output.clone())).unwrap_or(0);
    ToolExecutionReceipt {
        call_id: call.call_id.clone(),
        tool_id: call.tool_id.clone(),
        catalog_version: call.catalog_version.clone(),
        effect_id: id,
        output,
        output_bytes,
        untrusted_evidence: true,
        reused: false,
        effect_state: EffectState::Committed,
        failure: None,
    }
}

async fn finish_execution(
    inner: &ToolExecutorInner,
    key: Option<&EffectKey>,
    fingerprint: &str,
    receipt: &ToolExecutionReceipt,
) {
    let mut state = inner.state.lock().await;
    state.active_executions = state.active_executions.saturating_sub(1);
    let waiters = key
        .and_then(|key| state.in_flight.remove(key))
        .map(|entry| entry.waiters)
        .unwrap_or_default();
    if let Some(key) = key {
        if receipt.effect_state != EffectState::None {
            state.receipts.insert(
                key.clone(),
                StoredReceipt {
                    fingerprint: fingerprint.to_owned(),
                    receipt: receipt.clone(),
                },
            );
            state.touch_receipt(key);
            while state.receipts.len() > inner.limits.max_receipt_entries {
                if let Some(oldest) = state.receipt_order.pop_front() {
                    state.receipts.remove(&oldest);
                }
            }
        }
    }
    for waiter in waiters {
        let _ = waiter.send(receipt.clone());
    }
}

async fn await_shared_result(
    receiver: oneshot::Receiver<ToolExecutionReceipt>,
    call: &ToolCall,
    context: &ToolExecutionContext,
    reused: bool,
) -> ToolExecutionReceipt {
    if !reused {
        return match receiver.await {
            Ok(receipt) => receipt,
            Err(_) => ToolExecutionReceipt::failure(
                call,
                ToolFailureCode::AdapterUnavailable,
                EffectState::Uncertain,
            ),
        };
    }
    tokio::select! {
        biased;
        _ = context.cancellation.cancelled() => ToolExecutionReceipt::failure(call, ToolFailureCode::Cancelled, EffectState::None),
        _ = deadline(context.deadline) => ToolExecutionReceipt::failure(call, ToolFailureCode::DeadlineReached, EffectState::None),
        result = receiver => match result {
            Ok(receipt) => receipt.as_reused(&call.call_id),
            Err(_) => ToolExecutionReceipt::failure(call, ToolFailureCode::AdapterUnavailable, EffectState::Uncertain),
        },
    }
}

enum BoundedError {
    Cancelled,
    Deadline,
    Failed,
}

async fn bounded<T>(
    operation: impl std::future::Future<Output = T>,
    context: &ToolExecutionContext,
) -> Result<T, BoundedError> {
    check_control(context).map_err(|code| match code {
        ToolFailureCode::Cancelled => BoundedError::Cancelled,
        _ => BoundedError::Deadline,
    })?;
    tokio::select! {
        biased;
        _ = context.cancellation.cancelled() => Err(BoundedError::Cancelled),
        _ = deadline(context.deadline) => Err(BoundedError::Deadline),
        result = std::panic::AssertUnwindSafe(operation).catch_unwind() => {
            result.map_err(|_| BoundedError::Failed)
        },
    }
}

async fn deadline(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending::<()>().await,
    }
}

fn check_control(context: &ToolExecutionContext) -> Result<(), ToolFailureCode> {
    if context.cancellation.is_cancelled() {
        Err(ToolFailureCode::Cancelled)
    } else if context
        .deadline
        .is_some_and(|deadline| Instant::now() >= deadline)
    {
        Err(ToolFailureCode::DeadlineReached)
    } else {
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct SecretReference {
    uri: String,
    audience: String,
}

fn classify_credentials(
    arguments: &JsonObject,
    declared: &BTreeMap<String, String>,
) -> (BTreeMap<String, SecretReference>, bool, bool) {
    let mut references = BTreeMap::new();
    let mut audience_valid = true;
    for (key, audience) in declared {
        let reference = arguments
            .get(key)
            .and_then(Value::as_str)
            .and_then(parse_secret_reference);
        match reference {
            Some(reference) if reference.audience == *audience => {
                references.insert(key.clone(), reference);
            }
            _ => audience_valid = false,
        }
    }
    let raw_credential = contains_raw_credential(arguments, declared);
    (references, raw_credential, audience_valid)
}

fn parse_secret_reference(value: &str) -> Option<SecretReference> {
    let rest = value.strip_prefix("secret://")?;
    let (id, query) = rest.split_once('?')?;
    if id.trim().is_empty() || id.contains('/') || id.contains('#') {
        return None;
    }
    let audience = query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == "audience" && !value.trim().is_empty()).then(|| value.to_owned())
    })?;
    Some(SecretReference {
        uri: value.to_owned(),
        audience,
    })
}

fn contains_raw_credential(arguments: &JsonObject, declared: &BTreeMap<String, String>) -> bool {
    fn sensitive_name(name: &str) -> bool {
        let name = name.to_ascii_lowercase();
        [
            "token",
            "password",
            "secret",
            "credential",
            "api_key",
            "apikey",
        ]
        .iter()
        .any(|part| name.contains(part))
    }
    fn scan(value: &Value, key: Option<&str>, declared: &BTreeMap<String, String>) -> bool {
        match value {
            Value::Object(object) => object
                .iter()
                .any(|(name, value)| scan(value, Some(name), declared)),
            Value::Array(items) => items.iter().any(|item| scan(item, key, declared)),
            Value::String(text) => {
                if text.starts_with("secret://") {
                    return key.is_none_or(|key| !declared.contains_key(key));
                }
                key.is_some_and(sensitive_name) || text.to_ascii_lowercase().starts_with("bearer ")
            }
            _ => key.is_some_and(sensitive_name),
        }
    }
    arguments
        .iter()
        .any(|(key, value)| scan(value, Some(key), declared))
}

fn redact_output(value: &Value, secrets: &[String]) -> Value {
    fn sensitive_name(name: &str) -> bool {
        let name = name.to_ascii_lowercase();
        [
            "token",
            "password",
            "secret",
            "credential",
            "api_key",
            "apikey",
        ]
        .iter()
        .any(|part| name.contains(part))
    }
    fn redact(value: &Value, key: Option<&str>, secrets: &[String]) -> Value {
        if key.is_some_and(sensitive_name) {
            return Value::String("[redacted]".to_owned());
        }
        match value {
            Value::Object(object) => Value::Object(
                object
                    .iter()
                    .map(|(key, value)| (key.clone(), redact(value, Some(key), secrets)))
                    .collect(),
            ),
            Value::Array(items) => Value::Array(
                items
                    .iter()
                    .map(|value| redact(value, key, secrets))
                    .collect(),
            ),
            Value::String(text)
                if text.to_ascii_lowercase().starts_with("bearer ")
                    || secrets
                        .iter()
                        .any(|secret| !secret.is_empty() && text.contains(secret)) =>
            {
                Value::String("[redacted]".to_owned())
            }
            _ => value.clone(),
        }
    }
    redact(value, None, secrets)
}

fn fingerprint(call: &ToolCall) -> String {
    let value = serde_json::json!({
        "tool": call.tool_id,
        "catalog": call.catalog_version,
        "arguments": call.arguments,
    });
    let bytes = serde_json::to_vec(&value).unwrap_or_default();
    format!("{:x}", Sha256::digest(bytes))
}

fn effect_id(call: &ToolCall) -> String {
    let value = format!(
        "{}\0{}\0{}",
        call.tool_id,
        call.idempotency_key.as_deref().unwrap_or(&call.call_id),
        call.catalog_version
    );
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

#[cfg(test)]
mod approval_tests {
    use std::{
        collections::BTreeMap,
        sync::{
            Arc, RwLock,
            atomic::{AtomicUsize, Ordering},
        },
    };

    use async_trait::async_trait;
    use serde_json::json;
    use tokio_util::sync::CancellationToken;

    use crate::{
        contracts::JsonObject,
        policy::{ExecutionPolicy, PermissionGrantStore, ToolRoot},
        tools::{ToolCatalog, ToolDescriptor, ToolRisk, ToolSourceKind},
    };

    use super::{
        ToolAdapter, ToolAdapterError, ToolCall, ToolExecutionContext, ToolExecutionLimits,
        ToolExecutor, ToolFailureCode,
    };

    struct CountingAdapter(AtomicUsize);

    #[async_trait]
    impl ToolAdapter for CountingAdapter {
        async fn execute(
            &self,
            _descriptor: &ToolDescriptor,
            _arguments: JsonObject,
            _cancellation: CancellationToken,
        ) -> Result<JsonObject, ToolAdapterError> {
            self.0.fetch_add(1, Ordering::Relaxed);
            Ok(JsonObject::new())
        }
    }

    fn empty_schema() -> JsonObject {
        serde_json::from_value(json!({
            "type": "object",
            "properties": {},
            "required": [],
            "additionalProperties": true,
        }))
        .unwrap()
    }

    fn context() -> ToolExecutionContext {
        ToolExecutionContext {
            session_id: "session".to_owned(),
            cancellation: CancellationToken::new(),
            deadline: None,
            roots: vec![ToolRoot::host_managed("flow-hero").unwrap()],
            policy: ExecutionPolicy::new(1, [ToolRisk::Write], [], 1024).unwrap(),
            grants: Arc::new(RwLock::new(PermissionGrantStore::new(4).unwrap())),
            path_resolver: None,
            secret_resolver: None,
        }
    }

    fn executor(host_review: bool) -> (ToolExecutor, Arc<CountingAdapter>) {
        let mut schema = empty_schema();
        schema.insert(
            "properties".to_owned(),
            json!({"value": {"type": "string"}}),
        );
        let mut descriptor = ToolDescriptor::new(
            "proposal.submit",
            "Submit a reviewed proposal",
            ToolSourceKind::Builtin,
            schema,
            empty_schema(),
            ToolRisk::Write,
            ["proposal".to_owned()],
            None,
            None,
            BTreeMap::new(),
            1024,
        )
        .unwrap();
        if host_review {
            descriptor = descriptor.with_host_review().unwrap();
        }
        let adapter = Arc::new(CountingAdapter(AtomicUsize::new(0)));
        let executor = ToolExecutor::new(
            ToolCatalog::new("catalog", [descriptor], false).unwrap(),
            BTreeMap::from([(
                "proposal.submit".to_owned(),
                adapter.clone() as Arc<dyn ToolAdapter>,
            )]),
            Vec::new(),
            ToolExecutionLimits::new(2, 2, 1024).unwrap(),
        );
        (executor, adapter)
    }

    fn call(call_id: &str, value: &str) -> ToolCall {
        ToolCall {
            call_id: call_id.to_owned(),
            tool_id: "proposal.submit".to_owned(),
            catalog_version: "catalog".to_owned(),
            arguments: serde_json::from_value(json!({"value": value})).unwrap(),
            idempotency_key: None,
        }
    }

    #[tokio::test]
    async fn allow_once_is_bound_to_the_exact_call_and_does_not_store_a_grant() {
        let (executor, adapter) = executor(false);
        let context = context();
        let first = executor
            .preflight(call("call-1", "first"), &context)
            .await
            .unwrap();
        let approval = executor
            .bind_one_shot_approval(&first, "session", "call-1")
            .unwrap();
        let second = executor
            .preflight(call("call-1", "different"), &context)
            .await
            .unwrap();

        let receipt = executor
            .execute_prepared_once(second, approval, context.clone())
            .await;

        assert_eq!(
            receipt.failure.unwrap().code,
            ToolFailureCode::PermissionDenied
        );
        assert_eq!(adapter.0.load(Ordering::Relaxed), 0);

        let approved = executor
            .preflight(call("call-2", "allowed"), &context)
            .await
            .unwrap();
        let approval = executor
            .bind_one_shot_approval(&approved, "session", "call-2")
            .unwrap();
        let receipt = executor
            .execute_prepared_once(approved, approval, context.clone())
            .await;
        assert!(receipt.succeeded());
        assert_eq!(adapter.0.load(Ordering::Relaxed), 1);
        assert_eq!(context.grants.read().unwrap().active_grant_count(), 0);
    }

    #[tokio::test]
    async fn host_review_defers_only_the_grant_to_the_correlated_host_review() {
        let (executor, adapter) = executor(true);
        let context = context();
        let preflight = executor
            .preflight(call("proposal-call", "proposal"), &context)
            .await
            .unwrap();
        assert!(preflight.permission_requirement().is_none());

        let receipt = executor.execute_prepared(preflight, context.clone()).await;

        assert!(receipt.succeeded());
        assert_eq!(adapter.0.load(Ordering::Relaxed), 1);
        assert_eq!(context.grants.read().unwrap().active_grant_count(), 0);

        let mut denied = context;
        denied.policy = ExecutionPolicy::new(2, [ToolRisk::Read], [], 1024).unwrap();
        let preflight = executor
            .preflight(call("blocked", "proposal"), &denied)
            .await;
        assert!(matches!(preflight, Err(failure) if failure.code == ToolFailureCode::PolicyDenied));

        let mut missing_root = denied;
        missing_root.policy = ExecutionPolicy::new(3, [ToolRisk::Write], [], 1024).unwrap();
        missing_root.roots.clear();
        let preflight = executor
            .preflight(call("missing-root", "proposal"), &missing_root)
            .await;
        assert!(matches!(preflight, Err(failure) if failure.code == ToolFailureCode::PolicyDenied));
        assert_eq!(adapter.0.load(Ordering::Relaxed), 1);
    }
}
