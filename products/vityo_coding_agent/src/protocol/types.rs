//! Typed wire contract for the existing Vityo ACP extension.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const ACP_PROTOCOL_VERSION: u8 = 1;
pub const VITYO_EXTENSION_PREFIX: &str = "_vityo.dev/";
pub const VITYO_WORKSPACE_CHANGE_PROPOSAL: &str = "_vityo.dev/workspace-change-proposal";
pub const ACP_MAX_MESSAGE_BYTES: usize = 1024 * 1024;
pub const MAX_PROPOSAL_RESOURCES: usize = 64;
pub const MAX_PROPOSAL_EDITS: usize = 500;
pub const MAX_REPLACEMENT_UTF16_UNITS: usize = 200_000;

/// Params for the capability-gated workspace proposal notification.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VityoWorkspaceChangeProposalParams {
    pub session_id: String,
    pub proposal: VityoWorkspaceChangeProposal,
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

impl VityoWorkspaceChangeProposalParams {
    pub fn validate(&self) -> Result<(), ProposalValidationError> {
        if self.session_id.is_empty() || utf16_len(&self.session_id) > 256 {
            return Err(ProposalValidationError::InvalidProposalId);
        }
        self.proposal.validate()
    }
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
