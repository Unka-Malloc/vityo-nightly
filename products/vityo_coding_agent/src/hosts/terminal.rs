//! Standard ACP terminal lifecycle adapters.

use std::{collections::BTreeMap, path::PathBuf, sync::Arc};

use agent_client_protocol::{
    Client, ConnectionTo,
    schema::v1::{
        CreateTerminalRequest, KillTerminalRequest, ReleaseTerminalRequest, TerminalOutputRequest,
        WaitForTerminalExitRequest,
    },
};
use async_trait::async_trait;
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;

use crate::{
    contracts::JsonObject,
    tools::{
        ToolAdapter, ToolAdapterError, ToolDescriptor, ToolPathDomain, ToolRisk, ToolSchemaError,
        ToolSourceKind,
    },
};

const MAX_RESULT_BYTES: usize = 256 * 1024;

#[derive(Clone, Copy)]
enum TerminalOperation {
    Create,
    Output,
    WaitForExit,
    Kill,
    Release,
}

struct TerminalAdapter {
    connection: ConnectionTo<Client>,
    session_id: String,
    cwd: PathBuf,
    operation: TerminalOperation,
}

/// Creates adapters for the five standard ACP terminal lifecycle requests.
pub(crate) fn build_terminal_tools(
    connection: ConnectionTo<Client>,
    session_id: String,
    cwd: PathBuf,
) -> Result<Vec<(ToolDescriptor, Arc<dyn ToolAdapter>)>, ToolSchemaError> {
    let definitions = [
        (
            "terminal/create",
            "Create a host-managed terminal and run a command.",
            create_schema(),
            TerminalOperation::Create,
            Some("cwd"),
        ),
        (
            "terminal/output",
            "Read output currently available from a host-managed terminal.",
            terminal_id_schema(),
            TerminalOperation::Output,
            None,
        ),
        (
            "terminal/wait_for_exit",
            "Wait until a host-managed terminal command exits.",
            terminal_id_schema(),
            TerminalOperation::WaitForExit,
            None,
        ),
        (
            "terminal/kill",
            "Terminate a host-managed terminal command without releasing it.",
            terminal_id_schema(),
            TerminalOperation::Kill,
            None,
        ),
        (
            "terminal/release",
            "Release a host-managed terminal and free its resources.",
            terminal_id_schema(),
            TerminalOperation::Release,
            None,
        ),
    ];

    definitions
        .into_iter()
        .map(
            |(id, description, input_schema, operation, path_argument)| {
                let mut descriptor = ToolDescriptor::new(
                    id,
                    description,
                    ToolSourceKind::Builtin,
                    input_schema,
                    output_schema(operation),
                    ToolRisk::Process,
                    ["acp", "terminal"].into_iter().map(str::to_owned),
                    path_argument.map(str::to_owned),
                    None,
                    BTreeMap::new(),
                    MAX_RESULT_BYTES,
                )?;
                if path_argument.is_some() {
                    descriptor = descriptor.with_path_domain(ToolPathDomain::HostManaged)?;
                }
                let adapter: Arc<dyn ToolAdapter> = Arc::new(TerminalAdapter {
                    connection: connection.clone(),
                    session_id: session_id.clone(),
                    cwd: cwd.clone(),
                    operation,
                });
                Ok((descriptor, adapter))
            },
        )
        .collect()
}

