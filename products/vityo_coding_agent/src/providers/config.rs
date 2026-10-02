//! Non-secret provider configuration and native credential lookup.

use std::{fs, io::Read, path::Path};

use secrecy::SecretString;
use serde::Deserialize;

use super::{budget::UsageBudget, types::ModelProviderCapabilities};

const MAX_PROVIDER_CONFIG_BYTES: u64 = 64 * 1024;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProviderConfig {
    pub adapter: String,
    pub endpoint_base: String,
    pub model: String,
    pub capabilities: ProviderCapabilitiesConfig,
    pub limits: ProviderLimitsConfig,
    pub auth: ProviderAuthConfig,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProviderCapabilitiesConfig {
    pub context_tokens: u32,
    pub output_tokens: u32,
    pub supports_tools: bool,
    pub max_concurrency: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProviderLimitsConfig {
    pub max_total_tokens: u32,
    pub max_cost_micros: Option<u64>,
    #[serde(default = "default_output_bytes")]
    pub max_buffered_output_bytes: usize,
    #[serde(default = "default_argument_bytes")]
    pub max_tool_argument_bytes: usize,
    #[serde(default = "default_tool_buffer_bytes")]
    pub max_buffered_tool_bytes: usize,
    #[serde(default = "default_pending_tools")]
    pub max_pending_tool_calls: usize,
    #[serde(default = "default_tool_calls")]
    pub max_tool_calls: usize,
    #[serde(default = "default_schema_bytes")]
    pub max_tool_schema_bytes: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProviderAuthConfig {
    pub mode: ProviderAuthMode,
    pub secret_ref: Option<SecretReference>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderAuthMode {
    None,
    BearerToken,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SecretReference {
    pub service: String,
    pub account: String,
}

impl ProviderConfig {
    pub fn read(path: impl AsRef<Path>) -> Result<Self, ProviderConfigError> {
        let path = path.as_ref();
        if !path.is_absolute() {
            return Err(ProviderConfigError::InvalidConfiguration);
        }
        let file = fs::File::open(path).map_err(|_| ProviderConfigError::ConfigurationRequired)?;
        let metadata = file
            .metadata()
            .map_err(|_| ProviderConfigError::ConfigurationRequired)?;
        if !metadata.is_file() || metadata.len() > MAX_PROVIDER_CONFIG_BYTES {
            return Err(ProviderConfigError::InvalidConfiguration);
        }
        let mut content = Vec::with_capacity(metadata.len() as usize);
        file.take(MAX_PROVIDER_CONFIG_BYTES + 1)
            .read_to_end(&mut content)
            .map_err(|_| ProviderConfigError::ConfigurationRequired)?;
        if content.len() as u64 > MAX_PROVIDER_CONFIG_BYTES {
            return Err(ProviderConfigError::InvalidConfiguration);
        }
        Self::parse(&content)
    }

    pub fn parse(content: &[u8]) -> Result<Self, ProviderConfigError> {
        let config = serde_json::from_slice::<Self>(content)
            .map_err(|_| ProviderConfigError::InvalidConfiguration)?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), ProviderConfigError> {
        if self.adapter != "openai_compatible_chat"
            || self.model.trim().is_empty()
            || self.capabilities.context_tokens == 0
            || self.capabilities.output_tokens == 0
            || self.capabilities.max_concurrency == 0
            || self.limits.max_total_tokens == 0
            || self.limits.max_buffered_output_bytes == 0
            || self.limits.max_tool_argument_bytes == 0
            || self.limits.max_buffered_tool_bytes == 0
            || self.limits.max_pending_tool_calls == 0
            || self.limits.max_tool_calls == 0
            || self.limits.max_tool_schema_bytes == 0
            || self.capabilities.output_tokens > self.limits.max_total_tokens
        {
            return Err(ProviderConfigError::InvalidConfiguration);
        }
        let endpoint = reqwest::Url::parse(&self.endpoint_base)
            .map_err(|_| ProviderConfigError::InvalidConfiguration)?;
        if endpoint.scheme() != "https"
            || endpoint.host_str().is_none()
            || !endpoint.username().is_empty()
            || endpoint.password().is_some()
            || endpoint.query().is_some()
            || endpoint.fragment().is_some()
        {
            return Err(ProviderConfigError::InvalidConfiguration);
        }
        match self.auth.mode {
            ProviderAuthMode::None if self.auth.secret_ref.is_none() => Ok(()),
            ProviderAuthMode::BearerToken
                if self.auth.secret_ref.as_ref().is_some_and(|reference| {
                    !reference.service.trim().is_empty() && !reference.account.trim().is_empty()
                }) =>
            {
                Ok(())
            }
            _ => Err(ProviderConfigError::InvalidConfiguration),
        }
    }

    pub fn capabilities(&self) -> ModelProviderCapabilities {
        ModelProviderCapabilities {
            context_tokens: self.capabilities.context_tokens,
            output_tokens: self.capabilities.output_tokens,
            supports_tools: self.capabilities.supports_tools,
            max_concurrency: self.capabilities.max_concurrency,
        }
    }

    pub fn usage_budget(&self) -> UsageBudget {
        UsageBudget {
            max_context_tokens: self.capabilities.context_tokens,
            max_output_tokens: self.capabilities.output_tokens,
            max_total_tokens: self.limits.max_total_tokens,
            max_cost_micros: self.limits.max_cost_micros,
            max_buffered_output_bytes: self.limits.max_buffered_output_bytes,
            max_tool_argument_bytes: self.limits.max_tool_argument_bytes,
            max_buffered_tool_bytes: self.limits.max_buffered_tool_bytes,
            max_pending_tool_calls: self.limits.max_pending_tool_calls,
            max_tool_calls: self.limits.max_tool_calls,
            max_tool_schema_bytes: self.limits.max_tool_schema_bytes,
        }
    }
}

pub trait CredentialResolver: Send + Sync {
    fn resolve(&self, reference: &SecretReference) -> Result<SecretString, CredentialStoreError>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NativeCredentialResolver;

impl CredentialResolver for NativeCredentialResolver {
    fn resolve(&self, reference: &SecretReference) -> Result<SecretString, CredentialStoreError> {
        let entry = keyring::Entry::new(&reference.service, &reference.account)
            .map_err(|_| CredentialStoreError)?;
        entry
            .get_password()
            .map(SecretString::from)
            .map_err(|_| CredentialStoreError)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CredentialStoreError;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProviderConfigError {
    ConfigurationRequired,
    InvalidConfiguration,
    CredentialStoreUnavailable,
}

impl ProviderConfigError {
    pub const fn safe_message(self) -> &'static str {
        match self {
            Self::ConfigurationRequired => "provider configuration is required",
            Self::InvalidConfiguration => "provider configuration is invalid",
            Self::CredentialStoreUnavailable => "provider credentials are unavailable",
        }
    }
}

fn default_output_bytes() -> usize {
    256 * 1024
}

fn default_argument_bytes() -> usize {
    64 * 1024
}

fn default_tool_buffer_bytes() -> usize {
    256 * 1024
}

fn default_pending_tools() -> usize {
    16
}

fn default_tool_calls() -> usize {
    64
}

fn default_schema_bytes() -> usize {
    256 * 1024
}
