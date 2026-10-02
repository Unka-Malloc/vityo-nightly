//! Typed wire contract for the existing Vityo ACP extension.

use std::collections::HashSet;

use agent_client_protocol::{JsonRpcRequest, JsonRpcResponse};
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const ACP_PROTOCOL_VERSION: u8 = 1;
pub const VITYO_EXTENSION_PREFIX: &str = "_vityo.dev/";
pub const VITYO_WORKSPACE_CHANGE_PROPOSAL: &str = "_vityo.dev/workspace-change-proposal";
pub const ACP_MAX_MESSAGE_BYTES: usize = 1024 * 1024;
pub const MAX_PROPOSAL_RESOURCES: usize = 64;
pub const MAX_PROPOSAL_EDITS: usize = 500;
pub const MAX_REPLACEMENT_UTF16_UNITS: usize = 200_000;

/// Params for the capability-gated, correlated workspace proposal request.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VityoWorkspaceChangeProposalRequest {
    pub session_id: String,
    pub proposal: VityoWorkspaceChangeProposal,
}

impl JsonRpcRequest for VityoWorkspaceChangeProposalRequest {
    type Response = VityoWorkspaceChangeProposalResponse;
}

impl agent_client_protocol::JsonRpcMessage for VityoWorkspaceChangeProposalRequest {
    fn matches_method(method: &str) -> bool {
        method == VITYO_WORKSPACE_CHANGE_PROPOSAL
    }

    fn method(&self) -> &str {
        VITYO_WORKSPACE_CHANGE_PROPOSAL
    }

    fn to_untyped_message(
        &self,
    ) -> agent_client_protocol::Result<agent_client_protocol::UntypedMessage> {
        agent_client_protocol::UntypedMessage::new(VITYO_WORKSPACE_CHANGE_PROPOSAL, self)
    }

