use std::{
    io::Write,
    process::{Command, Output, Stdio},
};

use serde_json::{Value, json};
use tempfile::tempdir;

const BINARY: &str = env!("CARGO_BIN_EXE_vityo-coding-agent");
const PROPOSAL_EXTENSION: &str = "_vityo.dev/workspace-change-proposal";

#[test]
fn packaged_cli_runs_the_real_acp_stdio_lifecycle_with_explicit_configuration() {
    let root = tempdir().unwrap();
    let provider_config = root.path().join("provider.json");
    std::fs::write(
        &provider_config,
        serde_json::to_vec(&json!({
            "adapter":"openai_compatible_chat",
            "endpointBase":"https://api.example.test/v1",
            "model":"acceptance-model",
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
    let sessions = root.path().join("sessions");
    let initialize = json!({
        "jsonrpc":"2.0",
        "id":1,
        "method":"initialize",
        "params":{
            "protocolVersion":1,
            "clientCapabilities":{
                "fs":{"readTextFile":true,"writeTextFile":true},
                "terminal":true,
                "_meta":{"vityo.dev":{"extensions":[PROPOSAL_EXTENSION]}}
            }
        }
    });
    let new_session = json!({
        "jsonrpc":"2.0",
        "id":2,
        "method":"session/new",
        "params":{
            "cwd":root.path().to_string_lossy(),
            "mcpServers":[{
                "name":"fixture",
                "command":std::env::current_exe().unwrap(),
                "args":[],
                "env":[]
            }]
        }
    });
    let supported_session = json!({
        "jsonrpc":"2.0",
        "id":3,
        "method":"session/new",
        "params":{
            "cwd":root.path().to_string_lossy(),
            "mcpServers":[]
        }
    });

    let output = run_stdio_agent(
        &provider_config,
        &sessions,
        &[initialize.clone(), new_session, supported_session],
    );
    assert!(output.status.success());
    let responses = parse_json_lines(&output.stdout);
    let initialize_response = responses
        .iter()
        .find(|message| message.get("id") == Some(&json!(1)))
        .and_then(|message| message.get("result"))
        .expect("initialize response");
    assert_eq!(initialize_response.get("protocolVersion"), Some(&json!(1)));
    assert_eq!(
        initialize_response
            .pointer("/agentCapabilities/loadSession")
            .and_then(Value::as_bool),
        Some(true)
    );
    assert_eq!(
        initialize_response
            .pointer("/agentCapabilities/_meta/vityo.dev/extensions/0")
            .and_then(Value::as_str),
        Some(PROPOSAL_EXTENSION)
    );
    let mcp_response = responses
        .iter()
        .find(|message| message.get("id") == Some(&json!(2)))
        .expect("MCP attachment rejection");
    assert_eq!(
        mcp_response.pointer("/error/code").and_then(Value::as_i64),
        Some(-32003)
    );
    assert_eq!(
        mcp_response
            .pointer("/error/message")
            .and_then(Value::as_str),
        Some("MCP capability unavailable")
    );
    let session_response = responses
        .iter()
        .find(|message| message.get("id") == Some(&json!(3)))
        .and_then(|message| message.get("result"))
        .unwrap_or_else(|| {
            panic!(
                "new-session response missing (exit={:?}, response_shapes={:?}, stderr_empty={})",
                output.status.code(),
                responses
                    .iter()
                    .map(|message| (
                        message.get("id").cloned(),
                        message.get("result").is_some(),
                        message.pointer("/error/code").cloned(),
                    ))
                    .collect::<Vec<_>>(),
                output.stderr.is_empty(),
            )
        });
    assert!(
        session_response
            .pointer("/sessionId")
            .and_then(Value::as_str)
            .is_some_and(|session_id| !session_id.is_empty())
    );
    assert!(sessions.exists());

    // An unsupported client version must negotiate the latest version the
    // Agent actually implements, rather than echoing an unsupported contract.
    let mut future_initialize = initialize;
    future_initialize["params"]["protocolVersion"] = json!(999);
    let output = run_stdio_agent(&provider_config, &sessions, &[future_initialize]);
    assert!(output.status.success());
    let responses = parse_json_lines(&output.stdout);
    assert_eq!(
        responses[0].pointer("/result/protocolVersion"),
        Some(&json!(1))
    );
}

#[test]
fn cli_reports_configuration_errors_without_echoing_local_paths() {
    let root = tempdir().unwrap();
    let missing_config = root.path().join("missing-provider.json");
    let sessions = root.path().join("sessions");
    let output = Command::new(BINARY)
        .args([
            "--stdio-agent",
            "--provider-config",
            missing_config.to_str().unwrap(),
            "--session-dir",
            sessions.to_str().unwrap(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(78));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("provider configuration is required"));
    assert!(!stderr.contains(missing_config.to_string_lossy().as_ref()));
    assert!(output.stdout.is_empty());
}

#[test]
fn version_is_available_without_runtime_configuration() {
    let output = Command::new(BINARY)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .unwrap();
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("ACP v1"));
    assert!(output.stderr.is_empty());
}

fn run_stdio_agent(
    provider_config: &std::path::Path,
    sessions: &std::path::Path,
    messages: &[Value],
) -> Output {
    let mut child = Command::new(BINARY)
        .args([
            "--stdio-agent",
            "--provider-config",
            provider_config.to_str().unwrap(),
            "--session-dir",
            sessions.to_str().unwrap(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    {
        let stdin = child.stdin.as_mut().unwrap();
        for message in messages {
            serde_json::to_writer(&mut *stdin, message).unwrap();
            stdin.write_all(b"\n").unwrap();
        }
    }
    drop(child.stdin.take());
    child.wait_with_output().unwrap()
}

fn parse_json_lines(bytes: &[u8]) -> Vec<Value> {
    String::from_utf8_lossy(bytes)
        .lines()
        .map(|line| {
            serde_json::from_str(line).expect("ACP stdout is one JSON-RPC message per line")
        })
        .collect()
}
