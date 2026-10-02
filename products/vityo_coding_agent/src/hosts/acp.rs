//! ACP v1 host lifecycle for the first-party Coding Agent.

use std::{collections::HashMap, sync::Arc};

use agent_client_protocol::schema::v1::{
    AgentCapabilities, CancelNotification, CloseSessionRequest, CloseSessionResponse, ContentBlock,
    ContentChunk, Implementation, InitializeRequest, InitializeResponse, LoadSessionRequest,
    LoadSessionResponse, NewSessionRequest, NewSessionResponse, PromptCapabilities, PromptRequest,
    PromptResponse, SessionAdditionalDirectoriesCapabilities, SessionCapabilities,
    SessionCloseCapabilities, SessionNotification, SessionUpdate, StopReason, TextContent,
    ToolCall as AcpToolCall, ToolCallContent, ToolCallStatus, ToolCallUpdate as AcpToolCallUpdate,
    ToolCallUpdateFields, ToolKind,
};
use agent_client_protocol::{Agent, ConnectTo, Error, Stdio};
use serde_json::{Map, Value, json};
use tokio::sync::{Mutex, RwLock};
use tokio_util::sync::CancellationToken;

use crate::{
    application::{AgentApplication, AgentSession},
    orchestration::{RuntimeEventSink, RuntimeHostError, RuntimeUpdate},
    protocol::types::VITYO_WORKSPACE_CHANGE_PROPOSAL,
};

use super::operations::SessionOperations;

const AGENT_NAME: &str = "vityo-coding-agent";
const AGENT_VERSION: &str = env!("CARGO_PKG_VERSION");
const MCP_UNAVAILABLE_CODE: i32 = -32003;

fn mcp_unavailable_error() -> Error {
    Error::new(MCP_UNAVAILABLE_CODE, "MCP capability unavailable")
}

#[derive(Clone)]
pub struct AcpHost {
    state: Arc<HostState>,
}

struct HostState {
    application: Arc<AgentApplication>,
    negotiated: RwLock<Option<ClientCapabilities>>,
    sessions: Mutex<HashMap<String, Arc<HostedSession>>>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct ClientCapabilities {
    filesystem_read: bool,
    filesystem_write: bool,
    terminal: bool,
    workspace_change_proposal: bool,
}

struct HostedSession {
    agent_session: Arc<AgentSession>,
    operations: SessionOperations,
    active_prompt: Mutex<Option<ActivePrompt>>,
}

struct ActivePrompt {
    turn_id: String,
    cancellation: CancellationToken,
}

impl AcpHost {
    pub fn new(application: AgentApplication) -> Self {
        Self {
            state: Arc::new(HostState {
                application: Arc::new(application),
                negotiated: RwLock::new(None),
                sessions: Mutex::new(HashMap::new()),
            }),
        }
    }

    pub async fn run_stdio(self) -> Result<(), Error> {
        self.connect_to(Stdio::new()).await
    }

