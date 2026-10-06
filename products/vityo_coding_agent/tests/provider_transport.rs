use std::path::PathBuf;

use vityo_coding_agent::providers::{
    NativeCredentialResolver, ProviderAuthMode, ProviderConfig, ProviderConfigError,
    build_provider, load_provider_config,
};

#[test]
fn configuration_accepts_the_supported_openai_chat_schema_and_defaults_bounds() {
    let config = ProviderConfig::parse(&config_json(
        "https://api.example.test/v1",
        r#"{"mode":"none"}"#,
    ))
    .unwrap();
    assert_eq!(config.adapter, "openai_compatible_chat");
    assert_eq!(config.endpoint_base, "https://api.example.test/v1");
    assert_eq!(config.model, "test-model");
    assert_eq!(config.auth.mode, ProviderAuthMode::None);
    let budget = config.usage_budget();
    assert_eq!(budget.max_context_tokens, 8192);
    assert_eq!(budget.max_output_tokens, Some(1024));
    assert_eq!(budget.max_total_tokens, Some(9216));
    assert_eq!(budget.max_buffered_output_bytes, 256 * 1024);
    assert_eq!(budget.max_pending_tool_calls, 16);
}

#[test]
fn configuration_accepts_native_credential_references_without_secret_values() {
    let config = ProviderConfig::parse(&config_json(
        "https://api.example.test/v1",
        r#"{"mode":"bearer_token","secretRef":{"service":"vityo-agent","account":"fixture"}}"#,
    ))
    .unwrap();
    assert_eq!(config.auth.mode, ProviderAuthMode::BearerToken);
    let reference = config.auth.secret_ref.as_ref().unwrap();
    assert_eq!(reference.service, "vityo-agent");
    assert_eq!(reference.account, "fixture");
}

