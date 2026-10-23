use std::{
    borrow::Cow,
    collections::{BTreeMap, BTreeSet},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

use async_trait::async_trait;
use rmcp::{
    Peer, RoleClient,
    model::{CallToolRequestParams, CallToolResponse, PaginatedRequestParams, Tool},
    service::{RunningService, Service},
};
use tokio_util::sync::CancellationToken;

use crate::{
    contracts::JsonObject,
    tools::{ToolAdapter, ToolCatalog, ToolDescriptor, ToolRisk, ToolSourceKind},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum McpFailureCode {
    Unavailable,
    Cancelled,
    InvalidResponse,
    SchemaInvalid,
    ResponseTooLarge,
    ToolFailed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct McpFailure {
    pub code: McpFailureCode,
}

impl McpFailure {
    pub const fn safe_message(self) -> &'static str {
        match self.code {
            McpFailureCode::Unavailable => "MCP server is unavailable.",
            McpFailureCode::Cancelled => "MCP operation was cancelled.",
            McpFailureCode::InvalidResponse => "MCP server returned an invalid response.",
            McpFailureCode::SchemaInvalid => "MCP server returned an invalid tool schema.",
            McpFailureCode::ResponseTooLarge => "MCP response exceeds its configured bound.",
            McpFailureCode::ToolFailed => "MCP tool execution failed.",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct McpToolMetadata {
    pub name: String,
    pub description: String,
    pub input_schema: JsonObject,
    pub output_schema: Option<JsonObject>,
}

#[async_trait]
pub trait McpClient: Send + Sync {
    async fn list_tools(
        &self,
        max_tools: usize,
        cancellation: CancellationToken,
    ) -> Result<Vec<McpToolMetadata>, McpFailure>;

    async fn call_tool(
        &self,
        name: &str,
        arguments: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, McpFailure>;
}

/// Thin adapter over the official RMCP client peer.
///
/// The owner keeps the `RunningService` alive and passes this adapter the same
/// client connection; RMCP owns JSON-RPC framing, initialization and pagination.
pub struct RmcpMcpClient {
    peer: Peer<RoleClient>,
}

impl RmcpMcpClient {
    pub fn from_running_service<S: Service<RoleClient>>(
        service: &RunningService<RoleClient, S>,
    ) -> Self {
        Self {
            peer: service.peer().clone(),
        }
    }
}

#[async_trait]
impl McpClient for RmcpMcpClient {
    async fn list_tools(
        &self,
        max_tools: usize,
        cancellation: CancellationToken,
    ) -> Result<Vec<McpToolMetadata>, McpFailure> {
        if max_tools == 0 {
            return Err(McpFailure {
                code: McpFailureCode::ResponseTooLarge,
            });
        }
        let mut tools = Vec::new();
        let mut cursor = None;
        let mut seen_cursors = BTreeSet::new();
        let mut page_count = 0usize;
        loop {
            if cancellation.is_cancelled() {
                return Err(McpFailure {
                    code: McpFailureCode::Cancelled,
                });
            }
            if page_count >= max_tools.saturating_add(1) {
                return Err(McpFailure {
                    code: McpFailureCode::ResponseTooLarge,
                });
            }
            page_count += 1;
            let request = self
                .peer
                .list_tools(Some(PaginatedRequestParams::default().with_cursor(cursor)));
            let page = tokio::select! {
                _ = cancellation.cancelled() => return Err(McpFailure { code: McpFailureCode::Cancelled }),
                result = request => result.map_err(|_| McpFailure { code: McpFailureCode::Unavailable })?,
            };
            for tool in page.tools {
                if tools.len() == max_tools {
                    return Err(McpFailure {
                        code: McpFailureCode::ResponseTooLarge,
                    });
                }
                tools.push(metadata_from_rmcp(tool)?);
            }
            match page.next_cursor {
                Some(next) if seen_cursors.insert(next.clone()) => cursor = Some(next),
                Some(_) => {
                    return Err(McpFailure {
                        code: McpFailureCode::InvalidResponse,
                    });
                }
                None => return Ok(tools),
            }
        }
    }

    async fn call_tool(
        &self,
        name: &str,
        arguments: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, McpFailure> {
        if cancellation.is_cancelled() {
            return Err(McpFailure {
                code: McpFailureCode::Cancelled,
            });
        }
        let request = self
            .peer
            .call_tool_once(CallToolRequestParams::new(name.to_owned()).with_arguments(arguments));
        let response = tokio::select! {
            _ = cancellation.cancelled() => return Err(McpFailure { code: McpFailureCode::Cancelled }),
            result = request => result.map_err(|_| McpFailure { code: McpFailureCode::Unavailable })?,
        };
        let CallToolResponse::Complete(result) = response else {
            return Err(McpFailure {
                code: McpFailureCode::InvalidResponse,
            });
        };
        if result.is_error.unwrap_or(false) {
            return Err(McpFailure {
                code: McpFailureCode::ToolFailed,
            });
        }
        match result.structured_content {
            Some(serde_json::Value::Object(object)) => Ok(object),
            Some(value) => {
                let mut result = JsonObject::new();
                result.insert("result".to_owned(), value);
                Ok(result)
            }
            None => {
                let content = serde_json::to_value(result.content).map_err(|_| McpFailure {
                    code: McpFailureCode::InvalidResponse,
                })?;
                let mut result = JsonObject::new();
                result.insert("content".to_owned(), content);
                Ok(result)
            }
        }
    }
}

fn metadata_from_rmcp(tool: Tool) -> Result<McpToolMetadata, McpFailure> {
    let input_schema = (*tool.input_schema).clone();
    let output_schema = tool.output_schema.map(|schema| (*schema).clone());
    let name = tool.name.into_owned();
    if name.trim().is_empty() {
        return Err(McpFailure {
            code: McpFailureCode::InvalidResponse,
        });
    }
    Ok(McpToolMetadata {
        description: tool
            .description
            .map_or_else(|| name.clone(), Cow::into_owned),
        name,
        input_schema,
        output_schema,
    })
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct McpToolPolicy {
    pub risk: Option<ToolRisk>,
    pub tags: BTreeSet<String>,
    pub path_argument: Option<String>,
    pub network_host_argument: Option<String>,
    pub secret_arguments: BTreeMap<String, String>,
}

pub struct McpToolSource {
    server_id: String,
    client: Arc<dyn McpClient>,
    max_tools: usize,
    max_schema_bytes: usize,
    trusted_policies: BTreeMap<String, McpToolPolicy>,
    generation: AtomicU64,
}

impl McpToolSource {
    pub fn new(
        server_id: impl Into<String>,
        client: Arc<dyn McpClient>,
        max_tools: usize,
        max_schema_bytes: usize,
        trusted_policies: BTreeMap<String, McpToolPolicy>,
    ) -> Result<Self, McpFailure> {
        let server_id = server_id.into();
        if server_id.trim().is_empty() || max_tools == 0 || max_schema_bytes == 0 {
            return Err(McpFailure {
                code: McpFailureCode::SchemaInvalid,
            });
        }
        Ok(Self {
            server_id,
            client,
            max_tools,
            max_schema_bytes,
            trusted_policies,
            generation: AtomicU64::new(0),
        })
    }

    pub async fn refresh(
        &self,
        cancellation: CancellationToken,
    ) -> Result<McpToolSnapshot, McpFailure> {
        let metadata = self
            .client
            .list_tools(self.max_tools, cancellation.clone())
            .await?;
        if cancellation.is_cancelled() || metadata.len() > self.max_tools {
            return Err(McpFailure {
                code: if cancellation.is_cancelled() {
                    McpFailureCode::Cancelled
                } else {
                    McpFailureCode::ResponseTooLarge
                },
            });
        }

        let mut descriptors = Vec::with_capacity(metadata.len());
        let mut adapters: BTreeMap<String, Arc<dyn ToolAdapter>> = BTreeMap::new();
        let mut remote_names = BTreeSet::new();
        for tool in metadata {
            if !remote_names.insert(tool.name.clone()) {
                return Err(McpFailure {
                    code: McpFailureCode::InvalidResponse,
                });
            }
            let schema_bytes = serde_json::to_vec(&serde_json::json!({
                "input": &tool.input_schema,
                "output": &tool.output_schema,
            }))
            .map_err(|_| McpFailure {
                code: McpFailureCode::SchemaInvalid,
            })?
            .len();
            if schema_bytes > self.max_schema_bytes {
                return Err(McpFailure {
                    code: McpFailureCode::ResponseTooLarge,
                });
            }
            let trusted = self
                .trusted_policies
                .get(&tool.name)
                .cloned()
                .unwrap_or_default();
            let id = tool_id(&self.server_id, &tool.name);
            let mut tags = trusted.tags;
            tags.insert("mcp".to_owned());
            let output_schema = tool
                .output_schema
                .unwrap_or_else(super::catalog::empty_object_schema);
            let descriptor = ToolDescriptor::new(
                id.clone(),
                tool.description,
                ToolSourceKind::Mcp,
                tool.input_schema,
                output_schema,
                trusted.risk.unwrap_or(ToolRisk::Destructive),
                tags,
                trusted.path_argument,
                trusted.network_host_argument,
                trusted.secret_arguments,
                64 * 1024,
            )
            .map_err(|_| McpFailure {
                code: McpFailureCode::SchemaInvalid,
            })?;
            adapters.insert(
                id.clone(),
                Arc::new(McpToolAdapter {
                    client: self.client.clone(),
                    remote_name: tool.name,
                }),
            );
            descriptors.push(descriptor);
        }
        let generation = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
        let catalog = ToolCatalog::new(
            format!("mcp/{}/{}", encode_component(&self.server_id), generation),
            descriptors,
            false,
        )
        .map_err(|_| McpFailure {
            code: McpFailureCode::InvalidResponse,
        })?;
        Ok(McpToolSnapshot { catalog, adapters })
    }
}

pub struct McpToolSnapshot {
    pub catalog: ToolCatalog,
    pub adapters: BTreeMap<String, Arc<dyn ToolAdapter>>,
}

struct McpToolAdapter {
    client: Arc<dyn McpClient>,
    remote_name: String,
}

#[async_trait]
impl ToolAdapter for McpToolAdapter {
    async fn execute(
        &self,
        _descriptor: &ToolDescriptor,
        arguments: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, super::ToolAdapterError> {
        self.client
            .call_tool(&self.remote_name, arguments, cancellation)
            .await
            .map_err(|failure| super::ToolAdapterError {
                message: failure.safe_message(),
            })
    }
}

fn tool_id(server_id: &str, remote_name: &str) -> String {
    format!(
        "mcp/{}/{}",
        encode_component(server_id),
        encode_component(remote_name)
    )
}

fn encode_component(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.') {
            output.push(char::from(byte));
        } else {
            use std::fmt::Write as _;
            let _ = write!(output, "%{byte:02X}");
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    use rmcp::{
        RoleClient, RoleServer, ServerHandler, ServiceExt,
        model::{
            CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, ErrorData,
            ListToolsResult, PaginatedRequestParams, ServerCapabilities, ServerConfig, Tool,
        },
        service::{RequestContext, RunningService},
    };
    use serde_json::json;
    use tokio::task::JoinHandle;
    use tokio_util::sync::CancellationToken;

    use super::{McpClient, McpFailureCode, RmcpMcpClient, metadata_from_rmcp, tool_id};

    fn object(value: serde_json::Value) -> crate::contracts::JsonObject {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn rmcp_metadata_maps_schemas_and_defaults_missing_description() {
        let output_schema = object(json!({"type": "object"}));
        let tool = Tool::new_with_raw(
            "lookup",
            None,
            object(json!({"type": "object", "properties": {}})),
        )
        .with_raw_output_schema(Arc::new(output_schema.clone()));

        let metadata = metadata_from_rmcp(tool).unwrap();
        assert_eq!(metadata.name, "lookup");
        assert_eq!(metadata.description, "lookup");
        assert_eq!(metadata.input_schema["type"], "object");
        assert_eq!(metadata.output_schema, Some(output_schema));
    }

    #[test]
    fn rmcp_metadata_rejects_an_empty_tool_name() {
        let tool = Tool::new("", "empty name fixture", object(json!({"type": "object"})));

        let error = metadata_from_rmcp(tool).unwrap_err();
        assert_eq!(error.code, McpFailureCode::InvalidResponse);
    }

    #[test]
    fn server_and_tool_names_are_unambiguously_scoped() {
        assert_ne!(
            tool_id("alpha/beta", "search"),
            tool_id("alpha", "beta/search")
        );
        assert_eq!(tool_id("server", "search"), "mcp/server/search");
    }

    #[derive(Clone, Copy)]
    enum PagingMode {
        Normal,
        RepeatingCursor,
        EndlessEmptyPages,
    }

    #[derive(Clone)]
    struct SyntheticMcpServer {
        paging: PagingMode,
        list_calls: Arc<AtomicUsize>,
    }

    impl ServerHandler for SyntheticMcpServer {
        fn get_info(&self) -> ServerConfig {
            ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
        }

        async fn list_tools(
            &self,
            request: Option<PaginatedRequestParams>,
            _context: RequestContext<RoleServer>,
        ) -> Result<ListToolsResult, ErrorData> {
            let page = self.list_calls.fetch_add(1, Ordering::Relaxed);
            let cursor = request.and_then(|params| params.cursor);
            let mut response = ListToolsResult::default();
            match self.paging {
                PagingMode::EndlessEmptyPages => {
                    response.next_cursor = Some(format!("page-{page}"));
                }
                mode => {
                    let name = match cursor.as_deref() {
                        None => "lookup",
                        Some("page-2" | "same") => "second",
                        Some(_) => {
                            return Err(ErrorData::invalid_params(
                                "unexpected fixture cursor",
                                None,
                            ));
                        }
                    };
                    let schema = object(json!({
                        "type": "object",
                        "properties": {"query": {"type": "string"}},
                        "required": ["query"],
                        "additionalProperties": false
                    }));
                    response.tools.push(Tool::new(name, name, Arc::new(schema)));
                    response.next_cursor = match (mode, cursor.as_deref()) {
                        (PagingMode::Normal, None) => Some("page-2".to_owned()),
                        (PagingMode::RepeatingCursor, None | Some("same")) => {
                            Some("same".to_owned())
                        }
                        _ => None,
                    };
                }
            }
            Ok(response)
        }

        async fn call_tool(
            &self,
            request: CallToolRequestParams,
            _context: RequestContext<RoleServer>,
        ) -> Result<CallToolResponse, ErrorData> {
            let response = match request.name.as_ref() {
                "lookup" => CallToolResult::structured(json!({
                    "query": request.arguments.unwrap_or_default(),
                })),
                "scalar" => CallToolResult::structured(json!("fixture scalar")),
                "text" => CallToolResult::success(vec![ContentBlock::text("fixture result")]),
                "error" => CallToolResult::error(vec![ContentBlock::text("fixture tool error")]),
                _ => {
                    return Err(ErrorData::invalid_params("unknown fixture tool", None));
                }
            };
            Ok(response.into())
        }
    }

    async fn connect_peer(
        paging: PagingMode,
    ) -> (
        RmcpMcpClient,
        RunningService<RoleClient, ()>,
        Arc<AtomicUsize>,
        JoinHandle<()>,
    ) {
        let list_calls = Arc::new(AtomicUsize::new(0));
        let server = SyntheticMcpServer {
            paging,
            list_calls: list_calls.clone(),
        };
        let (server_transport, client_transport) = tokio::io::duplex(4096);
        let server_task = tokio::spawn(async move {
            let service = server
                .serve(server_transport)
                .await
                .expect("synthetic MCP server starts");
            let _ = service.waiting().await;
        });
        let client_service = ().serve(client_transport).await.expect("MCP client connects");
        let client = RmcpMcpClient::from_running_service(&client_service);
        (client, client_service, list_calls, server_task)
    }

    #[tokio::test]
    async fn rmcp_client_pages_converts_calls_and_maps_server_failures() {
        let (client, client_service, list_calls, server_task) =
            connect_peer(PagingMode::Normal).await;
        let tools = client
            .list_tools(2, CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(tools.len(), 2);
        assert_eq!(tools[0].name, "lookup");
        assert_eq!(tools[1].name, "second");
        assert_eq!(tools[0].input_schema["required"], json!(["query"]));
        assert_eq!(list_calls.load(Ordering::Relaxed), 2);

        let output = client
            .call_tool(
                "lookup",
                object(json!({"query": "hello"})),
                CancellationToken::new(),
            )
            .await
            .unwrap();
        assert_eq!(output["query"]["query"], "hello");
        let scalar = client
            .call_tool("scalar", serde_json::Map::new(), CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(scalar["result"], "fixture scalar");
        let text = client
            .call_tool("text", serde_json::Map::new(), CancellationToken::new())
            .await
            .unwrap();
        assert!(text["content"].is_array());
        assert_eq!(
            client
                .call_tool("error", serde_json::Map::new(), CancellationToken::new())
                .await
                .unwrap_err()
                .code,
            McpFailureCode::ToolFailed
        );

        let cancelled = CancellationToken::new();
        cancelled.cancel();
        assert_eq!(
            client.list_tools(2, cancelled).await.unwrap_err().code,
            McpFailureCode::Cancelled
        );
        assert_eq!(
            client
                .call_tool("lookup", serde_json::Map::new(), {
                    let cancelled = CancellationToken::new();
                    cancelled.cancel();
                    cancelled
                })
                .await
                .unwrap_err()
                .code,
            McpFailureCode::Cancelled
        );
        assert_eq!(
            client
                .list_tools(0, CancellationToken::new())
                .await
                .unwrap_err()
                .code,
            McpFailureCode::ResponseTooLarge
        );
        assert_eq!(
            client
                .list_tools(1, CancellationToken::new())
                .await
                .unwrap_err()
                .code,
            McpFailureCode::ResponseTooLarge
        );

        client_service.cancel().await.expect("client shuts down");
        server_task.await.expect("server task finishes");
        assert_eq!(
            client
                .call_tool("lookup", serde_json::Map::new(), CancellationToken::new())
                .await
                .unwrap_err()
                .code,
            McpFailureCode::Unavailable
        );
    }

    #[tokio::test]
    async fn rmcp_client_rejects_repeating_cursors_and_unbounded_empty_pages() {
        let (client, client_service, _, server_task) =
            connect_peer(PagingMode::RepeatingCursor).await;
        assert_eq!(
            client
                .list_tools(4, CancellationToken::new())
                .await
                .unwrap_err()
                .code,
            McpFailureCode::InvalidResponse
        );
        client_service.cancel().await.expect("client shuts down");
        server_task.await.expect("server task finishes");

        let (client, client_service, list_calls, server_task) =
            connect_peer(PagingMode::EndlessEmptyPages).await;
        assert_eq!(
            client
                .list_tools(1, CancellationToken::new())
                .await
                .unwrap_err()
                .code,
            McpFailureCode::ResponseTooLarge
        );
        assert_eq!(list_calls.load(Ordering::Relaxed), 2);
        client_service.cancel().await.expect("client shuts down");
        server_task.await.expect("server task finishes");
    }
}