    async fn connect_to(self, transport: impl ConnectTo<Agent>) -> Result<(), Error> {
        let initialize_state = self.state.clone();
        let new_session_state = self.state.clone();
        let load_session_state = self.state.clone();
        let close_session_state = self.state.clone();
        let prompt_state = self.state.clone();
        let cancel_state = self.state.clone();

        Agent
            .builder()
            .on_receive_request(
                async move |request: InitializeRequest, responder, _connection| {
                    let capabilities = ClientCapabilities::from_initialize(&request);
                    *initialize_state.negotiated.write().await = Some(capabilities);
                    let mut agent_capabilities = AgentCapabilities::new()
                        .load_session(true)
                        .prompt_capabilities(PromptCapabilities::new())
                        .session_capabilities(
                            SessionCapabilities::new()
                                .close(Some(SessionCloseCapabilities::new()))
                                .additional_directories(Some(
                                    SessionAdditionalDirectoriesCapabilities::new(),
                                )),
                        );
                    if capabilities.workspace_change_proposal {
                        agent_capabilities = agent_capabilities
                            .meta(extension_metadata(VITYO_WORKSPACE_CHANGE_PROPOSAL));
                    }
                    responder.respond(
                        InitializeResponse::new(request.protocol_version)
                            .agent_capabilities(agent_capabilities)
                            .agent_info(Implementation::new(AGENT_NAME, AGENT_VERSION)),
                    )
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: NewSessionRequest, responder, connection| {
                    let Some(capabilities) =
                        new_session_state.negotiated.read().await.as_ref().copied()
                    else {
                        return responder.respond_with_error(Error::invalid_request());
                    };
                    if !request.mcp_servers.is_empty() {
                        return responder.respond_with_error(mcp_unavailable_error());
                    }
                    let session_id = uuid::Uuid::new_v4().to_string();
                    let operations = match SessionOperations::new(
                        connection,
                        session_id.clone(),
                        request.cwd.clone(),
                        request.additional_directories.clone(),
                        capabilities.filesystem_read,
                        capabilities.filesystem_write,
                        capabilities.terminal,
                        capabilities.workspace_change_proposal,
                        Vec::new(),
                    ) {
                        Ok(operations) => operations,
                        Err(_) => return responder.respond_with_error(Error::invalid_params()),
                    };
                    let agent_session = match new_session_state
                        .application
                        .new_session(
                            session_id.clone(),
                            request.cwd,
                            &request.additional_directories,
                        )
                        .await
                    {
                        Ok(session) => Arc::new(session),
                        Err(_) => return responder.respond_with_error(Error::invalid_params()),
                    };
                    let hosted = Arc::new(HostedSession {
                        agent_session,
                        operations,
                        active_prompt: Mutex::new(None),
                    });
                    new_session_state
                        .sessions
                        .lock()
                        .await
                        .insert(session_id.clone(), hosted);
                    responder.respond(NewSessionResponse::new(session_id))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: LoadSessionRequest, responder, connection| {
                    let Some(capabilities) =
                        load_session_state.negotiated.read().await.as_ref().copied()
                    else {
                        return responder.respond_with_error(Error::invalid_request());
                    };
                    if !request.mcp_servers.is_empty() {
                        return responder.respond_with_error(mcp_unavailable_error());
                    }
                    let session_id = request.session_id.0.to_string();
                    if load_session_state
                        .sessions
                        .lock()
                        .await
                        .contains_key(&session_id)
                    {
                        return responder.respond_with_error(Error::invalid_params());
                    }
                    let agent_session = match load_session_state
                        .application
                        .load_session(
                            session_id.clone(),
                            request.cwd.clone(),
                            &request.additional_directories,
                        )
                        .await
                    {
                        Ok(session) => Arc::new(session),
                        Err(_) => return responder.respond_with_error(Error::invalid_params()),
                    };
                    let restored_grants = match agent_session.permission_grants().await {
                        Ok(grants) => grants,
                        Err(_) => return responder.respond_with_error(Error::internal_error()),
                    };
                    let operations = match SessionOperations::new(
                        connection.clone(),
                        session_id.clone(),
                        request.cwd,
                        request.additional_directories,
                        capabilities.filesystem_read,
                        capabilities.filesystem_write,
                        capabilities.terminal,
                        capabilities.workspace_change_proposal,
                        restored_grants,
                    ) {
                        Ok(operations) => operations,
                        Err(_) => return responder.respond_with_error(Error::invalid_params()),
                    };
                    let hosted = Arc::new(HostedSession {
                        agent_session: agent_session.clone(),
                        operations,
                        active_prompt: Mutex::new(None),
                    });
                    load_session_state
                        .sessions
                        .lock()
                        .await
                        .insert(session_id.clone(), hosted);
                    for turn in agent_session.completed_turns().await {
                        let user = SessionNotification::new(
                            session_id.clone(),
                            SessionUpdate::UserMessageChunk(ContentChunk::new(ContentBlock::Text(
                                TextContent::new(turn.user_text),
                            ))),
                        );
                        let assistant = SessionNotification::new(
                            session_id.clone(),
                            SessionUpdate::AgentMessageChunk(ContentChunk::new(
                                ContentBlock::Text(TextContent::new(turn.assistant_text)),
                            )),
                        );
                        if connection.send_notification(user).is_err()
                            || connection.send_notification(assistant).is_err()
                        {
                            return responder.respond_with_error(Error::internal_error());
                        }
                    }
                    responder.respond(LoadSessionResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: CloseSessionRequest, responder, _connection| {
                    let session_id = request.session_id.0.to_string();
                    if let Some(session) = close_session_state
                        .sessions
                        .lock()
                        .await
                        .remove(&session_id)
                    {
                        if let Some(active) = session.active_prompt.lock().await.take() {
                            active.cancellation.cancel();
                        }
                    }
                    responder.respond(CloseSessionResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: PromptRequest, responder, connection| {
                    let session_id = request.session_id.0.to_string();
                    let Some(session) =
                        prompt_state.sessions.lock().await.get(&session_id).cloned()
                    else {
                        return responder.respond_with_error(Error::invalid_params());
                    };
                    let Ok(user_text) = prompt_text(request.prompt) else {
                        return responder.respond(PromptResponse::new(StopReason::Refusal));
                    };
                    if user_text.trim().is_empty() {
                        return responder.respond(PromptResponse::new(StopReason::Refusal));
                    }
                    let turn_id = uuid::Uuid::new_v4().to_string();
                    let cancellation = CancellationToken::new();
                    {
                        let mut active = session.active_prompt.lock().await;
                        if active.is_some() {
                            return responder.respond(PromptResponse::new(StopReason::Refusal));
                        }
                        *active = Some(ActivePrompt {
                            turn_id: turn_id.clone(),
                            cancellation: cancellation.clone(),
                        });
                    }
                    let session_for_task = session.clone();
                    let session_id_for_task = session_id.clone();
                    let turn_id_for_task = turn_id.clone();
                    let text_for_task = user_text;
                    let task_connection = connection.clone();
                    let spawn = connection.spawn(async move {
                        let event_sink = AcpEventSink {
                            connection: task_connection.clone(),
                            session_id: session_id_for_task.clone(),
                        };
                        let tools = session_for_task.operations.runtime(
                            session_for_task.agent_session.clone(),
                            turn_id_for_task.clone(),
                        );
                        let result = session_for_task
                            .agent_session
                            .run_prompt(
                                session_for_task
                                    .agent_session
                                    .correlation(turn_id_for_task.clone()),
                                &text_for_task,
                                &tools,
                                &event_sink,
                                cancellation.clone(),
                            )
                            .await;
                        let response = match result {
                            Ok(receipt) => {
                                let _ = send_text(
                                    &task_connection,
                                    &session_id_for_task,
                                    receipt.assistant_text,
                                );
                                PromptResponse::new(StopReason::EndTurn)
                            }
                            Err(failure) => {
                                let _ = send_text(
                                    &task_connection,
                                    &session_id_for_task,
                                    failure.safe_message(),
                                );
                                PromptResponse::new(failure.stop_reason())
                            }
                        };
                        let mut active = session_for_task.active_prompt.lock().await;
                        if active
                            .as_ref()
                            .is_some_and(|active| active.turn_id == turn_id_for_task)
                        {
                            active.take();
                        }
                        responder.respond(response)
                    });
                    if spawn.is_err() {
                        session.active_prompt.lock().await.take();
                    }
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_notification(
                async move |notification: CancelNotification, _connection| {
                    let session_id = notification.session_id.0.to_string();
                    if let Some(session) =
                        cancel_state.sessions.lock().await.get(&session_id).cloned()
                        && let Some(active) = session.active_prompt.lock().await.as_ref()
                    {
                        active.cancellation.cancel();
                    }
                    Ok(())
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .connect_to(transport)
            .await
    }
}

impl ClientCapabilities {
    fn from_initialize(request: &InitializeRequest) -> Self {
        Self {
            filesystem_read: request.client_capabilities.fs.read_text_file,
            filesystem_write: request.client_capabilities.fs.write_text_file,
            terminal: request.client_capabilities.terminal,
            workspace_change_proposal: request
                .client_capabilities
                .meta
                .as_ref()
                .is_some_and(|meta| extension_is_advertised(meta, VITYO_WORKSPACE_CHANGE_PROPOSAL))
                && request.client_capabilities.fs.read_text_file
                && request.client_capabilities.fs.write_text_file,
        }
    }
}

fn extension_is_advertised(meta: &Map<String, Value>, extension: &str) -> bool {
    meta.get("vityo.dev")
        .and_then(Value::as_object)
        .and_then(|metadata| metadata.get("extensions"))
        .and_then(Value::as_array)
        .is_some_and(|extensions| {
            extensions
                .iter()
                .any(|value| value.as_str() == Some(extension))
        })
}

fn extension_metadata(extension: &str) -> Map<String, Value> {
    json!({"vityo.dev":{"extensions":[extension]}})
        .as_object()
        .cloned()
        .expect("static extension metadata is an object")
}

fn prompt_text(blocks: Vec<ContentBlock>) -> Result<String, ()> {
    let mut text = String::new();
    for block in blocks {
        match block {
            ContentBlock::Text(content) => {
                if !text.is_empty() {
                    text.push('\n');
                }
                text.push_str(&content.text);
            }
            ContentBlock::ResourceLink(resource) => {
                if !text.is_empty() {
                    text.push('\n');
                }
                text.push_str("Reference: ");
                text.push_str(&resource.name);
                text.push_str(" (\"");
                text.push_str(&resource.uri.to_string());
                text.push_str("\")");
            }
            _ => return Err(()),
        }
    }
    Ok(text)
}

fn send_text(
    connection: &agent_client_protocol::ConnectionTo<agent_client_protocol::Client>,
    session_id: &str,
    text: impl Into<String>,
) -> Result<(), Error> {
    connection.send_notification(SessionNotification::new(
        session_id.to_owned(),
        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(TextContent::new(
            text,
        )))),
    ))
}

struct AcpEventSink {
    connection: agent_client_protocol::ConnectionTo<agent_client_protocol::Client>,
    session_id: String,
}

#[async_trait::async_trait]
impl RuntimeEventSink for AcpEventSink {
    async fn emit(&self, update: RuntimeUpdate) -> Result<(), RuntimeHostError> {
        let update = match update {
            RuntimeUpdate::ToolStarted { call_id, name } => SessionUpdate::ToolCall(
                AcpToolCall::new(call_id, format!("Running {name}"))
                    .name(name)
                    .kind(ToolKind::Execute)
                    .status(ToolCallStatus::InProgress),
            ),
            RuntimeUpdate::ToolFinished {
                call_id,
                name,
                successful,
                summary,
            } => {
                let content = vec![ToolCallContent::from(ContentBlock::Text(TextContent::new(
                    summary,
                )))];
                SessionUpdate::ToolCallUpdate(AcpToolCallUpdate::new(
                    call_id,
                    ToolCallUpdateFields::new()
                        .name(name)
                        .status(if successful {
                            ToolCallStatus::Completed
                        } else {
                            ToolCallStatus::Failed
                        })
                        .content(content),
                ))
            }
        };
        self.connection
            .send_notification(SessionNotification::new(self.session_id.clone(), update))
            .map_err(|_| RuntimeHostError::ConnectionClosed)
    }
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        thread,
        time::{Duration, Instant},
    };

    use super::*;
    use agent_client_protocol::schema::v1::{
        ClientCapabilities as AcpClientCapabilities, CloseSessionRequest, FileSystemCapabilities,
        LoadSessionRequest, McpServer, McpServerStdio, PermissionOptionKind, PromptRequest,
        ReadTextFileRequest, ReadTextFileResponse, RequestPermissionOutcome,
        RequestPermissionRequest, RequestPermissionResponse, SelectedPermissionOutcome,
    };
    use agent_client_protocol::{Channel, Client, ConnectionTo};
    use serde_json::Value;
    use tempfile::tempdir;

    use crate::{
        application::AgentApplication,
        protocol::types::{
            VityoWorkspaceChangeOutcome, VityoWorkspaceChangeProposalRequest,
            VityoWorkspaceChangeProposalResponse,
        },
        providers::NativeCredentialResolver,
        sessions::{
            EffectExecutionOutcome, FileSessionEventStore, SessionEventKind, SessionEventStore,
        },
    };

    #[test]
    fn proposal_extension_requires_exact_client_advertisement_and_filesystem_support() {
        let mut request =
            InitializeRequest::new(agent_client_protocol::schema::ProtocolVersion::V1)
                .client_capabilities(
                    AcpClientCapabilities::new()
                        .fs(FileSystemCapabilities::new()
                            .read_text_file(true)
                            .write_text_file(true))
                        .meta(extension_metadata(VITYO_WORKSPACE_CHANGE_PROPOSAL)),
                );
        assert!(ClientCapabilities::from_initialize(&request).workspace_change_proposal);

        request.client_capabilities.meta = Some(extension_metadata("_vityo.dev/other"));
        assert!(!ClientCapabilities::from_initialize(&request).workspace_change_proposal);

        request.client_capabilities.meta =
            Some(extension_metadata(VITYO_WORKSPACE_CHANGE_PROPOSAL));
        request.client_capabilities.fs = FileSystemCapabilities::new().read_text_file(true);
        assert!(!ClientCapabilities::from_initialize(&request).workspace_change_proposal);
    }

    #[test]
    fn prompt_text_accepts_baseline_text_and_resource_links_only() {
        use agent_client_protocol::schema::v1::ResourceLink;
        let result = prompt_text(vec![
            ContentBlock::Text(TextContent::new("edit this")),
            ContentBlock::ResourceLink(ResourceLink::new("source", "file:///src/main.rs")),
        ])
        .unwrap();
        assert!(result.contains("edit this"));
        assert!(result.contains("file:///src/main.rs"));
        assert!(
            prompt_text(vec![ContentBlock::Image(
                agent_client_protocol::schema::v1::ImageContent::new("AA==", "image/png"),
            )])
            .is_err()
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn configured_react_flow_records_commit_rejection_conflict_and_recovers_over_acp_sse() {
        let proposal_outcomes = [
            VityoWorkspaceChangeOutcome::Committed,
            VityoWorkspaceChangeOutcome::Rejected,
            VityoWorkspaceChangeOutcome::Conflict,
        ];
        let root = tempdir().unwrap();
        let workspace = root.path().join("workspace");
        std::fs::create_dir(&workspace).unwrap();
        let session_directory = root.path().join("sessions");
        let provider_config = root.path().join("provider.json");
        std::fs::write(
            &provider_config,
            serde_json::to_vec(&json!({
                "adapter":"openai_compatible_chat",
                "endpointBase":"https://api.example.test/v1",
                "model":"fixture-model",
                "capabilities":{
                    "contextTokens":8192,
                    "outputTokens":512,
                    "supportsTools":true,
                    "maxConcurrency":1
                },
                "limits":{"maxTotalTokens":9216},
                "auth":{"mode":"none"}
            }))
            .unwrap(),
        )
        .unwrap();
        let file_path = workspace.join("main.sty");
        let (provider_endpoint, provider_server) =
            sse_agent_fixture(file_path.clone(), proposal_outcomes.to_vec());
        let application = AgentApplication::from_paths_with_test_transport(
            &provider_config,
            &session_directory,
            &NativeCredentialResolver,
            &provider_endpoint,
        )
        .unwrap();
        let host = AcpHost::new(application);
        let host_state = host.state.clone();
        let (host_transport, client_transport) = Channel::duplex();
        let host_connection = host.connect_to(host_transport);

        let permission_requests = Arc::new(AtomicUsize::new(0));
        let permission_requests_for_callback = permission_requests.clone();
        let read_path = file_path.clone();
        let workspace_snapshot = json!({
            "vityo.dev":{
                "workspaceSnapshot":{
                    "rootId":"flow-hero",
                    "workspaceId":"flow-hero",
                    "resourceId":"main.sty",
                    "workspaceRevision":41,
                    "documentExists":true,
                    "documentRevision":8,
                    "sourceRevision":9,
                    "sourceKind":"open-buffer",
                    "sourceDirty":false,
                    "proposalEligible":true
                }
            }
        })
        .as_object()
        .unwrap()
        .clone();
        let (session_id_tx, session_id_rx) = tokio::sync::oneshot::channel();
        let proposal_outcomes_for_callback = proposal_outcomes.to_vec();
        let client_connection = Client
            .builder()
            .on_receive_request(
                async move |request: RequestPermissionRequest, responder, _connection| {
                    permission_requests_for_callback.fetch_add(1, Ordering::Relaxed);
                    let option = request
                        .options
                        .iter()
                        .find(|option| option.kind == PermissionOptionKind::AllowOnce)
                        .map(|option| option.option_id.clone());
                    let outcome = option.map_or(RequestPermissionOutcome::Cancelled, |option_id| {
                        RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
                            option_id,
                        ))
                    });
                    responder.respond(RequestPermissionResponse::new(outcome))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: ReadTextFileRequest, responder, _connection| {
                    assert_eq!(request.path.file_name(), read_path.file_name());
                    responder.respond(
                        ReadTextFileResponse::new("source text from the ACP peer")
                            .meta(workspace_snapshot.clone()),
                    )
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: VityoWorkspaceChangeProposalRequest,
                            responder,
                            _connection| {
                    assert_eq!(request.proposal.base_workspace_revision, 41);
                    assert_eq!(request.proposal.resources.len(), 1);
                    assert_eq!(request.proposal.resources[0].resource_id, "main.sty");
                    assert_eq!(request.proposal.resources[0].base_document_revision, 8);
                    let index = request
                        .proposal
                        .id
                        .strip_prefix("proposal-fixture-")
                        .and_then(|index| index.parse::<usize>().ok())
                        .expect("proposal fixture has an outcome index");
                    let outcome = proposal_outcomes_for_callback[index];
                    let committed = outcome == VityoWorkspaceChangeOutcome::Committed;
                    responder.respond(VityoWorkspaceChangeProposalResponse {
                        proposal_id: request.proposal.id,
                        outcome,
                        workspace_revision: committed.then_some(42),
                        document_revisions: committed
                            .then(|| [("main.sty".to_owned(), 9)].into_iter().collect()),
                        code: (!committed).then(|| match outcome {
                            VityoWorkspaceChangeOutcome::Rejected => "user_rejected".to_owned(),
                            VityoWorkspaceChangeOutcome::Conflict => {
                                "workspace_revision_conflict".to_owned()
                            }
                            VityoWorkspaceChangeOutcome::Failed => "host_failed".to_owned(),
                            VityoWorkspaceChangeOutcome::Committed => unreachable!(),
                        }),
                    })
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_notification(
                async move |_notification: SessionNotification, _connection| Ok(()),
                agent_client_protocol::on_receive_notification!(),
            )
            .connect_with(
                client_transport,
                async move |connection: ConnectionTo<Agent>| {
                    let capabilities = AcpClientCapabilities::new()
                        .fs(FileSystemCapabilities::new()
                            .read_text_file(true)
                            .write_text_file(true))
                        .meta(extension_metadata(VITYO_WORKSPACE_CHANGE_PROPOSAL));
                    let initialized = connection
                        .send_request(
                            InitializeRequest::new(
                                agent_client_protocol::schema::ProtocolVersion::V1,
                            )
                            .client_capabilities(capabilities),
                        )
                        .block_task()
                        .await?;
                    assert!(
                        initialized
                            .agent_capabilities
                            .meta
                            .as_ref()
                            .is_some_and(|meta| extension_is_advertised(
                                meta,
                                VITYO_WORKSPACE_CHANGE_PROPOSAL
                            ))
                    );
                    let mut session_ids = Vec::with_capacity(proposal_outcomes.len());
                    for index in 0..proposal_outcomes.len() {
                        let session = connection
                            .send_request(
                                NewSessionRequest::new(workspace.clone()).mcp_servers(Vec::new()),
                            )
                            .block_task()
                            .await?;
                        let session_id = session.session_id.0.to_string();
                        let prompt = connection
                            .send_request(PromptRequest::new(
                                session.session_id.clone(),
                                vec![ContentBlock::Text(TextContent::new(
                                    "Read the source, propose the prepared edit, and report the result.",
                                ))],
                            ))
                            .block_task()
                            .await?;
                        assert_eq!(prompt.stop_reason, StopReason::EndTurn);
                        session_ids.push(session_id);

                        if index == 0 {
                            let session_id = session_ids[0].clone();
                            connection
                                .send_request(CloseSessionRequest::new(session_id.clone()))
                                .block_task()
                                .await?;
                            let attachment = McpServer::Stdio(McpServerStdio::new(
                                "unsupported-fixture",
                                std::env::current_exe().map_err(Error::into_internal_error)?,
                            ));
                            let rejected = connection
                                .send_request(
                                    LoadSessionRequest::new(session_id.clone(), workspace.clone())
                                        .mcp_servers(vec![attachment]),
                                )
                                .block_task()
                                .await
                                .expect_err("load with MCP attachments must be rejected");
                            assert_eq!(i32::from(rejected.code), MCP_UNAVAILABLE_CODE);
                            connection
                                .send_request(LoadSessionRequest::new(
                                    session_id,
                                    workspace.clone(),
                                ))
                                .block_task()
                                .await?;
                        }
                    }
                    session_id_tx
                        .send(session_ids)
                        .map_err(|_| Error::internal_error())?;
                    Ok::<(), Error>(())
                },
            );

        let joined = tokio::time::timeout(Duration::from_secs(20), async {
            tokio::join!(host_connection, client_connection)
        })
        .await
        .expect("in-memory ACP composition must complete");
        assert!(joined.0.is_ok());
        assert!(joined.1.is_ok());
        assert_eq!(
            permission_requests.load(Ordering::Relaxed),
            proposal_outcomes.len()
        );

        let session_ids = session_id_rx.await.unwrap();
        for (session_id, expected_outcome) in session_ids.iter().zip(proposal_outcomes) {
            let session = host_state
                .sessions
                .lock()
                .await
                .get(session_id)
                .cloned()
                .expect("session retained or restored after load");
            let completed_turns = session.agent_session.completed_turns().await;
            assert_eq!(completed_turns.len(), 1);
            assert_eq!(
                completed_turns[0].assistant_text,
                format!(
                    "The {} outcome was recorded.",
                    outcome_name(expected_outcome)
                )
            );
            let receipts = session
                .agent_session
                .effect_journal()
                .load_effect_receipts(session_id, 8)
                .await
                .unwrap();
            assert_eq!(receipts.len(), 1);
            assert_eq!(
                receipts[0].outcome,
                if expected_outcome == VityoWorkspaceChangeOutcome::Committed {
                    EffectExecutionOutcome::Committed
                } else {
                    EffectExecutionOutcome::Rejected
                }
            );
            assert_eq!(
                receipts[0].metadata["outcome"],
                json!(outcome_name(expected_outcome))
            );
            if expected_outcome == VityoWorkspaceChangeOutcome::Committed {
                assert_eq!(receipts[0].metadata["workspaceRevision"], json!(42));
            } else {
                assert!(receipts[0].metadata["workspaceRevision"].is_null());
            }
        }

        let requests = provider_server.join().unwrap();
        assert_eq!(requests.len(), proposal_outcomes.len() * 3);
        assert!(requests[0]["tools"].as_array().is_some_and(|tools| {
            tools.iter().any(|tool| {
                tool.pointer("/function/description")
                    .and_then(Value::as_str)
                    .is_some_and(|description| description.contains("Read a text file"))
            })
        }));
        for (index, outcome) in proposal_outcomes.iter().enumerate() {
            assert!(
                requests[index * 3 + 1]["messages"]
                    .as_array()
                    .is_some_and(|messages| messages.iter().any(|message| {
                        message["role"] == "tool"
                            && message["content"].as_str().is_some_and(|content| {
                                content.contains("source text from the ACP peer")
                            })
                    }))
            );
            let expected = format!("\"outcome\":\"{}\"", outcome_name(*outcome));
            assert!(
                requests[index * 3 + 2]["messages"]
                    .as_array()
                    .is_some_and(|messages| messages.iter().any(|message| {
                        message["role"] == "tool"
                            && message["content"]
                                .as_str()
                                .is_some_and(|content| content.contains(&expected))
                    }))
            );
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn acp_cancel_during_workspace_read_cancels_react_turn_and_records_terminal_failure() {
        let root = tempdir().unwrap();
        let workspace = root.path().join("workspace");
        std::fs::create_dir(&workspace).unwrap();
        let session_directory = root.path().join("sessions");
        let provider_config = root.path().join("provider.json");
        std::fs::write(
            &provider_config,
            serde_json::to_vec(&json!({
                "adapter":"openai_compatible_chat",
                "endpointBase":"https://api.example.test/v1",
                "model":"fixture-model",
                "capabilities":{
                    "contextTokens":8192,
                    "outputTokens":512,
                    "supportsTools":true,
                    "maxConcurrency":1
                },
                "limits":{"maxTotalTokens":9216},
                "auth":{"mode":"none"}
            }))
            .unwrap(),
        )
        .unwrap();
        let file_path = workspace.join("main.sty");
        std::fs::write(&file_path, "source").unwrap();
        let (provider_endpoint, provider_server) = single_read_tool_fixture(file_path.clone());
        let application = AgentApplication::from_paths_with_test_transport(
            &provider_config,
            &session_directory,
            &NativeCredentialResolver,
            &provider_endpoint,
        )
        .unwrap();
        let host = AcpHost::new(application);
        let host_state = host.state.clone();
        let (host_transport, client_transport) = Channel::duplex();
        let host_connection = host.connect_to(host_transport);

        let (read_started_tx, read_started_rx) = tokio::sync::oneshot::channel();
        let (read_response_tx, read_response_rx) = tokio::sync::oneshot::channel();
        let (session_id_tx, session_id_rx) = tokio::sync::oneshot::channel();
        let expected_read_path = Arc::new(file_path);
        let read_started_tx = Arc::new(Mutex::new(Some(read_started_tx)));
        let read_response_tx = Arc::new(Mutex::new(Some(read_response_tx)));
        let permission_requests = Arc::new(AtomicUsize::new(0));
        let permission_requests_for_callback = permission_requests.clone();
        let client_connection = Client
            .builder()
            .on_receive_request(
                async move |request: RequestPermissionRequest, responder, _connection| {
                    permission_requests_for_callback.fetch_add(1, Ordering::Relaxed);
                    let option = request
                        .options
                        .iter()
                        .find(|option| option.kind == PermissionOptionKind::AllowOnce)
                        .map(|option| option.option_id.clone());
                    let outcome = option.map_or(RequestPermissionOutcome::Cancelled, |option_id| {
                        RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
                            option_id,
                        ))
                    });
                    responder.respond(RequestPermissionResponse::new(outcome))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: ReadTextFileRequest, responder, connection| {
                    assert_eq!(request.path, *expected_read_path);
                    read_started_tx
                        .lock()
                        .await
                        .take()
                        .expect("only one read is expected")
                        .send(())
                        .expect("test client is waiting for the workspace read");
                    connection
                        .send_notification(CancelNotification::new(request.session_id.clone()))
                        .map_err(|_| Error::internal_error())?;
                    let response = responder.respond(ReadTextFileResponse::new("source"));
                    let _ = read_response_tx
                        .lock()
                        .await
                        .take()
                        .expect("only one read is expected")
                        .send(response.is_ok());
                    response
                },
                agent_client_protocol::on_receive_request!(),
            )
            .connect_with(
                client_transport,
                async move |connection: ConnectionTo<Agent>| {
                    let capabilities = AcpClientCapabilities::new()
                        .fs(FileSystemCapabilities::new().read_text_file(true));
                    connection
                        .send_request(
                            InitializeRequest::new(
                                agent_client_protocol::schema::ProtocolVersion::V1,
                            )
                            .client_capabilities(capabilities),
                        )
                        .block_task()
                        .await?;
                    let session = connection
                        .send_request(NewSessionRequest::new(workspace))
                        .block_task()
                        .await?;
                    let session_id = session.session_id.0.to_string();
                    let prompt = connection.send_request(PromptRequest::new(
                        session.session_id.clone(),
                        vec![ContentBlock::Text(TextContent::new("Read the source."))],
                    ));
                    let prompt = prompt.block_task();
                    let response = prompt.await?;
                    assert_eq!(response.stop_reason, StopReason::Cancelled);
                    read_started_rx.await.map_err(|_| Error::internal_error())?;
                    assert!(read_response_rx.await.unwrap());
                    session_id_tx
                        .send(session_id)
                        .map_err(|_| Error::internal_error())?;
                    Ok::<(), Error>(())
                },
            );

        let joined = tokio::time::timeout(Duration::from_secs(15), async {
            tokio::join!(host_connection, client_connection)
        })
        .await
        .expect("ACP cancellation must settle the prompt");
        assert!(joined.0.is_ok());
        assert!(joined.1.is_ok());
        assert_eq!(permission_requests.load(Ordering::Relaxed), 1);

        let session_id = session_id_rx.await.unwrap();
        let session = host_state
            .sessions
            .lock()
            .await
            .get(&session_id)
            .cloned()
            .expect("cancelled session remains available for recovery");
        assert!(session.agent_session.completed_turns().await.is_empty());
        let receipts = session
            .agent_session
            .effect_journal()
            .load_effect_receipts(&session_id, 8)
            .await
            .unwrap();
        assert!(receipts.is_empty());

        let store = FileSessionEventStore::new(&session_directory, 256, 65_536);
        let events = store.load(&session_id, 0, 32).await.unwrap();
        assert!(!events.corrupted_tail);
        assert!(events.events.iter().any(|event| {
            event.kind == SessionEventKind::TerminalRecorded
                && event.payload["outcome"] == "failed"
                && event.payload["failure"] == "cancelled"
        }));
        assert!(!events.events.iter().any(|event| {
            event.kind == SessionEventKind::TurnRecorded && event.payload["status"] == "completed"
        }));

        let provider_request = provider_server.join().unwrap();
        assert!(provider_request["tools"].as_array().is_some_and(|tools| {
            tools.iter().any(|tool| {
                tool.pointer("/function/description")
                    .and_then(Value::as_str)
                    .is_some_and(|description| description.contains("Read a text file"))
            })
        }));
    }

    fn sse_agent_fixture(
        file_path: std::path::PathBuf,
        proposal_outcomes: Vec<VityoWorkspaceChangeOutcome>,
    ) -> (String, thread::JoinHandle<Vec<Value>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let endpoint = format!("http://{}/v1", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let mut requests = Vec::with_capacity(proposal_outcomes.len() * 3);
            for (index, outcome) in proposal_outcomes.into_iter().enumerate() {
                let (first_stream, first) = read_fixture_request(&listener);
                let first_json = fixture_request_body(&first);
                let read_alias = tool_alias(&first_json, "Read a text file");
                let proposal_alias = tool_alias(&first_json, "Propose a revision-bound");
                requests.push(first_json);
                write_fixture_response(
                    first_stream,
                    &tool_call_stream(
                        &read_alias,
                        &format!("call-read-{index}"),
                        json!({"path":file_path.to_string_lossy()}),
                    ),
                );

                let (second_stream, second) = read_fixture_request(&listener);
                requests.push(fixture_request_body(&second));
                let proposal_id = format!("proposal-fixture-{index}");
                write_fixture_response(
                    second_stream,
                    &tool_call_stream(
                        &proposal_alias,
                        &format!("call-review-{index}"),
                        json!({
                            "proposal":{
                                "id":proposal_id,
                                "baseWorkspaceRevision":41,
                                "resources":[{
                                    "resourceId":"main.sty",
                                    "baseDocumentRevision":8,
                                    "edits":[{"start":0,"end":6,"replacement":"module"}]
                                }]
                            }
                        }),
                    ),
                );

                let (third_stream, third) = read_fixture_request(&listener);
                requests.push(fixture_request_body(&third));
                write_fixture_response(
                    third_stream,
                    &text_stream(&format!(
                        "The {} outcome was recorded.",
                        outcome_name(outcome)
                    )),
                );
            }
            requests
        });
        (endpoint, server)
    }

    fn single_read_tool_fixture(
        file_path: std::path::PathBuf,
    ) -> (String, thread::JoinHandle<Value>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let endpoint = format!("http://{}/v1", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (stream, request) = read_fixture_request(&listener);
            let request = fixture_request_body(&request);
            let read_alias = tool_alias(&request, "Read a text file");
            write_fixture_response(
                stream,
                &tool_call_stream(
                    &read_alias,
                    "call-cancelled-read",
                    json!({"path":file_path.to_string_lossy()}),
                ),
            );
            request
        });
        (endpoint, server)
    }

    fn outcome_name(outcome: VityoWorkspaceChangeOutcome) -> &'static str {
        match outcome {
            VityoWorkspaceChangeOutcome::Committed => "committed",
            VityoWorkspaceChangeOutcome::Rejected => "rejected",
            VityoWorkspaceChangeOutcome::Conflict => "conflict",
            VityoWorkspaceChangeOutcome::Failed => "failed",
        }
    }

    fn accept_fixture_connection(listener: &TcpListener) -> TcpStream {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(10)))
                        .unwrap();
                    return stream;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        Instant::now() < deadline,
                        "model fixture did not receive a request"
                    );
                    thread::sleep(Duration::from_millis(5));
                }
                Err(error) => panic!("model fixture listener failed: {error}"),
            }
        }
    }

    fn read_fixture_request(listener: &TcpListener) -> (TcpStream, String) {
        let mut stream = accept_fixture_connection(listener);
        let mut header = Vec::new();
        let mut byte = [0_u8; 1];
        while !header.ends_with(b"\r\n\r\n") {
            stream
                .read_exact(&mut byte)
                .expect("model fixture received complete headers");
            header.push(byte[0]);
        }
        let header_text = String::from_utf8(header.clone()).unwrap();
        let content_length = header_text
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            })
            .expect("model request declares its body length");
        let body_start = header.len();
        header.resize(body_start + content_length, 0);
        stream
            .read_exact(&mut header[body_start..])
            .expect("model fixture received complete body");
        (stream, String::from_utf8(header).unwrap())
    }

    fn fixture_request_body(request: &str) -> Value {
        serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap()
    }

    fn tool_alias(request: &Value, description: &str) -> String {
        request["tools"]
            .as_array()
            .unwrap()
            .iter()
            .find_map(|tool| {
                tool.pointer("/function/description")
                    .and_then(Value::as_str)
                    .filter(|value| value.contains(description))
                    .and_then(|_| tool.pointer("/function/name"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .expect("expected production tool definition")
    }

    fn tool_call_stream(alias: &str, id: &str, arguments: Value) -> String {
        let encoded_arguments = serde_json::to_string(&arguments).unwrap();
        sse_stream([
            json!({
                "id":"fixture",
                "object":"chat.completion.chunk",
                "created":1,
                "model":"fixture-model",
                "choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{
                    "index":0,
                    "id":id,
                    "type":"function",
                    "function":{"name":alias,"arguments":encoded_arguments}
                }]},"finish_reason":null}]
            }),
            json!({
                "id":"fixture",
                "object":"chat.completion.chunk",
                "created":1,
                "model":"fixture-model",
                "choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]
            }),
            json!({
                "id":"fixture",
                "object":"chat.completion.chunk",
                "created":1,
                "model":"fixture-model",
                "choices":[],
                "usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}
            }),
        ])
    }

    fn text_stream(text: &str) -> String {
        sse_stream([
            json!({
                "id":"fixture",
                "object":"chat.completion.chunk",
                "created":1,
                "model":"fixture-model",
                "choices":[{"index":0,"delta":{"role":"assistant","content":text},"finish_reason":"stop"}]
            }),
            json!({
                "id":"fixture",
                "object":"chat.completion.chunk",
                "created":1,
                "model":"fixture-model",
                "choices":[],
                "usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}
            }),
        ])
    }

    fn sse_stream(events: impl IntoIterator<Item = Value>) -> String {
        let mut body = events
            .into_iter()
            .map(|event| format!("data: {event}\n\n"))
            .collect::<String>();
        body.push_str("data: [DONE]\n\n");
        body
    }

    fn write_fixture_response(mut stream: TcpStream, body: &str) {
        let headers = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        stream.write_all(headers.as_bytes()).unwrap();
        stream.write_all(body.as_bytes()).unwrap();
        stream.flush().unwrap();
    }
}