#[test]
fn configuration_rejects_plaintext_remote_endpoints_and_ambiguous_fields() {
    for content in [
        config_json("http://api.example.test/v1", r#"{"mode":"none"}"#),
        config_json(
            "https://user:password@api.example.test/v1",
            r#"{"mode":"none"}"#,
        ),
        config_json(
            "https://api.example.test/v1?token=private",
            r#"{"mode":"none"}"#,
        ),
        config_json(
            "https://api.example.test/v1#fragment",
            r#"{"mode":"none"}"#,
        ),
        br#"{"adapter":"openai_compatible_chat","endpointBase":"https://api.example.test/v1","model":"test-model","capabilities":{"contextTokens":8192,"outputTokens":1024,"supportsTools":true,"maxConcurrency":2},"limits":{"maxTotalTokens":9216},"auth":{"mode":"none","rawCredential":"must-not-be-accepted"}}"#.to_vec(),
        config_json(
            "https://api.example.test/v1",
            r#"{"mode":"bearer_token","secretRef":{"service":"","account":"fixture"}}"#,
        ),
    ] {
        assert!(matches!(
            ProviderConfig::parse(&content),
            Err(ProviderConfigError::InvalidConfiguration)
        ));
    }
}

#[test]
fn configuration_file_read_requires_an_absolute_bounded_file() {
    assert!(matches!(
        ProviderConfig::read(PathBuf::from("relative-provider.json")),
        Err(ProviderConfigError::InvalidConfiguration)
    ));
    let missing =
        std::env::temp_dir().join("vityo-coding-agent-provider-config-does-not-exist.json");
    assert!(matches!(
        ProviderConfig::read(missing),
        Err(ProviderConfigError::ConfigurationRequired)
    ));

    let mut file = tempfile::NamedTempFile::new().unwrap();
    std::io::Write::write_all(
        &mut file,
        &config_json("https://api.example.test/v1", r#"{"mode":"none"}"#),
    )
    .unwrap();
    let config = load_provider_config(file.path()).unwrap();
    let provider = build_provider(config, &NativeCredentialResolver).unwrap();
    assert_eq!(provider.id(), "openai-compatible-chat");

    file.as_file_mut().set_len(64 * 1024 + 1).unwrap();
    assert!(matches!(
        ProviderConfig::read(file.path()),
        Err(ProviderConfigError::InvalidConfiguration)
    ));
}

#[test]
fn configuration_accepts_unbounded_output_and_total_when_omitted() {
    let content = config_with(
        serde_json::json!({
            "contextTokens":8192,
            "supportsTools":true,
            "maxConcurrency":2
        }),
        serde_json::json!({}),
    );
    let config = ProviderConfig::parse(&content).unwrap();
    assert_eq!(config.capabilities().output_tokens, None);
    let budget = config.usage_budget();
    assert_eq!(budget.max_context_tokens, 8192);
    assert_eq!(budget.max_output_tokens, None);
    assert_eq!(budget.max_total_tokens, None);
}

#[test]
fn configuration_validates_explicit_limits_only_when_present() {
    for (capabilities, limits) in [
        (
            serde_json::json!({"contextTokens":8192,"outputTokens":0,"supportsTools":true,"maxConcurrency":1}),
            serde_json::json!({"maxTotalTokens":9216}),
        ),
        (
            serde_json::json!({"contextTokens":8192,"outputTokens":1024,"supportsTools":true,"maxConcurrency":1}),
            serde_json::json!({"maxTotalTokens":0}),
        ),
        (
            serde_json::json!({"contextTokens":8192,"outputTokens":2048,"supportsTools":true,"maxConcurrency":1}),
            serde_json::json!({"maxTotalTokens":1024}),
        ),
        (
            serde_json::json!({"contextTokens":8192,"outputTokens":8193,"supportsTools":true,"maxConcurrency":1}),
            serde_json::json!({"maxTotalTokens":9216}),
        ),
    ] {
        assert!(
            matches!(
                ProviderConfig::parse(&config_with(capabilities, limits)),
                Err(ProviderConfigError::InvalidConfiguration)
            ),
            "explicit zero or output-over-total limits must be rejected"
        );
    }

    for (capabilities, limits) in [
        (
            serde_json::json!({"contextTokens":8192,"outputTokens":2048,"supportsTools":true,"maxConcurrency":1}),
            serde_json::json!({}),
        ),
        (
            serde_json::json!({"contextTokens":8192,"supportsTools":true,"maxConcurrency":1}),
            serde_json::json!({"maxTotalTokens":1024}),
        ),
    ] {
        assert!(
            ProviderConfig::parse(&config_with(capabilities, limits)).is_ok(),
            "output over total is only invalid when both limits are present"
        );
    }
}

#[test]
fn configuration_failures_use_static_non_sensitive_messages() {
    assert_eq!(
        ProviderConfigError::CredentialStoreUnavailable.safe_message(),
        "provider credentials are unavailable"
    );
    assert_eq!(
        ProviderConfigError::InvalidConfiguration.safe_message(),
        "provider configuration is invalid"
    );
}

fn config_with(capabilities: serde_json::Value, limits: serde_json::Value) -> Vec<u8> {
    serde_json::json!({
        "adapter":"openai_compatible_chat",
        "endpointBase":"https://api.example.test/v1",
        "model":"test-model",
        "capabilities":capabilities,
        "limits":limits,
        "auth":{"mode":"none"}
    })
    .to_string()
    .into_bytes()
}

fn config_json(endpoint: &str, auth_json: &str) -> Vec<u8> {
    let auth: serde_json::Value = serde_json::from_str(auth_json).unwrap();
    serde_json::json!({
        "adapter":"openai_compatible_chat",
        "endpointBase":endpoint,
        "model":"test-model",
        "capabilities":{
            "contextTokens":8192,
            "outputTokens":1024,
            "supportsTools":true,
            "maxConcurrency":2
        },
        "limits":{"maxTotalTokens":9216},
        "auth":auth
    })
    .to_string()
    .into_bytes()
}