#[async_trait]
impl ToolAdapter for TerminalAdapter {
    async fn execute(
        &self,
        _descriptor: &ToolDescriptor,
        arguments: JsonObject,
        cancellation: CancellationToken,
    ) -> Result<JsonObject, ToolAdapterError> {
        let result = match self.operation {
            TerminalOperation::Create => {
                let command = required_string(&arguments, "command")?;
                let args = optional_string_array(&arguments, "args")?;
                let env = optional_env(&arguments)?;
                let cwd = arguments
                    .get("cwd")
                    .and_then(Value::as_str)
                    .map(PathBuf::from)
                    .unwrap_or_else(|| self.cwd.clone());
                if !cwd.is_absolute() {
                    return Err(invalid_arguments());
                }
                let output_byte_limit = output_byte_limit(&arguments)?;
                let request = CreateTerminalRequest::new(self.session_id.clone(), command)
                    .args(args)
                    .env(env)
                    .cwd(cwd)
                    .output_byte_limit(output_byte_limit);
                let request = self.connection.send_request(request);
                tokio::select! {
                    _ = cancellation.cancelled() => return Err(cancelled()),
                    response = request.block_task() => {
                        let response = response.map_err(|_| host_unavailable())?;
                        json!({"ok": true, "terminalId": response.terminal_id.to_string()})
                    }
                }
            }
            TerminalOperation::Output => {
                let terminal_id = terminal_id(&arguments)?;
                let request = self.connection.send_request(TerminalOutputRequest::new(
                    self.session_id.clone(),
                    terminal_id,
                ));
                tokio::select! {
                    _ = cancellation.cancelled() => return Err(cancelled()),
                    response = request.block_task() => {
                        let response = response.map_err(|_| host_unavailable())?;
                        let mut output = json!({
                            "ok": true,
                            "output": response.output,
                            "truncated": response.truncated,
                        });
                        if let Some(exit_status) = response.exit_status {
                            output["exitStatus"] = json!(exit_status);
                        }
                        output
                    }
                }
            }
            TerminalOperation::WaitForExit => {
                let terminal_id = terminal_id(&arguments)?;
                let request = self
                    .connection
                    .send_request(WaitForTerminalExitRequest::new(
                        self.session_id.clone(),
                        terminal_id,
                    ));
                tokio::select! {
                    _ = cancellation.cancelled() => return Err(cancelled()),
                    response = request.block_task() => {
                        let response = response.map_err(|_| host_unavailable())?;
                        json!({"ok": true, "exitStatus": response.exit_status})
                    }
                }
            }
            TerminalOperation::Kill => {
                let terminal_id = terminal_id(&arguments)?;
                let request = self.connection.send_request(KillTerminalRequest::new(
                    self.session_id.clone(),
                    terminal_id,
                ));
                tokio::select! {
                    _ = cancellation.cancelled() => return Err(cancelled()),
                    response = request.block_task() => {
                        response.map_err(|_| host_unavailable())?;
                        json!({"ok": true})
                    }
                }
            }
            TerminalOperation::Release => {
                let terminal_id = terminal_id(&arguments)?;
                let request = self.connection.send_request(ReleaseTerminalRequest::new(
                    self.session_id.clone(),
                    terminal_id,
                ));
                tokio::select! {
                    _ = cancellation.cancelled() => return Err(cancelled()),
                    response = request.block_task() => {
                        response.map_err(|_| host_unavailable())?;
                        json!({"ok": true})
                    }
                }
            }
        };
        object_result(result)
    }
}

fn create_schema() -> JsonObject {
    let mut properties = BTreeMap::new();
    properties.insert("command", json!({"type":"string"}));
    properties.insert("args", json!({"type":"array", "items":{"type":"string"}}));
    properties.insert(
        "env",
        json!({"type":"array", "items":{
            "type":"object",
            "properties":{"name":{"type":"string"},"value":{"type":"string"}},
            "required":["name","value"],
            "additionalProperties":false
        }}),
    );
    properties.insert("cwd", json!({"type":"string"}));
    properties.insert("outputByteLimit", json!({"type":"integer"}));
    schema(properties, &["command"])
}

fn terminal_id_schema() -> JsonObject {
    let mut properties = BTreeMap::new();
    properties.insert("terminalId", json!({"type":"string"}));
    schema(properties, &["terminalId"])
}

fn output_schema(operation: TerminalOperation) -> JsonObject {
    let mut properties = BTreeMap::new();
    properties.insert("ok", json!({"type":"boolean"}));
    match operation {
        TerminalOperation::Create => {
            properties.insert("terminalId", json!({"type":"string"}));
        }
        TerminalOperation::Output => {
            properties.insert("output", json!({"type":"string"}));
            properties.insert("truncated", json!({"type":"boolean"}));
            properties.insert("exitStatus", exit_status_schema());
        }
        TerminalOperation::WaitForExit => {
            properties.insert("exitStatus", exit_status_schema());
        }
        TerminalOperation::Kill | TerminalOperation::Release => {}
    }
    let required = match operation {
        TerminalOperation::Create => &["ok", "terminalId"][..],
        TerminalOperation::Output => &["ok", "output", "truncated"][..],
        TerminalOperation::WaitForExit | TerminalOperation::Kill | TerminalOperation::Release => {
            &["ok"][..]
        }
    };
    schema(properties, required)
}