    fn parse_message(
        method: &str,
        params: &impl serde::Serialize,
    ) -> agent_client_protocol::Result<Self> {
        if method != VITYO_WORKSPACE_CHANGE_PROPOSAL {
            return Err(agent_client_protocol::Error::method_not_found());
        }
        agent_client_protocol::util::json_cast_params(params)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum VityoWorkspaceChangeOutcome {
    Committed,
    Rejected,
    Conflict,
    Failed,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VityoWorkspaceChangeProposalResponse {
    pub proposal_id: String,
    pub outcome: VityoWorkspaceChangeOutcome,
    #[serde(default)]
    pub workspace_revision: Option<u64>,
    #[serde(default)]
    pub document_revisions: Option<std::collections::BTreeMap<String, u64>>,
    #[serde(default)]
    pub code: Option<String>,
}

impl JsonRpcResponse for VityoWorkspaceChangeProposalResponse {
    fn into_json(self, _method: &str) -> agent_client_protocol::Result<serde_json::Value> {
        serde_json::to_value(self).map_err(agent_client_protocol::Error::into_internal_error)
    }

    fn from_value(_method: &str, value: serde_json::Value) -> agent_client_protocol::Result<Self> {
        agent_client_protocol::util::json_cast(&value)
    }
}

/// A patch bound to one observed workspace revision.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VityoWorkspaceChangeProposal {
    pub id: String,
    pub base_workspace_revision: u64,
    pub resources: Vec<VityoResourceChange>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VityoResourceChange {
    pub resource_id: String,
    pub base_document_revision: u64,
    pub edits: Vec<VityoTextChange>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VityoTextChange {
    pub start: u64,
    pub end: u64,
    pub replacement: String,
}

#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum ProposalValidationError {
    #[error("proposal identifier is empty or too long")]
    InvalidProposalId,
    #[error("proposal must contain between 1 and 64 resources")]
    InvalidResourceCount,
    #[error("resource identifier is empty or too long")]
    InvalidResourceId,
    #[error("proposal contains duplicate resource identifiers")]
    DuplicateResource,
    #[error("each resource must contain between 1 and 500 edits")]
    InvalidEditCount,
    #[error("text edit range is reversed")]
    InvalidEditRange,
    #[error("proposal exceeds the replacement text limit")]
    ReplacementTextTooLarge,
}

impl VityoWorkspaceChangeProposalRequest {
    pub fn validate(&self) -> Result<(), ProposalValidationError> {
        if self.session_id.is_empty() || utf16_len(&self.session_id) > 256 {
            return Err(ProposalValidationError::InvalidProposalId);
        }
        self.proposal.validate()
    }
}

impl VityoWorkspaceChangeProposalResponse {
    pub fn validates_for(&self, proposal: &VityoWorkspaceChangeProposal) -> bool {
        if self.proposal_id != proposal.id {
            return false;
        }
        match self.outcome {
            VityoWorkspaceChangeOutcome::Committed => {
                let Some(revisions) = self.document_revisions.as_ref() else {
                    return false;
                };
                self.workspace_revision.is_some()
                    && revisions.len() == proposal.resources.len()
                    && proposal
                        .resources
                        .iter()
                        .all(|resource| revisions.contains_key(&resource.resource_id))
            }
            _ => self.workspace_revision.is_none() && self.document_revisions.is_none(),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum WorkspaceSourceKind {
    OpenBuffer,
    Workspace,
}

/// Host-attested workspace state returned with one standard ACP read result.
/// `document_revision: None` with `document_exists: false` means known absence,
/// while an absent snapshot is represented by no value at all.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSnapshot {
    pub root_id: String,
    pub workspace_id: String,
    pub resource_id: String,
    pub workspace_revision: u64,
    pub document_exists: bool,
    pub document_revision: Option<u64>,
    #[serde(default)]
    pub source_revision: Option<u64>,
    #[serde(default)]
    pub source_kind: Option<WorkspaceSourceKind>,
    #[serde(default)]
    pub source_dirty: Option<bool>,
    #[serde(default)]
    pub proposal_eligible: bool,
}

impl WorkspaceSnapshot {
    pub fn parse(value: &serde_json::Value) -> Option<Self> {
        let object = value.as_object()?;
        // Revision null is a meaningful, explicit absence observation. Missing
        // `documentRevision` is malformed and must not be confused with null.
        if !object.contains_key("documentRevision") {
            return None;
        }
        let snapshot: Self = serde_json::from_value(value.clone()).ok()?;
        if snapshot.root_id.trim().is_empty()
            || snapshot.workspace_id.trim().is_empty()
            || snapshot.resource_id.trim().is_empty()
            || (snapshot.document_exists != snapshot.document_revision.is_some())
        {
            return None;
        }
        if !snapshot.document_exists
            && (snapshot.proposal_eligible || snapshot.source_revision.is_some())
        {
            return None;
        }
        if snapshot.proposal_eligible
            && (snapshot.document_revision.is_none()
                || snapshot.source_kind.is_none()
                || snapshot.source_dirty != Some(false))
        {
            return None;
        }
        Some(snapshot)
    }

    pub fn proposal_base(&self) -> Option<(u64, u64)> {
        (self.document_exists && self.proposal_eligible && self.source_dirty == Some(false))
            .then_some((self.workspace_revision, self.document_revision?))
    }
}

pub fn workspace_snapshot_from_meta(
    meta: Option<&agent_client_protocol::schema::v1::Meta>,
) -> Option<WorkspaceSnapshot> {
    WorkspaceSnapshot::parse(meta?.get("vityo.dev")?.get("workspaceSnapshot")?)
}

pub fn workspace_snapshot_from_error_data(
    data: Option<&serde_json::Value>,
) -> Option<WorkspaceSnapshot> {
    WorkspaceSnapshot::parse(
        data?
            .get("_meta")?
            .get("vityo.dev")?
            .get("workspaceSnapshot")?,
    )
}

impl VityoWorkspaceChangeProposal {
    pub fn validate(&self) -> Result<(), ProposalValidationError> {
        if self.id.is_empty() || utf16_len(&self.id) > 256 {
            return Err(ProposalValidationError::InvalidProposalId);
        }
        if self.resources.is_empty() || self.resources.len() > MAX_PROPOSAL_RESOURCES {
            return Err(ProposalValidationError::InvalidResourceCount);
        }

        let mut resource_ids = HashSet::with_capacity(self.resources.len());
        let mut edit_count = 0usize;
        let mut replacement_len = 0usize;
        for resource in &self.resources {
            if resource.resource_id.is_empty() || utf16_len(&resource.resource_id) > 4096 {
                return Err(ProposalValidationError::InvalidResourceId);
            }
            if !resource_ids.insert(resource.resource_id.as_str()) {
                return Err(ProposalValidationError::DuplicateResource);
            }
            if resource.edits.is_empty() {
                return Err(ProposalValidationError::InvalidEditCount);
            }
            edit_count = edit_count.saturating_add(resource.edits.len());
            if edit_count > MAX_PROPOSAL_EDITS {
                return Err(ProposalValidationError::InvalidEditCount);
            }
            for edit in &resource.edits {
                if edit.end < edit.start {
                    return Err(ProposalValidationError::InvalidEditRange);
                }
                replacement_len = replacement_len.saturating_add(utf16_len(&edit.replacement));
                if replacement_len > MAX_REPLACEMENT_UTF16_UNITS {
                    return Err(ProposalValidationError::ReplacementTextTooLarge);
                }
            }
        }
        Ok(())
    }
}

fn utf16_len(value: &str) -> usize {
    value.encode_utf16().count()
}
