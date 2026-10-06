use std::collections::{HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use crate::{AgentProcessError, AgentProcessLaunch, SupervisedAgentRegistry};

const ACP_PROTOCOL_VERSION: u64 = 1;
const MAX_EVENTS_PER_SESSION: usize = 4096;
const MAX_CLIENT_OPERATIONS_PER_SESSION: usize = 64;
const MAX_COMPLETED_CLIENT_OPERATIONS: usize = 256;

#[derive(Debug, Clone, PartialEq)]
pub struct AcpConnectionSnapshot {
    pub agent_id: String,
    pub protocol_version: u64,
    pub generation: u64,
    pub capabilities: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpSessionSnapshot {
    pub session_id: String,
    pub agent_id: String,
    pub generation: u64,
    pub remote_session_id: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AcpEvent {
    pub sequence: u64,
    pub kind: String,
    pub text: Option<String>,
    pub payload: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcpPermissionOptionKind {
    AllowOnce,
    AllowAlways,
    RejectOnce,
    RejectAlways,
}

impl AcpPermissionOptionKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::AllowOnce => "allow_once",
            Self::AllowAlways => "allow_always",
            Self::RejectOnce => "reject_once",
            Self::RejectAlways => "reject_always",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpPermissionOption {
    pub option_id: String,
    pub name: String,
    pub kind: AcpPermissionOptionKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpPermissionRequest {
    pub permission_id: String,
    pub agent_id: String,
    pub session_id: String,
    pub tool_call_id: String,
    pub tool_call_title: Option<String>,
    pub tool_call_kind: Option<String>,
    pub options: Vec<AcpPermissionOption>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AcpClientCapabilities {
    pub read_text_file: bool,
    pub write_text_file: bool,
    pub terminal: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AcpClientOperation {
    pub operation_id: String,
    pub session_id: String,
    pub method: String,
    pub params: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AcpPollResult {
    pub events: Vec<AcpEvent>,
    pub permissions: Vec<AcpPermissionRequest>,
    pub client_operations: Vec<AcpClientOperation>,
    pub prompt_result: Option<Value>,
    pub process_exit_code: Option<i32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcpError {
    InvalidRequest,
    WorkspaceMismatch,
    CapacityExceeded,
    StartFailed,
    UnknownAgent,
    UnknownSession,
    UnknownClientOperation,
    UnknownPermission,
    PermissionAlreadyResolved,
    UnsupportedProtocol,
    CapabilityDenied,
    SessionCollision,
    PromptInProgress,
    NoPromptInProgress,
    MessageTooLarge,
    MalformedMessage,
    RemoteError,
    TimedOut,
    ProcessExited,
    TransportFailed,
    ResumeGap,
}

pub struct AcpRuntime {
    processes: SupervisedAgentRegistry,
    connections: HashMap<String, AcpConnection>,
    sessions: HashMap<String, AcpSession>,
    permissions: HashMap<String, PendingPermission>,
    next_generation: u64,
    next_session: u64,
    next_client_operation: u64,
}

struct AcpConnection {
    generation: u64,
    next_request: u64,
    maximum_message_bytes: usize,
    capabilities: HashSet<String>,
    allowed_extensions: HashSet<String>,
    client_capabilities: AcpClientCapabilities,
}

struct AcpSession {
    session_id: String,
    agent_id: String,
    generation: u64,
    remote_session_id: String,
    workspace_path: String,
    next_sequence: u64,
    events: VecDeque<AcpEvent>,
    prompt_request_id: Option<String>,
    prompt_result: Option<Value>,
    client_operations: VecDeque<PendingClientOperation>,
    completed_client_operations: HashMap<String, Value>,
    completed_client_operation_order: VecDeque<String>,
}

struct PendingClientOperation {
    request: AcpClientOperation,
    rpc_id: Value,
}

struct PendingPermission {
    permission_id: String,
    agent_id: String,
    session_id: String,
    rpc_id: Value,
    tool_call_id: String,
    tool_call_title: Option<String>,
    tool_call_kind: Option<String>,
    options: Vec<AcpPermissionOption>,
}

impl Default for AcpRuntime {
    fn default() -> Self {
        Self::new(64, 8 * 1024 * 1024, 1024 * 1024)
    }
}

impl AcpRuntime {
    pub fn new(
        maximum_processes: usize,
        maximum_buffered_bytes: usize,
        maximum_message_bytes: usize,
    ) -> Self {
        Self {
            processes: SupervisedAgentRegistry::new(
                maximum_processes,
                maximum_buffered_bytes,
                maximum_message_bytes,
            ),
            connections: HashMap::new(),
            sessions: HashMap::new(),
            permissions: HashMap::new(),
            next_generation: 1,
            next_session: 1,
            next_client_operation: 1,
        }
    }

    pub fn connect(
        &mut self,
        launch: AgentProcessLaunch,
        allowed_extensions: impl IntoIterator<Item = String>,
        client_capabilities: AcpClientCapabilities,
        maximum_message_bytes: usize,
        timeout: Duration,
    ) -> Result<AcpConnectionSnapshot, AcpError> {
        if timeout.is_zero()
            || maximum_message_bytes == 0
            || maximum_message_bytes > 1024 * 1024
            || self.connections.contains_key(&launch.agent_id)
        {
            return Err(AcpError::InvalidRequest);
        }
        let agent_id = launch.agent_id.clone();
        self.processes.start(launch).map_err(map_process_error)?;
        let generation = self.next_generation;
        self.next_generation = self.next_generation.saturating_add(1);
        let allowed_extensions = allowed_extensions
            .into_iter()
            .filter(|capability| capability.starts_with("_vityo.dev/") && capability.len() <= 256)
            .collect::<HashSet<_>>();
        let mut advertised_extensions = allowed_extensions.iter().cloned().collect::<Vec<_>>();
        advertised_extensions.sort();
        self.connections.insert(
            agent_id.clone(),
            AcpConnection {
                generation,
                next_request: 1,
                maximum_message_bytes,
                capabilities: HashSet::new(),
                allowed_extensions,
                client_capabilities,
            },
        );
        let result = self.request_and_wait(
            &agent_id,
            "initialize",
            json!({
                "protocolVersion": ACP_PROTOCOL_VERSION,
                "clientInfo": {"name": "vityod", "version": "0.1.0"},
                "clientCapabilities": {
                    "fs": {
                        "readTextFile": client_capabilities.read_text_file,
                        "writeTextFile": client_capabilities.write_text_file
                    },
                    "terminal": client_capabilities.terminal,
                    "_meta": {
                        "vityo.dev": {
                            "extensions": advertised_extensions
                        }
                    }
                }
            }),
            timeout,
        );
        let result = match result {
            Ok(result) => result,
            Err(error) => {
                self.connections.remove(&agent_id);
                let _ = self.processes.close(&agent_id);
                return Err(error);
            }
        };
        if result.get("protocolVersion").and_then(Value::as_u64) != Some(ACP_PROTOCOL_VERSION) {
            self.connections.remove(&agent_id);
            let _ = self.processes.close(&agent_id);
            return Err(AcpError::UnsupportedProtocol);
        }
        let capabilities = decode_capabilities(
            &result,
            &self
                .connections
                .get(&agent_id)
                .expect("connection inserted before initialize")
                .allowed_extensions,
        );
        self.connections
            .get_mut(&agent_id)
            .expect("connection inserted before initialize")
            .capabilities = capabilities;
        self.connection(&agent_id)
    }

    pub fn connection(&self, agent_id: &str) -> Result<AcpConnectionSnapshot, AcpError> {
        let connection = self
            .connections
            .get(agent_id)
            .ok_or(AcpError::UnknownAgent)?;
        let mut capabilities = connection.capabilities.iter().cloned().collect::<Vec<_>>();
        capabilities.sort_unstable();
        Ok(AcpConnectionSnapshot {
            agent_id: agent_id.to_owned(),
            protocol_version: ACP_PROTOCOL_VERSION,
            generation: connection.generation,
            capabilities,
        })
    }

    pub fn new_session(
        &mut self,
        agent_id: &str,
        workspace_path: &str,
        timeout: Duration,
    ) -> Result<AcpSessionSnapshot, AcpError> {
        validate_workspace_path(workspace_path)?;
        let result = self.request_and_wait(
            agent_id,
            "session/new",
            json!({"cwd": workspace_path, "mcpServers": []}),
            timeout,
        )?;
        let remote_session_id = required_bounded_string(&result, "sessionId", 256)?;
        let generation = self
            .connections
            .get(agent_id)
            .ok_or(AcpError::UnknownAgent)?
            .generation;
        if self.sessions.values().any(|session| {
            session.agent_id == agent_id
                && session.generation == generation
                && session.remote_session_id == remote_session_id
        }) {
            return Err(AcpError::SessionCollision);
        }
        let session_id = format!("agent-session-{}", self.next_session);
        self.next_session = self.next_session.saturating_add(1);
        self.sessions.insert(
            session_id.clone(),
            AcpSession {
                session_id: session_id.clone(),
                agent_id: agent_id.to_owned(),
                generation,
                remote_session_id,
                workspace_path: workspace_path.to_owned(),
                next_sequence: 1,
                events: VecDeque::with_capacity(MAX_EVENTS_PER_SESSION),
                prompt_request_id: None,
                prompt_result: None,
                client_operations: VecDeque::new(),
                completed_client_operations: HashMap::new(),
                completed_client_operation_order: VecDeque::new(),
            },
        );
        self.session(&session_id)
    }

    pub fn load_session(
        &mut self,
        session_id: &str,
        workspace_path: &str,
        timeout: Duration,
    ) -> Result<AcpSessionSnapshot, AcpError> {
        validate_workspace_path(workspace_path)?;
        let (agent_id, remote_session_id, expected_workspace_path) = {
            let session = self
                .sessions
                .get(session_id)
                .ok_or(AcpError::UnknownSession)?;
            (
                session.agent_id.clone(),
                session.remote_session_id.clone(),
                session.workspace_path.clone(),
            )
        };
        if workspace_path != expected_workspace_path {
            return Err(AcpError::WorkspaceMismatch);
        }
        let connection = self
            .connections
            .get(&agent_id)
            .ok_or(AcpError::UnknownAgent)?;
        if !connection.capabilities.contains("loadSession") {
            return Err(AcpError::CapabilityDenied);
        }
        let current_generation = connection.generation;
        if self.sessions.values().any(|session| {
            session.session_id != session_id
                && session.agent_id == agent_id
                && session.generation == current_generation
                && session.remote_session_id == remote_session_id
        }) {
            return Err(AcpError::SessionCollision);
        }
        let previous_generation = self
            .sessions
            .get(session_id)
            .expect("session checked before load")
            .generation;
        self.sessions
            .get_mut(session_id)
            .expect("session checked before load")
            .generation = current_generation;
        let result = self.request_and_wait(
            &agent_id,
            "session/load",
            json!({
                "sessionId": remote_session_id,
                "cwd": workspace_path,
                "mcpServers": []
            }),
            timeout,
        );
        let result = match result {
            Ok(result) => result,
            Err(error) => {
                self.sessions
                    .get_mut(session_id)
                    .expect("session retained after failed load")
                    .generation = previous_generation;
                return Err(error);
            }
        };
        if !result.is_null() {
            self.sessions
                .get_mut(session_id)
                .expect("session retained after malformed load")
                .generation = previous_generation;
            return Err(AcpError::MalformedMessage);
        }
        self.append_event(
            session_id,
            "session_state".to_owned(),
            None,
            json!({"status": "active", "restored": true}),
        )?;
        self.session(session_id)
    }

    pub fn session(&self, session_id: &str) -> Result<AcpSessionSnapshot, AcpError> {
        let session = self
            .sessions
            .get(session_id)
            .ok_or(AcpError::UnknownSession)?;
        Ok(AcpSessionSnapshot {
            session_id: session.session_id.clone(),
            agent_id: session.agent_id.clone(),
            generation: session.generation,
            remote_session_id: session.remote_session_id.clone(),
        })
    }

    pub fn start_prompt(&mut self, session_id: &str, text: &str) -> Result<(), AcpError> {
        if text.trim().is_empty() || text.len() > 1024 * 1024 {
            return Err(AcpError::MessageTooLarge);
        }
        let (agent_id, remote_session_id, generation) = {
            let session = self
                .sessions
                .get(session_id)
                .ok_or(AcpError::UnknownSession)?;
            if session.prompt_request_id.is_some() {
                return Err(AcpError::PromptInProgress);
            }
            (
                session.agent_id.clone(),
                session.remote_session_id.clone(),
                session.generation,
            )
        };
        if self
            .connections
            .get(&agent_id)
            .is_none_or(|connection| connection.generation != generation)
        {
            return Err(AcpError::UnknownAgent);
        }
        let request_id = self.allocate_request_id(&agent_id)?;
        self.send_json(
            &agent_id,
            json!({
                "jsonrpc": "2.0",
                "id": request_id,
                "method": "session/prompt",
                "params": {
                    "sessionId": remote_session_id,
                    "prompt": [{"type": "text", "text": text}]
                }
            }),
        )?;
        let session = self
            .sessions
            .get_mut(session_id)
            .expect("session checked before prompt send");
        session.prompt_request_id = Some(request_id);
        session.prompt_result = None;
        Ok(())
    }

    pub fn poll(
        &mut self,
        session_id: &str,
        after_sequence: u64,
    ) -> Result<AcpPollResult, AcpError> {
        let agent_id = self
            .sessions
            .get(session_id)
            .ok_or(AcpError::UnknownSession)?
            .agent_id
            .clone();
        let poll = self
            .processes
            .poll(&agent_id, 128)
            .map_err(map_process_error)?;
        if poll.message_too_large {
            return Err(AcpError::MessageTooLarge);
        }
        if poll.protocol_failed {
            return Err(AcpError::MalformedMessage);
        }
        let maximum_message_bytes = self
            .connections
            .get(&agent_id)
            .ok_or(AcpError::UnknownAgent)?
            .maximum_message_bytes;
        for message in poll.messages {
            if message.len() > maximum_message_bytes {
                return Err(AcpError::MessageTooLarge);
            }
            self.route_message(&agent_id, &message)?;
        }
        let session = self
            .sessions
            .get(session_id)
            .ok_or(AcpError::UnknownSession)?;
        if let Some(first) = session.events.front()
            && after_sequence.saturating_add(1) < first.sequence
        {
            return Err(AcpError::ResumeGap);
        }
        let events = session
            .events
            .iter()
            .filter(|event| event.sequence > after_sequence)
            .cloned()
            .collect();
        let mut permissions = self
            .permissions
            .values()
            .filter(|permission| permission.session_id == session_id)
            .map(PendingPermission::snapshot)
            .collect::<Vec<_>>();
        permissions.sort_unstable_by(|left, right| left.permission_id.cmp(&right.permission_id));
        let client_operations = session
            .client_operations
            .iter()
            .map(|pending| pending.request.clone())
            .collect();
        Ok(AcpPollResult {
            events,
            permissions,
            client_operations,
            prompt_result: session.prompt_result.clone(),
            process_exit_code: poll.exit_code,
        })
    }

    pub fn respond_client_operation(
        &mut self,
        session_id: &str,
        operation_id: &str,
        response: Value,
    ) -> Result<(), AcpError> {
        if serde_json::to_vec(&response)
            .map_err(|_| AcpError::MalformedMessage)?
            .len()
            > 1024 * 1024
        {
            return Err(AcpError::MessageTooLarge);
        }
        let (agent_id, request, operation) = {
            let session = self
                .sessions
                .get(session_id)
                .ok_or(AcpError::UnknownSession)?;
            if let Some(previous) = session.completed_client_operations.get(operation_id) {
                return if previous == &response {
                    Ok(())
                } else {
                    Err(AcpError::InvalidRequest)
                };
            }
            let pending = session
                .client_operations
                .iter()
                .find(|pending| pending.request.operation_id == operation_id)
                .ok_or(AcpError::UnknownClientOperation)?;
            (
                session.agent_id.clone(),
                pending.rpc_id.clone(),
                pending.request.clone(),
            )
        };
        let envelope = if response.get("errorCode").is_some() {
            let code = response
                .get("errorCode")
                .and_then(Value::as_str)
                .filter(|code| !code.is_empty() && code.len() <= 128)
                .ok_or(AcpError::InvalidRequest)?;
            let message = response
                .get("message")
                .and_then(Value::as_str)
                .filter(|message| message.len() <= 1024)
                .unwrap_or("IDE operation failed");
            let mut data = Map::new();
            data.insert("errorCode".to_owned(), Value::String(code.to_owned()));
            if let Some(extra) = response.get("data").and_then(Value::as_object) {
                for (key, value) in extra {
                    if key != "errorCode" {
                        data.insert(key.clone(), value.clone());
                    }
                }
            }
            json!({
                "jsonrpc": "2.0",
                "id": request,
                "error": {
                    "code": -32000,
                    "message": message,
                    "data": data
                }
            })
        } else {
            json!({"jsonrpc": "2.0", "id": request, "result": response})
        };
        let completed = envelope.get("error").is_none();
        self.send_json(&agent_id, envelope)?;
        let session = self
            .sessions
            .get_mut(session_id)
            .expect("session retained while operation response is sent");
        let index = session
            .client_operations
            .iter()
            .position(|pending| pending.request.operation_id == operation_id)
            .expect("operation retained while response is sent");
        session.client_operations.remove(index);
        session
            .completed_client_operations
            .insert(operation_id.to_owned(), response);
        session
            .completed_client_operation_order
            .push_back(operation_id.to_owned());
        while session.completed_client_operation_order.len() > MAX_COMPLETED_CLIENT_OPERATIONS {
            if let Some(expired) = session.completed_client_operation_order.pop_front() {
                session.completed_client_operations.remove(&expired);
            }
        }
        self.append_event(
            session_id,
            "client_operation.completed".to_owned(),
            None,
            json!({
                "operationId": operation.operation_id,
                "method": operation.method,
                "status": if completed { "completed" } else { "failed" }
            }),
        )?;
        Ok(())
    }

    pub fn cancel_prompt(&mut self, session_id: &str) -> Result<bool, AcpError> {
        let (agent_id, remote_session_id, active) = {
            let session = self
                .sessions
                .get(session_id)
                .ok_or(AcpError::UnknownSession)?;
            (
                session.agent_id.clone(),
                session.remote_session_id.clone(),
                session.prompt_request_id.is_some(),
            )
        };
        if !active {
            return Ok(false);
        }
        self.send_json(
            &agent_id,
            json!({
                "jsonrpc": "2.0",
                "method": "session/cancel",
                "params": {"sessionId": remote_session_id}
            }),
        )?;
        let permission_ids = self
            .permissions
            .values()
            .filter(|permission| permission.session_id == session_id)
            .map(|permission| permission.permission_id.clone())
            .collect::<Vec<_>>();
        for permission_id in permission_ids {
            let permission = self
                .permissions
                .remove(&permission_id)
                .expect("permission selected from the same map");
            self.send_json(
                &agent_id,
                json!({
                    "jsonrpc": "2.0",
                    "id": permission.rpc_id,
                    "result": {"outcome": {"outcome": "cancelled"}}
                }),
            )?;
        }
        Ok(true)
    }

    pub fn resolve_permission(
        &mut self,
        permission_id: &str,
        option_id: &str,
    ) -> Result<(), AcpError> {
        let permission = self
            .permissions
            .get(permission_id)
            .ok_or(AcpError::UnknownPermission)?;
        if !permission
            .options
            .iter()
            .any(|option| option.option_id == option_id)
        {
            return Err(AcpError::CapabilityDenied);
        }
        let agent_id = permission.agent_id.clone();
        let rpc_id = permission.rpc_id.clone();
        self.send_json(
            &agent_id,
            json!({
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": {
                    "outcome": {"outcome": "selected", "optionId": option_id}
                }
            }),
        )?;
        self.permissions.remove(permission_id);
        Ok(())
    }

    pub fn invoke_extension(
        &mut self,
        agent_id: &str,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, AcpError> {
        let connection = self
            .connections
            .get(agent_id)
            .ok_or(AcpError::UnknownAgent)?;
        if !method.starts_with("_vityo.dev/") || !connection.capabilities.contains(method) {
            return Err(AcpError::CapabilityDenied);
        }
        self.request_and_wait(agent_id, method, params, timeout)
    }

    pub fn disconnect(&mut self, agent_id: &str) -> Result<i32, AcpError> {
        self.connections
            .remove(agent_id)
            .ok_or(AcpError::UnknownAgent)?;
        self.permissions
            .retain(|_, permission| permission.agent_id != agent_id);
        self.processes.close(agent_id).map_err(map_process_error)
    }

    pub fn active_connection_count(&self) -> usize {
        self.connections.len()
    }

    fn request_and_wait(
        &mut self,
        agent_id: &str,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, AcpError> {
        if timeout.is_zero() {
            return Err(AcpError::TimedOut);
        }
        let request_id = self.allocate_request_id(agent_id)?;
        self.send_json(
            agent_id,
            json!({
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params
            }),
        )?;
        let deadline = Instant::now() + timeout;
        loop {
            let poll = self
                .processes
                .poll(agent_id, 128)
                .map_err(map_process_error)?;
            if poll.message_too_large {
                return Err(AcpError::MessageTooLarge);
            }
            if poll.protocol_failed {
                return Err(AcpError::MalformedMessage);
            }
            let maximum_message_bytes = self
                .connections
                .get(agent_id)
                .ok_or(AcpError::UnknownAgent)?
                .maximum_message_bytes;
            for message in poll.messages {
                if message.len() > maximum_message_bytes {
                    return Err(AcpError::MessageTooLarge);
                }
                let value = decode_message(&message)?;
                if value.get("id") == Some(&Value::String(request_id.clone()))
                    && value.get("method").is_none()
                {
                    if let Some(result) = value.get("result") {
                        return Ok(result.clone());
                    }
                    if value.get("error").is_some() {
                        return Err(AcpError::RemoteError);
                    }
                    return Err(AcpError::MalformedMessage);
                }
                self.route_value(agent_id, value)?;
            }
            if poll.exit_code.is_some() {
                return Err(AcpError::ProcessExited);
            }
            if Instant::now() >= deadline {
                return Err(AcpError::TimedOut);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    fn allocate_request_id(&mut self, agent_id: &str) -> Result<String, AcpError> {
        let connection = self
            .connections
            .get_mut(agent_id)
            .ok_or(AcpError::UnknownAgent)?;
        let request_id = format!(
            "vityod-{}-{}",
            connection.generation, connection.next_request
        );
        connection.next_request = connection.next_request.saturating_add(1);
        Ok(request_id)
    }

    fn send_json(&mut self, agent_id: &str, value: Value) -> Result<(), AcpError> {
        let encoded = serde_json::to_vec(&value).map_err(|_| AcpError::MalformedMessage)?;
        if encoded.len()
            > self
                .connections
                .get(agent_id)
                .ok_or(AcpError::UnknownAgent)?
                .maximum_message_bytes
        {
            return Err(AcpError::MessageTooLarge);
        }
        self.processes
            .send(agent_id, &encoded)
            .map_err(map_process_error)
    }

    fn route_message(&mut self, agent_id: &str, message: &[u8]) -> Result<(), AcpError> {
        self.route_value(agent_id, decode_message(message)?)
    }

    fn route_value(&mut self, agent_id: &str, value: Value) -> Result<(), AcpError> {
        let object = value.as_object().ok_or(AcpError::MalformedMessage)?;
        if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
            return Err(AcpError::MalformedMessage);
        }
        if let Some(method) = object.get("method").and_then(Value::as_str) {
            let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
            if object.contains_key("id") {
                return self.route_inbound_request(agent_id, method, object, params);
            }
            return self.route_notification(agent_id, method, params);
        }
        let Some(id) = object.get("id") else {
            return Err(AcpError::MalformedMessage);
        };
        let id = id.as_str().ok_or(AcpError::MalformedMessage)?;
        let session_id = self
            .sessions
            .values()
            .find(|session| {
                session.agent_id == agent_id && session.prompt_request_id.as_deref() == Some(id)
            })
            .map(|session| session.session_id.clone());
        let Some(session_id) = session_id else {
            return Ok(());
        };
        let result = if let Some(result) = object.get("result") {
            result.clone()
        } else if object.get("error").is_some() {
            json!({"errorCode": "remote_error"})
        } else {
            return Err(AcpError::MalformedMessage);
        };
        let session = self
            .sessions
            .get_mut(&session_id)
            .expect("prompt session selected from the same map");
        session.prompt_result = Some(result);
        session.prompt_request_id = None;
        Ok(())
    }

    fn route_notification(
        &mut self,
        agent_id: &str,
        method: &str,
        params: Value,
    ) -> Result<(), AcpError> {
        match method {
            "session/update" => {
                let remote_session_id = required_bounded_string(&params, "sessionId", 256)?;
                let update = params
                    .get("update")
                    .cloned()
                    .ok_or(AcpError::MalformedMessage)?;
                let kind = required_bounded_string(&update, "sessionUpdate", 256)?;
                let text = update
                    .get("content")
                    .and_then(Value::as_object)
                    .and_then(|content| content.get("text"))
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                let session_id = self.session_id_for_remote(agent_id, &remote_session_id)?;
                self.append_event(&session_id, kind, text, update)
            }
            "_vityo.dev/workspace-change-proposal" => {
                // Proposals are correlated requests so the Agent observes the
                // user's review and the transaction receipt. Notifications
                // cannot carry that result and are not projected as proposals.
                let _ = (agent_id, params);
                Ok(())
            }
            "_vityo.dev/capabilities_changed" => {
                let values = params
                    .get("capabilities")
                    .and_then(Value::as_array)
                    .ok_or(AcpError::MalformedMessage)?;
                let connection = self
                    .connections
                    .get_mut(agent_id)
                    .ok_or(AcpError::UnknownAgent)?;
                let mut capabilities = HashSet::new();
                for value in values {
                    let capability = value.as_str().ok_or(AcpError::MalformedMessage)?;
                    if capability == "loadSession"
                        || connection.allowed_extensions.contains(capability)
                    {
                        capabilities.insert(capability.to_owned());
                    }
                }
                connection.capabilities = capabilities;
                Ok(())
            }
            _ => Ok(()),
        }
    }

    fn route_inbound_request(
        &mut self,
        agent_id: &str,
        method: &str,
        object: &Map<String, Value>,
        params: Value,
    ) -> Result<(), AcpError> {
        let rpc_id = object
            .get("id")
            .cloned()
            .ok_or(AcpError::MalformedMessage)?;
        if method != "session/request_permission" {
            let Some(capability) = client_operation_capability(method) else {
                return self.send_json(
                    agent_id,
                    json!({
                        "jsonrpc": "2.0",
                        "id": rpc_id,
                        "error": {"code": -32601, "message": "method not found"}
                    }),
                );
            };
            let connection = self
                .connections
                .get(agent_id)
                .ok_or(AcpError::UnknownAgent)?;
            let enabled = if capability == ClientOperationCapability::WorkspaceChangeProposal {
                connection.capabilities.contains(method)
            } else {
                client_operation_is_enabled(connection.client_capabilities, capability)
            };
            if !enabled {
                return self.send_json(
                    agent_id,
                    json!({
                        "jsonrpc": "2.0",
                        "id": rpc_id,
                        "error": {"code": -32601, "message": "client operation is unavailable"}
                    }),
                );
            }
            if !params.is_object() {
                return Err(AcpError::MalformedMessage);
            }
            let remote_session_id = required_bounded_string(&params, "sessionId", 256)?;
            let session_id = self.session_id_for_remote(agent_id, &remote_session_id)?;
            let session = self
                .sessions
                .get_mut(&session_id)
                .ok_or(AcpError::UnknownSession)?;
            if session.client_operations.len() >= MAX_CLIENT_OPERATIONS_PER_SESSION
                || session
                    .client_operations
                    .iter()
                    .any(|pending| pending.rpc_id == rpc_id)
            {
                return Err(AcpError::CapacityExceeded);
            }
            let operation_id = format!("client-operation-{}", self.next_client_operation);
            self.next_client_operation = self.next_client_operation.saturating_add(1);
            let operation = AcpClientOperation {
                operation_id,
                session_id: session_id.clone(),
                method: method.to_owned(),
                params,
            };
            session.client_operations.push_back(PendingClientOperation {
                request: operation.clone(),
                rpc_id,
            });
            return self.append_event(
                &session_id,
                "client_operation.requested".to_owned(),
                None,
                json!({
                    "operationId": operation.operation_id,
                    "method": operation.method,
                    "status": "requested"
                }),
            );
        }
        let remote_session_id = required_bounded_string(&params, "sessionId", 256)?;
        let session_id = self.session_id_for_remote(agent_id, &remote_session_id)?;
        let tool_call = params
            .get("toolCall")
            .and_then(Value::as_object)
            .ok_or(AcpError::MalformedMessage)?;
        let tool_call_id = required_bounded_string_object(tool_call, "toolCallId", 256)?;
        let tool_call_title = optional_bounded_string_object(tool_call, "title", 512)?;
        let tool_call_kind = optional_bounded_string_object(tool_call, "kind", 256)?;
        let options = params
            .get("options")
            .and_then(Value::as_array)
            .filter(|options| !options.is_empty() && options.len() <= 16)
            .ok_or(AcpError::MalformedMessage)?;
        let mut parsed_options = Vec::with_capacity(options.len());
        let mut option_ids = HashSet::with_capacity(options.len());
        for option in options {
            let option = option.as_object().ok_or(AcpError::MalformedMessage)?;
            let kind = required_bounded_string_object(option, "kind", 64)?;
            let option_id = required_bounded_string_object(option, "optionId", 256)?;
            let name = required_bounded_string_object(option, "name", 512)?;
            let kind = match kind.as_str() {
                "allow_once" => AcpPermissionOptionKind::AllowOnce,
                "allow_always" => AcpPermissionOptionKind::AllowAlways,
                "reject_once" => AcpPermissionOptionKind::RejectOnce,
                "reject_always" => AcpPermissionOptionKind::RejectAlways,
                _ => return Err(AcpError::MalformedMessage),
            };
            if name.chars().any(char::is_control) || !option_ids.insert(option_id.clone()) {
                return Err(AcpError::MalformedMessage);
            }
            parsed_options.push(AcpPermissionOption {
                option_id,
                name,
                kind,
            });
        }
        let permission_id = format!("permission:{}:{}", agent_id, rpc_id);
        if self.permissions.contains_key(&permission_id) {
            return Err(AcpError::MalformedMessage);
        }
        self.permissions.insert(
            permission_id.clone(),
            PendingPermission {
                permission_id,
                agent_id: agent_id.to_owned(),
                session_id,
                rpc_id,
                tool_call_id,
                tool_call_title,
                tool_call_kind,
                options: parsed_options,
            },
        );
        Ok(())
    }

    fn session_id_for_remote(
        &self,
        agent_id: &str,
        remote_session_id: &str,
    ) -> Result<String, AcpError> {
        let generation = self
            .connections
            .get(agent_id)
            .ok_or(AcpError::UnknownAgent)?
            .generation;
        self.sessions
            .values()
            .find(|session| {
                session.agent_id == agent_id
                    && session.generation == generation
                    && session.remote_session_id == remote_session_id
            })
            .map(|session| session.session_id.clone())
            .ok_or(AcpError::UnknownSession)
    }

    fn append_event(
        &mut self,
        session_id: &str,
        kind: String,
        text: Option<String>,
        payload: Value,
    ) -> Result<(), AcpError> {
        if kind.is_empty() {
            return Err(AcpError::MalformedMessage);
        }
        let session = self
            .sessions
            .get_mut(session_id)
            .ok_or(AcpError::UnknownSession)?;
        let event = AcpEvent {
            sequence: session.next_sequence,
            kind,
            text,
            payload,
        };
        session.next_sequence = session.next_sequence.saturating_add(1);
        if session.events.len() == MAX_EVENTS_PER_SESSION {
            session.events.pop_front();
        }
        session.events.push_back(event);
        Ok(())
    }
}

impl PendingPermission {
    fn snapshot(&self) -> AcpPermissionRequest {
        AcpPermissionRequest {
            permission_id: self.permission_id.clone(),
            agent_id: self.agent_id.clone(),
            session_id: self.session_id.clone(),
            tool_call_id: self.tool_call_id.clone(),
            tool_call_title: self.tool_call_title.clone(),
            tool_call_kind: self.tool_call_kind.clone(),
            options: self.options.clone(),
        }
    }
}

fn decode_capabilities(result: &Value, allowed_extensions: &HashSet<String>) -> HashSet<String> {
    let mut capabilities = HashSet::new();
    let Some(agent_capabilities) = result.get("agentCapabilities") else {
        return capabilities;
    };
    if agent_capabilities
        .get("loadSession")
        .and_then(Value::as_bool)
        == Some(true)
    {
        capabilities.insert("loadSession".to_owned());
    }
    let extensions = agent_capabilities
        .pointer("/_meta/vityo.dev/extensions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|capability| allowed_extensions.contains(*capability));
    capabilities.extend(extensions.map(str::to_owned));
    capabilities
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ClientOperationCapability {
    ReadTextFile,
    WriteTextFile,
    Terminal,
    WorkspaceChangeProposal,
}

fn client_operation_capability(method: &str) -> Option<ClientOperationCapability> {
    match method {
        "fs/read_text_file" => Some(ClientOperationCapability::ReadTextFile),
        "fs/write_text_file" => Some(ClientOperationCapability::WriteTextFile),
        "terminal/create"
        | "terminal/output"
        | "terminal/wait_for_exit"
        | "terminal/kill"
        | "terminal/release" => Some(ClientOperationCapability::Terminal),
        "_vityo.dev/workspace-change-proposal" => {
            Some(ClientOperationCapability::WorkspaceChangeProposal)
        }
        _ => None,
    }
}

fn client_operation_is_enabled(
    capabilities: AcpClientCapabilities,
    operation: ClientOperationCapability,
) -> bool {
    match operation {
        ClientOperationCapability::ReadTextFile => capabilities.read_text_file,
        ClientOperationCapability::WriteTextFile => capabilities.write_text_file,
        ClientOperationCapability::Terminal => capabilities.terminal,
        ClientOperationCapability::WorkspaceChangeProposal => false,
    }
}

fn decode_message(bytes: &[u8]) -> Result<Value, AcpError> {
    if bytes.is_empty() || bytes.len() > 1024 * 1024 {
        return Err(AcpError::MessageTooLarge);
    }
    let value: Value = serde_json::from_slice(bytes).map_err(|_| AcpError::MalformedMessage)?;
    value.as_object().ok_or(AcpError::MalformedMessage)?;
    Ok(value)
}

fn required_bounded_string(value: &Value, key: &str, maximum: usize) -> Result<String, AcpError> {
    let object = value.as_object().ok_or(AcpError::MalformedMessage)?;
    required_bounded_string_object(object, key, maximum)
}

fn required_bounded_string_object(
    object: &Map<String, Value>,
    key: &str,
    maximum: usize,
) -> Result<String, AcpError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.len() <= maximum)
        .map(str::to_owned)
        .ok_or(AcpError::MalformedMessage)
}

fn optional_bounded_string_object(
    object: &Map<String, Value>,
    key: &str,
    maximum: usize,
) -> Result<Option<String>, AcpError> {
    let Some(value) = object.get(key) else {
        return Ok(None);
    };
    value
        .as_str()
        .filter(|value| !value.is_empty() && value.len() <= maximum)
        .map(str::to_owned)
        .map(Some)
        .ok_or(AcpError::MalformedMessage)
}

fn validate_workspace_path(workspace_path: &str) -> Result<(), AcpError> {
    if workspace_path.is_empty() || workspace_path.len() > 32 * 1024 {
        return Err(AcpError::InvalidRequest);
    }
    Ok(())
}

fn map_process_error(error: AgentProcessError) -> AcpError {
    match error {
        AgentProcessError::InvalidLaunch | AgentProcessError::InvalidMessage => {
            AcpError::InvalidRequest
        }
        AgentProcessError::CapacityExceeded => AcpError::CapacityExceeded,
        AgentProcessError::StartFailed => AcpError::StartFailed,
        AgentProcessError::UnknownAgent => AcpError::UnknownAgent,
        AgentProcessError::WriteFailed
        | AgentProcessError::PollFailed
        | AgentProcessError::TerminateFailed => AcpError::TransportFailed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn daemon_routes_updates_and_permissions_without_client_side_correlation() {
        let mut runtime = AcpRuntime::default();
        runtime.connections.insert(
            "agent".to_owned(),
            AcpConnection {
                generation: 1,
                next_request: 1,
                maximum_message_bytes: 1024 * 1024,
                capabilities: HashSet::new(),
                allowed_extensions: HashSet::new(),
                client_capabilities: AcpClientCapabilities {
                    read_text_file: true,
                    write_text_file: true,
                    terminal: true,
                },
            },
        );
        runtime.sessions.insert(
            "session".to_owned(),
            AcpSession {
                session_id: "session".to_owned(),
                agent_id: "agent".to_owned(),
                generation: 1,
                remote_session_id: "remote".to_owned(),
                workspace_path: "/workspace".to_owned(),
                next_sequence: 1,
                events: VecDeque::new(),
                prompt_request_id: None,
                prompt_result: None,
                client_operations: VecDeque::new(),
                completed_client_operations: HashMap::new(),
                completed_client_operation_order: VecDeque::new(),
            },
        );
        runtime
            .route_value(
                "agent",
                json!({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": "remote",
                        "update": {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {"text": "bounded"}
                        }
                    }
                }),
            )
            .unwrap();
        runtime
            .route_value(
                "agent",
                json!({
                    "jsonrpc": "2.0",
                    "id": "permission-1",
                    "method": "session/request_permission",
                    "params": {
                        "sessionId": "remote",
                        "toolCall": {"toolCallId": "tool-1"},
                        "options": [
                            {"optionId": "yes", "name": "Allow once", "kind": "allow_once"},
                            {"optionId": "yes-again", "name": "Also allow once", "kind": "allow_once"},
                            {"optionId": "always", "name": "Always allow", "kind": "allow_always"},
                            {"optionId": "no", "name": "Reject once", "kind": "reject_once"},
                            {"optionId": "never", "name": "Always reject", "kind": "reject_always"}
                        ]
                    }
                }),
            )
            .unwrap();

        let session = runtime.sessions.get("session").unwrap();
        assert_eq!(session.events.len(), 1);
        assert_eq!(
            session.events.front().unwrap().text.as_deref(),
            Some("bounded")
        );
        let permission = runtime.permissions.values().next().unwrap().snapshot();
        assert_eq!(permission.session_id, "session");
        assert_eq!(
            permission.options,
            vec![
                AcpPermissionOption {
                    option_id: "yes".to_owned(),
                    name: "Allow once".to_owned(),
                    kind: AcpPermissionOptionKind::AllowOnce,
                },
                AcpPermissionOption {
                    option_id: "yes-again".to_owned(),
                    name: "Also allow once".to_owned(),
                    kind: AcpPermissionOptionKind::AllowOnce,
                },
                AcpPermissionOption {
                    option_id: "always".to_owned(),
                    name: "Always allow".to_owned(),
                    kind: AcpPermissionOptionKind::AllowAlways,
                },
                AcpPermissionOption {
                    option_id: "no".to_owned(),
                    name: "Reject once".to_owned(),
                    kind: AcpPermissionOptionKind::RejectOnce,
                },
                AcpPermissionOption {
                    option_id: "never".to_owned(),
                    name: "Always reject".to_owned(),
                    kind: AcpPermissionOptionKind::RejectAlways,
                },
            ]
        );

        for options in [
            json!([
                {"optionId": "duplicate", "name": "First", "kind": "allow_once"},
                {"optionId": "duplicate", "name": "Second", "kind": "reject_once"}
            ]),
            json!([
                {"optionId": "unknown-kind", "name": "Unsupported", "kind": "allow_temporarily"}
            ]),
        ] {
            assert_eq!(
                runtime.route_value(
                    "agent",
                    json!({
                        "jsonrpc": "2.0",
                        "id": "invalid-permission",
                        "method": "session/request_permission",
                        "params": {
                            "sessionId": "remote",
                            "toolCall": {"toolCallId": "tool-invalid"},
                            "options": options
                        }
                    })
                ),
                Err(AcpError::MalformedMessage)
            );
        }
        assert_eq!(runtime.permissions.len(), 1);
    }

    #[test]
    fn permission_resolution_rejects_unoffered_id_without_consuming_request() {
        let permission_id = "permission:agent:request";
        let mut runtime = AcpRuntime::default();
        runtime.permissions.insert(
            permission_id.to_owned(),
            PendingPermission {
                permission_id: permission_id.to_owned(),
                agent_id: "agent".to_owned(),
                session_id: "session".to_owned(),
                rpc_id: json!("request"),
                tool_call_id: "tool".to_owned(),
                tool_call_title: None,
                tool_call_kind: None,
                options: vec![
                    AcpPermissionOption {
                        option_id: "allow-a".to_owned(),
                        name: "Allow first".to_owned(),
                        kind: AcpPermissionOptionKind::AllowOnce,
                    },
                    AcpPermissionOption {
                        option_id: "allow-b".to_owned(),
                        name: "Allow second".to_owned(),
                        kind: AcpPermissionOptionKind::AllowOnce,
                    },
                ],
            },
        );

        assert_eq!(
            runtime.resolve_permission(permission_id, "not-offered"),
            Err(AcpError::CapabilityDenied)
        );
        let pending = runtime.permissions.get(permission_id).unwrap();
        assert_eq!(pending.options[0].option_id, "allow-a");
        assert_eq!(pending.options[1].option_id, "allow-b");
    }

    #[test]
    fn workspace_change_proposal_notifications_are_not_projected() {
        let mut runtime = AcpRuntime::default();
        runtime.connections.insert(
            "agent".to_owned(),
            AcpConnection {
                generation: 1,
                next_request: 1,
                maximum_message_bytes: 1024 * 1024,
                capabilities: HashSet::new(),
                allowed_extensions: HashSet::from([
                    "_vityo.dev/workspace-change-proposal".to_owned()
                ]),
                client_capabilities: AcpClientCapabilities::default(),
            },
        );
        runtime.sessions.insert(
            "session".to_owned(),
            AcpSession {
                session_id: "session".to_owned(),
                agent_id: "agent".to_owned(),
                generation: 1,
                remote_session_id: "remote".to_owned(),
                workspace_path: "/workspace".to_owned(),
                next_sequence: 1,
                events: VecDeque::new(),
                prompt_request_id: None,
                prompt_result: None,
                client_operations: VecDeque::new(),
                completed_client_operations: HashMap::new(),
                completed_client_operation_order: VecDeque::new(),
            },
        );

        let proposal = json!({
            "sessionId": "remote",
            "proposal": {"proposalId": "proposal-1"}
        });
        runtime
            .route_notification(
                "agent",
                "_vityo.dev/workspace-change-proposal",
                proposal.clone(),
            )
            .unwrap();
        assert!(runtime.sessions["session"].events.is_empty());

        runtime
            .connections
            .get_mut("agent")
            .unwrap()
            .capabilities
            .insert("_vityo.dev/workspace-change-proposal".to_owned());
        runtime
            .route_notification(
                "agent",
                "_vityo.dev/workspace-change-proposal",
                proposal.clone(),
            )
            .unwrap();
        assert!(runtime.sessions["session"].events.is_empty());
    }

    #[test]
    fn initialize_filters_extension_capabilities_to_the_host_allow_list() {
        let proposal = "_vityo.dev/workspace-change-proposal";
        let advertised = json!({
            "agentCapabilities": {
                "_meta": {
                    "vityo.dev": {
                        "extensions": [proposal, "_vityo.dev/unapproved"]
                    }
                }
            }
        });
        let allowed = HashSet::from([proposal.to_owned()]);

        let negotiated = decode_capabilities(&advertised, &allowed);

        assert_eq!(negotiated, allowed);
    }

    #[cfg(unix)]
    #[test]
    fn proposal_is_a_negotiated_correlated_request_with_typed_result_and_error_data() {
        let mut runtime = AcpRuntime::default();
        runtime
            .processes
            .start(AgentProcessLaunch {
                agent_id: "agent".to_owned(),
                executable: std::path::PathBuf::from("/bin/sh"),
                arguments: vec![
                    "-c".to_owned(),
                    "while IFS= read -r line; do printf '%s\\n' \"$line\"; done".to_owned(),
                ],
                working_directory: std::env::current_dir().unwrap(),
            })
            .unwrap();
        runtime.connections.insert(
            "agent".to_owned(),
            AcpConnection {
                generation: 1,
                next_request: 1,
                maximum_message_bytes: 1024 * 1024,
                capabilities: HashSet::new(),
                allowed_extensions: HashSet::from([
                    "_vityo.dev/workspace-change-proposal".to_owned()
                ]),
                client_capabilities: AcpClientCapabilities {
                    read_text_file: true,
                    write_text_file: true,
                    terminal: true,
                },
            },
        );
        runtime.sessions.insert(
            "session".to_owned(),
            AcpSession {
                session_id: "session".to_owned(),
                agent_id: "agent".to_owned(),
                generation: 1,
                remote_session_id: "remote".to_owned(),
                workspace_path: "/workspace".to_owned(),
                next_sequence: 1,
                events: VecDeque::new(),
                prompt_request_id: None,
                prompt_result: None,
                client_operations: VecDeque::new(),
                completed_client_operations: HashMap::new(),
                completed_client_operation_order: VecDeque::new(),
            },
        );
        let request = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "_vityo.dev/workspace-change-proposal",
            "params": {
                "sessionId": "remote",
                "proposal": {
                    "id": "proposal-1",
                    "baseWorkspaceRevision": 7,
                    "resources": [{
                        "resourceId": "src/main.styio",
                        "baseDocumentRevision": 3,
                        "edits": [{"start": 0, "end": 1, "replacement": "M"}]
                    }]
                }
            }
        });

        runtime.route_value("agent", request.clone()).unwrap();
        let denied = next_process_json(&mut runtime, "agent");
        assert_eq!(denied["id"], 1);
        assert_eq!(denied["error"]["code"], -32601);
        assert!(runtime.sessions["session"].client_operations.is_empty());

        runtime
            .connections
            .get_mut("agent")
            .unwrap()
            .capabilities
            .insert("_vityo.dev/workspace-change-proposal".to_owned());
        let mut negotiated_request = request;
        negotiated_request["id"] = json!(2);
        runtime.route_value("agent", negotiated_request).unwrap();
        let operation = runtime.sessions["session"]
            .client_operations
            .front()
            .unwrap()
            .request
            .clone();
        assert_eq!(operation.session_id, "session");
        assert_eq!(operation.params["sessionId"], "remote");
        assert_eq!(operation.method, "_vityo.dev/workspace-change-proposal");
        let proposal_result = json!({
            "proposalId": "proposal-1",
            "outcome": "committed",
            "workspaceRevision": 8,
            "documentRevisions": {"src/main.styio": 4}
        });
        runtime
            .respond_client_operation("session", &operation.operation_id, proposal_result.clone())
            .unwrap();
        let response = next_process_json(&mut runtime, "agent");
        assert_eq!(response["id"], 2);
        assert_eq!(response["result"], proposal_result);

        runtime
            .route_value(
                "agent",
                json!({
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "fs/read_text_file",
                    "params": {"sessionId": "remote", "path": "/workspace/src/new.styio"}
                }),
            )
            .unwrap();
        let operation = runtime.sessions["session"]
            .client_operations
            .front()
            .unwrap()
            .request
            .clone();
        let failure = json!({
            "errorCode": "document_missing",
            "message": "The requested workspace document does not exist.",
            "data": {
                "_meta": {"vityo.dev": {"workspaceSnapshot": {
                    "rootId": "flow-hero",
                    "resourceId": "src/new.styio",
                    "workspaceRevision": 9,
                    "documentExists": false,
                    "documentRevision": null
                }}}
            }
        });
        runtime
            .respond_client_operation("session", &operation.operation_id, failure)
            .unwrap();
        let response = next_process_json(&mut runtime, "agent");
        assert_eq!(response["id"], 3);
        assert_eq!(response["error"]["data"]["errorCode"], "document_missing");
        assert_eq!(
            response["error"]["data"]["_meta"]["vityo.dev"]["workspaceSnapshot"]["documentRevision"],
            Value::Null
        );
        runtime.processes.close("agent").unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn client_operation_requests_are_projected_and_correlated_responses_are_redacted() {
        let mut runtime = AcpRuntime::default();
        runtime
            .processes
            .start(AgentProcessLaunch {
                agent_id: "agent".to_owned(),
                executable: std::path::PathBuf::from("/bin/sh"),
                arguments: vec![
                    "-c".to_owned(),
                    "while IFS= read -r line; do printf '%s\\n' \"$line\"; done".to_owned(),
                ],
                working_directory: std::env::current_dir().unwrap(),
            })
            .unwrap();
        runtime.connections.insert(
            "agent".to_owned(),
            AcpConnection {
                generation: 1,
                next_request: 1,
                maximum_message_bytes: 1024 * 1024,
                capabilities: HashSet::new(),
                allowed_extensions: HashSet::new(),
                client_capabilities: AcpClientCapabilities {
                    read_text_file: true,
                    write_text_file: true,
                    terminal: true,
                },
            },
        );
        runtime.sessions.insert(
            "session".to_owned(),
            AcpSession {
                session_id: "session".to_owned(),
                agent_id: "agent".to_owned(),
                generation: 1,
                remote_session_id: "remote".to_owned(),
                workspace_path: "/workspace".to_owned(),
                next_sequence: 1,
                events: VecDeque::new(),
                prompt_request_id: None,
                prompt_result: None,
                client_operations: VecDeque::new(),
                completed_client_operations: HashMap::new(),
                completed_client_operation_order: VecDeque::new(),
            },
        );
        runtime.sessions.insert(
            "other-session".to_owned(),
            AcpSession {
                session_id: "other-session".to_owned(),
                agent_id: "agent".to_owned(),
                generation: 1,
                remote_session_id: "other-remote".to_owned(),
                workspace_path: "/workspace".to_owned(),
                next_sequence: 1,
                events: VecDeque::new(),
                prompt_request_id: None,
                prompt_result: None,
                client_operations: VecDeque::new(),
                completed_client_operations: HashMap::new(),
                completed_client_operation_order: VecDeque::new(),
            },
        );

        runtime
            .route_value(
                "agent",
                json!({
                    "jsonrpc": "2.0",
                    "id": 7,
                    "method": "fs/write_text_file",
                    "params": {
                        "sessionId": "remote",
                        "path": "/workspace/src/app.styio",
                        "content": "private-source-must-not-enter-the-event-log"
                    }
                }),
            )
            .unwrap();
        let queued = runtime.sessions["session"]
            .client_operations
            .front()
            .unwrap();
        let operation = queued.request.clone();
        assert_eq!(operation.method, "fs/write_text_file");
        assert_eq!(queued.rpc_id, json!(7));
        assert_eq!(
            runtime.respond_client_operation(
                "other-session",
                &operation.operation_id,
                json!({"accepted": true})
            ),
            Err(AcpError::UnknownClientOperation)
        );
        assert_eq!(
            operation.params["content"],
            "private-source-must-not-enter-the-event-log"
        );
        assert_eq!(
            runtime.sessions["session"].events.front().unwrap().kind,
            "client_operation.requested"
        );
        assert!(
            !runtime.sessions["session"]
                .events
                .front()
                .unwrap()
                .payload
                .to_string()
                .contains("private-source")
        );

        let response = json!({"accepted": true});
        runtime
            .respond_client_operation("session", &operation.operation_id, response.clone())
            .unwrap();
        assert_eq!(
            runtime.respond_client_operation("session", &operation.operation_id, response.clone()),
            Ok(())
        );
        assert!(
            runtime
                .respond_client_operation(
                    "session",
                    &operation.operation_id,
                    json!({"accepted": false})
                )
                .is_err()
        );

        let deadline = Instant::now() + Duration::from_secs(3);
        let mut responses = Vec::new();
        while Instant::now() < deadline {
            let output = runtime.processes.poll("agent", 8).unwrap();
            responses.extend(output.messages);
            if !responses.is_empty() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(responses.len(), 1);
        let wire: Value = serde_json::from_slice(&responses[0]).unwrap();
        assert_eq!(wire["id"], json!(7));
        assert_eq!(wire["result"], response);
        assert_eq!(
            runtime.sessions["session"].events.back().unwrap().payload,
            json!({
                "operationId": operation.operation_id,
                "method": "fs/write_text_file",
                "status": "completed"
            })
        );
        runtime.processes.close("agent").unwrap();
    }

    #[cfg(unix)]
    fn next_process_json(runtime: &mut AcpRuntime, agent_id: &str) -> Value {
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            let output = runtime.processes.poll(agent_id, 8).unwrap();
            if let Some(message) = output.messages.first() {
                return serde_json::from_slice(message).unwrap();
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("Agent process did not return an ACP response");
    }
}
