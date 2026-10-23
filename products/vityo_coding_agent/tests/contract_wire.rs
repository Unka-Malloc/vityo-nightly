use agent_client_protocol::schema::{ProtocolVersion, v1::InitializeRequest};
use serde_json::{Value, json};
use vityo_coding_agent::protocol::types::{
    ProposalValidationError, VityoWorkspaceChangeOutcome, VityoWorkspaceChangeProposal,
    VityoWorkspaceChangeProposalRequest, VityoWorkspaceChangeProposalResponse,
};

const WORKSPACE_PROPOSAL_FIXTURE: &str =
    include_str!("../fixtures/agent-wire/workspace_change_proposal.json");

#[test]
fn acp_sdk_serializes_the_stable_v1_initialize_shape() {
    let request = InitializeRequest::new(ProtocolVersion::V1);
    let serialized = serde_json::to_value(request).expect("initialize request serializes");

    assert_eq!(serialized["protocolVersion"], json!(1));
    assert!(serialized.get("clientInfo").is_none());
}

#[test]
fn vityo_workspace_proposal_matches_the_shared_wire_fixture() {
    let expected: Value =
        serde_json::from_str(WORKSPACE_PROPOSAL_FIXTURE).expect("fixture is valid JSON");
    let proposal: VityoWorkspaceChangeProposalRequest =
        serde_json::from_value(expected.clone()).expect("fixture follows the wire types");
    proposal.validate().expect("fixture proposal is valid");

    assert_eq!(serde_json::to_value(proposal).unwrap(), expected);
}

#[test]
fn vityo_workspace_proposal_rejects_stale_or_ambiguous_patch_shapes() {
    let mut proposal: VityoWorkspaceChangeProposalRequest =
        serde_json::from_str(WORKSPACE_PROPOSAL_FIXTURE).unwrap();
    proposal
        .proposal
        .resources
        .push(proposal.proposal.resources[0].clone());

    assert_eq!(
        proposal.validate(),
        Err(ProposalValidationError::DuplicateResource)
    );

    let invalid = VityoWorkspaceChangeProposal {
        id: "change-2".to_owned(),
        base_workspace_revision: 8,
        resources: vec![vityo_coding_agent::protocol::types::VityoResourceChange {
            resource_id: "src/app.sty".to_owned(),
            base_document_revision: 4,
            edits: vec![vityo_coding_agent::protocol::types::VityoTextChange {
                start: 5,
                end: 4,
                replacement: "invalid".to_owned(),
            }],
        }],
    };

    assert_eq!(
        invalid.validate(),
        Err(ProposalValidationError::InvalidEditRange)
    );
}

#[test]
fn correlated_proposal_reply_requires_actual_revision_receipt_only_on_commit() {
    let proposal: VityoWorkspaceChangeProposalRequest =
        serde_json::from_str(WORKSPACE_PROPOSAL_FIXTURE).unwrap();
    let committed: VityoWorkspaceChangeProposalResponse = serde_json::from_value(json!({
        "proposalId": proposal.proposal.id,
        "outcome": "committed",
        "workspaceRevision": proposal.proposal.base_workspace_revision + 1,
        "documentRevisions": {
            proposal.proposal.resources[0].resource_id.clone():
                proposal.proposal.resources[0].base_document_revision + 1
        }
    }))
    .unwrap();
    assert!(committed.validates_for(&proposal.proposal));

    let conflict: VityoWorkspaceChangeProposalResponse = serde_json::from_value(json!({
        "proposalId": proposal.proposal.id,
        "outcome": "conflict",
        "code": "workspace_revision_conflict"
    }))
    .unwrap();
    assert!(conflict.validates_for(&proposal.proposal));

    let fabricated_success: VityoWorkspaceChangeProposalResponse = serde_json::from_value(json!({
        "proposalId": proposal.proposal.id,
        "outcome": "committed",
        "workspaceRevision": 0,
        "documentRevisions": {}
    }))
    .unwrap();
    assert!(!fabricated_success.validates_for(&proposal.proposal));
    assert_eq!(conflict.outcome, VityoWorkspaceChangeOutcome::Conflict);
}
