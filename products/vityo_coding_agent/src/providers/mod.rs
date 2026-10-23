//! Model provider configuration, OpenAI-compatible streaming, and routing.

mod budget;
mod config;
mod openai_compatible;
mod reducer;
mod router;
mod types;

pub use budget::UsageBudget;
pub use config::{
    CredentialResolver, NativeCredentialResolver, ProviderAuthConfig, ProviderAuthMode,
    ProviderCapabilitiesConfig, ProviderConfig, ProviderConfigError, ProviderLimitsConfig,
    SecretReference,
};
pub use openai_compatible::OpenAiCompatibleProvider;
pub use reducer::ProviderStreamReducer;
pub use router::ProviderRouter;
pub use types::{
    ModelEffectState, ModelEvent, ModelExecutionReceipt, ModelFinishReason, ModelMessage,
    ModelMessageRole, ModelProvider, ModelProviderCapabilities, ModelRequest, ModelRetrySafety,
    ModelToolCall, ModelToolDefinition, ModelUsage, ProviderEventStream, ProviderFailure,
    ProviderFailureKind, ProviderRequirements,
};

use std::sync::Arc;

pub fn build_provider(
    config: ProviderConfig,
    credentials: &dyn CredentialResolver,
) -> Result<Arc<dyn ModelProvider>, ProviderConfigError> {
    Ok(Arc::new(OpenAiCompatibleProvider::new(
        config,
        credentials,
    )?))
}

#[cfg(test)]
pub(crate) fn build_provider_for_test(
    config: ProviderConfig,
    credentials: &dyn CredentialResolver,
    endpoint_base: &str,
) -> Result<Arc<dyn ModelProvider>, ProviderConfigError> {
    Ok(Arc::new(
        OpenAiCompatibleProvider::new_for_loopback_fixture(config, credentials, endpoint_base)?,
    ))
}

pub fn load_provider_config(
    path: impl AsRef<std::path::Path>,
) -> Result<ProviderConfig, ProviderConfigError> {
    ProviderConfig::read(path)
}