fn exit_status_schema() -> Value {
    json!({
        "type":"object",
        "properties":{
            "exitCode":{"type":"integer"},
            "signal":{"type":"string"}
        },
        "additionalProperties":false
    })
}

fn schema(properties: BTreeMap<&str, Value>, required: &[&str]) -> JsonObject {
    let properties: serde_json::Map<String, Value> = properties
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value))
        .collect();
    json!({
        "type":"object",
        "properties":properties,
        "required":required,
        "additionalProperties":false
    })
    .as_object()
    .cloned()
    .unwrap_or_default()
}

fn required_string(arguments: &JsonObject, key: &str) -> Result<String, ToolAdapterError> {
    arguments
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(invalid_arguments)
}

fn optional_string_array(
    arguments: &JsonObject,
    key: &str,
) -> Result<Vec<String>, ToolAdapterError> {
    match arguments.get(key) {
        None => Ok(Vec::new()),
        Some(value) => serde_json::from_value(value.clone()).map_err(|_| invalid_arguments()),
    }
}

fn optional_env(
    arguments: &JsonObject,
) -> Result<Vec<agent_client_protocol::schema::v1::EnvVariable>, ToolAdapterError> {
    match arguments.get("env") {
        None => Ok(Vec::new()),
        Some(value) => serde_json::from_value(value.clone()).map_err(|_| invalid_arguments()),
    }
}

fn output_byte_limit(arguments: &JsonObject) -> Result<u64, ToolAdapterError> {
    match arguments.get("outputByteLimit") {
        None => Ok(MAX_RESULT_BYTES as u64),
        Some(value) => value
            .as_u64()
            .filter(|limit| *limit <= MAX_RESULT_BYTES as u64)
            .ok_or_else(invalid_arguments),
    }
}

fn terminal_id(
    arguments: &JsonObject,
) -> Result<agent_client_protocol::schema::v1::TerminalId, ToolAdapterError> {
    let id = required_string(arguments, "terminalId")?;
    Ok(agent_client_protocol::schema::v1::TerminalId::new(id))
}

fn object_result(value: Value) -> Result<JsonObject, ToolAdapterError> {
    value.as_object().cloned().ok_or_else(invalid_arguments)
}

fn invalid_arguments() -> ToolAdapterError {
    ToolAdapterError {
        message: "terminal arguments are invalid",
    }
}

fn cancelled() -> ToolAdapterError {
    ToolAdapterError {
        message: "terminal request was cancelled",
    }
}

