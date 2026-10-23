//! Request and response budget checks for provider boundaries.

use crate::contracts::JsonObject;

use super::types::{
    ModelEffectState, ModelRequest, ModelUsage, ProviderFailure, ProviderFailureKind,
};

#[derive(Clone, Debug)]
pub struct UsageBudget {
    /// Full input-plus-output context window for each provider attempt.
    pub max_context_tokens: u32,
    /// `None` means no finite output ceiling.
    pub max_output_tokens: Option<u32>,
    /// Optional input-plus-output cap across one routed generation's permitted
    /// fallback attempts. `None` means no finite total-token ceiling.
    pub max_total_tokens: Option<u32>,
    pub max_cost_micros: Option<u64>,
    pub max_buffered_output_bytes: usize,
    pub max_tool_argument_bytes: usize,
    pub max_buffered_tool_bytes: usize,
    pub max_pending_tool_calls: usize,
    pub max_tool_calls: usize,
    pub max_tool_schema_bytes: usize,
}

impl Default for UsageBudget {
    fn default() -> Self {
        Self {
            max_context_tokens: 65_536,
            max_output_tokens: Some(8_192),
            max_total_tokens: Some(73_728),
            max_cost_micros: None,
            max_buffered_output_bytes: 256 * 1024,
            max_tool_argument_bytes: 64 * 1024,
            max_buffered_tool_bytes: 256 * 1024,
            max_pending_tool_calls: 16,
            max_tool_calls: 64,
            max_tool_schema_bytes: 256 * 1024,
        }
    }
}

impl UsageBudget {
    pub fn validate_request(&self, request: &ModelRequest) -> Result<(), ProviderFailure> {
        if request.request_id.trim().is_empty()
            || request.messages.is_empty()
            || request.output_token_limit == Some(0)
        {
            return Err(failure(
                ProviderFailureKind::InvalidRequest,
                "provider request shape is invalid",
            ));
        }
        let mut tool_names = std::collections::HashSet::with_capacity(request.tools.len());
        let mut schema_bytes = 0_usize;
        for tool in &request.tools {
            if !valid_tool_name(&tool.name)
                || tool.description.trim().is_empty()
                || tool.description.len() > 4096
                || !tool_names.insert(tool.name.as_str())
            {
                return Err(failure(
                    ProviderFailureKind::InvalidRequest,
                    "selected tool definitions are invalid or duplicated",
                ));
            }
            schema_bytes = schema_bytes.saturating_add(serialized_size(&tool.input_schema)?);
        }
        if request.tools.len() > self.max_tool_calls || schema_bytes > self.max_tool_schema_bytes {
            return Err(failure(
                ProviderFailureKind::BudgetExceeded,
                "selected tool schemas exceed the configured budget",
            ));
        }
        let output_exceeds = match (request.output_token_limit, self.max_output_tokens) {
            (Some(limit), Some(maximum)) => limit > maximum,
            _ => false,
        };
        let requested_context_tokens = request
            .estimated_context_tokens
            .checked_add(request.output_token_limit.unwrap_or(0));
        if requested_context_tokens.is_none_or(|total| total > self.max_context_tokens)
            || output_exceeds
            || self.request_total_exceeds(request, ModelUsage::default())
        {
            return Err(failure(
                ProviderFailureKind::BudgetExceeded,
                "request exceeds the configured token budget",
            ));
        }
        Ok(())
    }

    pub(crate) fn validate_fallback_request(
        &self,
        request: &ModelRequest,
        prior_usage: ModelUsage,
    ) -> Result<(), ProviderFailure> {
        if self.request_total_exceeds(request, prior_usage) {
            return Err(failure(
                ProviderFailureKind::BudgetExceeded,
                "request exceeds the configured token budget",
            ));
        }
        Ok(())
    }

    fn request_total_exceeds(&self, request: &ModelRequest, prior_usage: ModelUsage) -> bool {
        let Some(maximum) = self.max_total_tokens else {
            return false;
        };
        let prior_total = prior_usage
            .input_tokens
            .checked_add(prior_usage.output_tokens);
        let request_total = request
            .estimated_context_tokens
            .checked_add(request.output_token_limit.unwrap_or(0));
        prior_total
            .zip(request_total)
            .and_then(|(prior, requested)| prior.checked_add(requested))
            .is_none_or(|total| total > maximum)
    }

    pub(crate) fn validate_attempt_usage(&self, usage: ModelUsage) -> Result<(), ProviderFailure> {
        let context_tokens = usage.input_tokens.checked_add(usage.output_tokens);
        if context_tokens.is_none_or(|total| total > self.max_context_tokens)
            || self
                .max_output_tokens
                .is_some_and(|maximum| usage.output_tokens > maximum)
        {
            return Err(failure(
                ProviderFailureKind::BudgetExceeded,
                "provider usage exceeds the configured context window",
            ));
        }
        Ok(())
    }

    /// Checks the reported usage accumulated over provider fallback attempts.
    /// The context window and output cap remain per-attempt constraints.
    pub(crate) fn validate_routed_usage(&self, usage: ModelUsage) -> Result<(), ProviderFailure> {
        let total = usage.input_tokens.checked_add(usage.output_tokens);
        if self
            .max_total_tokens
            .is_some_and(|maximum| total.is_none_or(|total| total > maximum))
            || self
                .max_cost_micros
                .zip(usage.cost_micros)
                .is_some_and(|(maximum, cost)| cost > maximum)
        {
            return Err(failure(
                ProviderFailureKind::BudgetExceeded,
                "provider usage exceeds the configured generation budget",
            ));
        }
        Ok(())
    }

    pub fn validate_usage(&self, usage: ModelUsage) -> Result<(), ProviderFailure> {
        self.validate_attempt_usage(usage)?;
        self.validate_routed_usage(usage)
    }
}

fn valid_tool_name(name: &str) -> bool {
    !name.trim().is_empty() && name.len() <= 1024 && !name.chars().any(char::is_control)
}

fn serialized_size(value: &JsonObject) -> Result<usize, ProviderFailure> {
    serde_json::to_vec(value)
        .map(|bytes| bytes.len())
        .map_err(|_| {
            failure(
                ProviderFailureKind::InvalidRequest,
                "selected tool schema is not JSON serializable",
            )
        })
}

const fn failure(kind: ProviderFailureKind, message: &'static str) -> ProviderFailure {
    ProviderFailure::new(kind, message, false, ModelEffectState::None)
}
