use vityo_coding_agent::{
    policy::{ToolPathScope, *},
    tools::ToolRisk,
};

fn policy() -> ExecutionPolicy {
    ExecutionPolicy::new(
        1,
        [ToolRisk::Read, ToolRisk::Write, ToolRisk::Network],
        ["example.test".to_owned()],
        1024,
    )
    .unwrap()
}

fn roots() -> Vec<ToolRoot> {
    vec![ToolRoot::resource_uri("workspace", "workspace://project/src/").unwrap()]
}

fn grants(tool: &str, root: &str) -> PermissionGrantStore {
    let mut grants = PermissionGrantStore::new(4).unwrap();
    assert!(
        grants.grant(
            PermissionGrant::new(
                "edit-grant",
                "session",
                tool,
                [ToolRisk::Write],
                [root.to_owned()],
            )
            .unwrap(),
        )
    );
    grants
}

#[test]
fn permission_is_bound_to_session_tool_risk_and_root() {
    let grants = grants("source.edit", "workspace");
    let evaluator = DefaultPolicyEvaluator;
    let mut effect = ToolEffect::new("source.edit", ToolRisk::Write);

    assert!(
        evaluator
            .evaluate(&effect, &policy(), &roots(), &grants, "session")
            .allowed()
    );
    assert_eq!(
        evaluator
            .evaluate(&effect, &policy(), &roots(), &grants, "other-session")
            .code,
        PolicyDecisionCode::PermissionDenied
    );
    effect.tool_id = "source.read".to_owned();
    assert_eq!(
        evaluator
            .evaluate(&effect, &policy(), &roots(), &grants, "session")
            .code,
        PolicyDecisionCode::PermissionDenied
    );
}

#[test]
fn path_scope_uses_segment_boundaries_and_rejects_encoded_traversal() {
    let grants = grants("source.read", "workspace");
    let evaluator = DefaultPolicyEvaluator;
    let mut effect = ToolEffect::new("source.read", ToolRisk::Write);
    effect.path_scope = Some(ToolPathScope::ResourceUri {
        requested_uri: "workspace://project/src/main.sty".to_owned(),
        resolved_uri: "workspace://project/src/main.sty".to_owned(),
    });
    assert!(
        evaluator
            .evaluate(&effect, &policy(), &roots(), &grants, "session")
            .allowed()
    );

    effect.path_scope = Some(ToolPathScope::ResourceUri {
        requested_uri: "workspace://project/src-elsewhere/main.sty".to_owned(),
        resolved_uri: "workspace://project/src-elsewhere/main.sty".to_owned(),
    });
    assert_eq!(
        evaluator
            .evaluate(&effect, &policy(), &roots(), &grants, "session")
            .code,
        PolicyDecisionCode::PathDenied
    );

    effect.path_scope = Some(ToolPathScope::ResourceUri {
        requested_uri: "workspace://project/src/%2e%2e/secrets.sty".to_owned(),
        resolved_uri: "workspace://project/src/%2e%2e/secrets.sty".to_owned(),
    });
    assert_eq!(
        evaluator
            .evaluate(&effect, &policy(), &roots(), &grants, "session")
            .code,
        PolicyDecisionCode::PathDenied
    );
}

#[test]
fn resolved_symlink_target_must_remain_under_the_requested_root() {
    let grants = grants("source.read", "workspace");
    let evaluator = DefaultPolicyEvaluator;
    let mut effect = ToolEffect::new("source.read", ToolRisk::Write);
    effect.path_scope = Some(ToolPathScope::ResourceUri {
        requested_uri: "workspace://project/src/link.sty".to_owned(),
        resolved_uri: "workspace://other/secrets.sty".to_owned(),
    });

    assert_eq!(
        evaluator
            .evaluate(&effect, &policy(), &roots(), &grants, "session")
            .code,
        PolicyDecisionCode::PathDenied
    );
}