fn host_unavailable() -> ToolAdapterError {
    ToolAdapterError {
        message: "terminal host is unavailable",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::ToolSchema;
    use agent_client_protocol::schema::v1::{
        CreateTerminalResponse, KillTerminalResponse, ReleaseTerminalResponse, TerminalExitStatus,
        TerminalOutputResponse, WaitForTerminalExitResponse,
    };
    use agent_client_protocol::{Agent, Client, ConnectionTo, on_receive_request};

    #[test]
    fn exposes_five_process_risk_standard_terminal_tools() {
        let create = create_schema();
        assert_eq!(create.get("required"), Some(&json!(["command"])));
        assert!(ToolSchema::validate_definition(&create, true).is_ok());
        assert!(ToolSchema::validate_definition(&terminal_id_schema(), true).is_ok());
        for operation in [
            TerminalOperation::Create,
            TerminalOperation::Output,
            TerminalOperation::WaitForExit,
            TerminalOperation::Kill,
            TerminalOperation::Release,
        ] {
            assert!(ToolSchema::validate_definition(&output_schema(operation), true).is_ok());
        }
    }

    #[test]
    fn terminal_id_and_create_arguments_reject_missing_or_malformed_values() {
        assert!(terminal_id(&JsonObject::new()).is_err());
        assert!(required_string(&JsonObject::new(), "command").is_err());
        let mut args = JsonObject::new();
        args.insert("terminalId".into(), json!("term-7"));
        assert_eq!(terminal_id(&args).unwrap().to_string(), "term-7");
        args.insert("args".into(), json!(["ok", 4]));
        assert!(optional_string_array(&args, "args").is_err());
        assert_eq!(
            output_byte_limit(&JsonObject::new()).unwrap(),
            MAX_RESULT_BYTES as u64
        );
        args.insert("outputByteLimit".into(), json!(MAX_RESULT_BYTES + 1));
        assert!(output_byte_limit(&args).is_err());
    }

    #[tokio::test]
    async fn adapters_route_all_five_standard_requests_and_keep_host_results() {
        let client = Client
            .builder()
            .on_receive_request(
                async |request: CreateTerminalRequest, responder, _| {
                    assert_eq!(request.session_id.0.as_ref(), "session-test");
                    assert_eq!(request.command, "cargo");
                    assert_eq!(request.args, ["check"]);
                    assert_eq!(request.env.len(), 1);
                    assert_eq!(request.cwd, Some(PathBuf::from("/workspace")));
                    assert_eq!(request.output_byte_limit, Some(4096));
                    responder.respond(CreateTerminalResponse::new("terminal-7"))
                },
                on_receive_request!(),
            )
            .on_receive_request(
                async |request: TerminalOutputRequest, responder, _| {
                    assert_eq!(request.session_id.0.as_ref(), "session-test");
                    assert_eq!(request.terminal_id.to_string(), "terminal-7");
                    responder.respond(
                        TerminalOutputResponse::new("compiler output", true)
                            .exit_status(Some(TerminalExitStatus::new().exit_code(Some(23)))),
                    )
                },
                on_receive_request!(),
            )
            .on_receive_request(
                async |request: WaitForTerminalExitRequest, responder, _| {
                    assert_eq!(request.terminal_id.to_string(), "terminal-7");
                    responder.respond(WaitForTerminalExitResponse::new(
                        TerminalExitStatus::new().exit_code(Some(23)),
                    ))
                },
                on_receive_request!(),
            )
            .on_receive_request(
                async |request: KillTerminalRequest, responder, _| {
                    assert_eq!(request.terminal_id.to_string(), "terminal-7");
                    responder.respond(KillTerminalResponse::new())
                },
                on_receive_request!(),
            )
            .on_receive_request(
                async |request: ReleaseTerminalRequest, responder, _| {
                    assert_eq!(request.terminal_id.to_string(), "terminal-7");
                    responder.respond(ReleaseTerminalResponse::new())
                },
                on_receive_request!(),
            );

        Agent
            .builder()
            .connect_with(client, async |connection: ConnectionTo<Client>| {
                let tools = build_terminal_tools(
                    connection,
                    "session-test".to_owned(),
                    PathBuf::from("/workspace"),
                )
                .unwrap();
                let mut tool_ids: Vec<_> = tools
                    .iter()
                    .map(|(descriptor, _)| {
                        assert_eq!(descriptor.risk, ToolRisk::Process);
                        descriptor.id.as_str()
                    })
                    .collect();
                tool_ids.sort_unstable();
                assert_eq!(
                    tool_ids,
                    [
                        "terminal/create",
                        "terminal/kill",
                        "terminal/output",
                        "terminal/release",
                        "terminal/wait_for_exit"
                    ]
                );
                for (descriptor, adapter) in tools {
                    let arguments = match descriptor.id.as_str() {
                        "terminal/create" => serde_json::from_value(json!({
                            "command":"cargo",
                            "args":["check"],
                            "env":[{"name":"CI","value":"1"}],
                            "outputByteLimit":4096
                        }))
                        .unwrap(),
                        _ => serde_json::from_value(json!({"terminalId":"terminal-7"})).unwrap(),
                    };
                    let output = adapter
                        .execute(&descriptor, arguments, CancellationToken::new())
                        .await
                        .unwrap();
                    assert_eq!(output.get("ok"), Some(&json!(true)));
                    match descriptor.id.as_str() {
                        "terminal/create" => {
                            assert_eq!(output.get("terminalId"), Some(&json!("terminal-7")));
                        }
                        "terminal/output" => {
                            assert_eq!(output.get("output"), Some(&json!("compiler output")));
                            assert_eq!(output.get("truncated"), Some(&json!(true)));
                            assert_eq!(output["exitStatus"]["exitCode"], json!(23));
                        }
                        "terminal/wait_for_exit" => {
                            assert_eq!(output["exitStatus"]["exitCode"], json!(23));
                        }
                        "terminal/kill" | "terminal/release" => {}
                        other => panic!("unexpected terminal tool {other}"),
                    }
                }
                Ok(())
            })
            .await
            .unwrap();
    }
}