#[test]
fn host_managed_scope_requires_its_exact_root_and_normalized_relative_path() {
    let roots = vec![ToolRoot::host_managed("flow-hero").unwrap()];
    let mut grants = PermissionGrantStore::new(4).unwrap();
    grants.grant(
        PermissionGrant::new(
            "host-grant",
            "session",
            "source.read",
            [ToolRisk::Read],
            ["flow-hero".to_owned()],
        )
        .unwrap(),
    );
    let evaluator = DefaultPolicyEvaluator;
    let mut effect = ToolEffect::new("source.read", ToolRisk::Read);
    effect.path_scope = Some(ToolPathScope::HostManaged {
        root_id: "flow-hero".to_owned(),
        relative_path: "src/main.sty".to_owned(),
    });
    assert!(
        evaluator
            .evaluate(&effect, &policy(), &roots, &grants, "session")
            .allowed()
    );

    if let Some(ToolPathScope::HostManaged { relative_path, .. }) = effect.path_scope.as_mut() {
        *relative_path = "src/../private.sty".to_owned();
    }
    assert_eq!(
        evaluator
            .evaluate(&effect, &policy(), &roots, &grants, "session")
            .code,
        PolicyDecisionCode::PathDenied
    );

    effect.path_scope = Some(ToolPathScope::HostManaged {
        root_id: "other-workspace".to_owned(),
        relative_path: "src/main.sty".to_owned(),
    });
    assert_eq!(
        evaluator
            .evaluate(&effect, &policy(), &roots, &grants, "session")
            .code,
        PolicyDecisionCode::PathDenied
    );
}

#[test]
fn credentials_and_network_hosts_are_checked_before_permission() {
    let mut grants = PermissionGrantStore::new(4).unwrap();
    grants.grant(
        PermissionGrant::new(
            "network-grant",
            "session",
            "http.fetch",
            [ToolRisk::Network],
            ["workspace".to_owned()],
        )
        .unwrap(),
    );
    let evaluator = DefaultPolicyEvaluator;
    let mut effect = ToolEffect::new("http.fetch", ToolRisk::Network);
    effect.network_host = Some(" EXAMPLE.TEST ".to_owned());
    assert!(
        evaluator
            .evaluate(&effect, &policy(), &roots(), &grants, "session")
            .allowed()
    );

    effect.network_host = Some("other.test".to_owned());
    assert_eq!(
        evaluator
            .evaluate(&effect, &policy(), &roots(), &grants, "session")
            .code,
        PolicyDecisionCode::HostDenied
    );

    effect.network_host = Some("example.test".to_owned());
    effect.raw_credential_detected = true;
    assert_eq!(
        evaluator
            .evaluate(&effect, &policy(), &roots(), &grants, "session")
            .code,
        PolicyDecisionCode::CredentialDenied
    );
}

#[test]
fn grant_revocation_and_bounded_replacement_apply_immediately() {
    let mut grants = PermissionGrantStore::new(1).unwrap();
    let first = PermissionGrant::new(
        "grant-1",
        "session",
        "source.edit",
        [ToolRisk::Write],
        ["workspace".to_owned()],
    )
    .unwrap();
    let second = PermissionGrant::new(
        "grant-2",
        "session",
        "source.edit",
        [ToolRisk::Write],
        ["other".to_owned()],
    )
    .unwrap();
    grants.grant(first);
    assert!(grants.allows("session", "source.edit", ToolRisk::Write, "workspace"));
    grants.grant(second);
    assert_eq!(grants.active_grant_count(), 1);
    assert!(!grants.allows("session", "source.edit", ToolRisk::Write, "workspace"));
    assert!(grants.allows("session", "source.edit", ToolRisk::Write, "other"));
    assert!(grants.revoke("grant-2"));
    assert!(!grants.allows("session", "source.edit", ToolRisk::Write, "other"));
}

#[test]
fn secret_key_redaction_preserves_non_secret_arguments() {
    let arguments =
        serde_json::from_value::<serde_json::Map<String, serde_json::Value>>(serde_json::json!({
            "query": "safe text",
            "api_key": "secret://credential-id?audience=remote", // placeholder URI
            "nested": {"accessToken": "secret-value"} // placeholder token
        }))
        .unwrap();
    let redacted = redact_argument_secrets(&arguments);
    assert_eq!(redacted["query"], serde_json::json!("safe text"));
    assert_eq!(redacted["api_key"], serde_json::json!("[redacted]"));
    assert_eq!(
        redacted["nested"]["accessToken"],
        serde_json::json!("[redacted]")
    );
    assert!(ToolRoot::resource_uri("", "workspace://project/").is_none());
    assert!(ToolRoot::resource_uri("workspace", "workspace://project/../outside").is_none());
    assert!(ToolRoot::host_managed(" ").is_none());
}
