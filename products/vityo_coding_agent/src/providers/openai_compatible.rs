//! OpenAI-compatible chat streaming adapter implemented with async-openai.

use std::{
    collections::{BTreeSet, HashMap, HashSet, VecDeque},
    time::Duration,
};

use async_openai::{
    Client,
    config::Config,
    error::OpenAIError,
    types::chat::{
        ChatCompletionMessageToolCall, ChatCompletionMessageToolCalls,
        ChatCompletionRequestAssistantMessage, ChatCompletionRequestMessage,
        ChatCompletionRequestSystemMessage, ChatCompletionRequestToolMessage,
        ChatCompletionRequestUserMessage, ChatCompletionStreamOptions, ChatCompletionTool,
        ChatCompletionTools, CreateChatCompletionRequest, CreateChatCompletionRequestArgs,
        FinishReason, FunctionCall, FunctionObject,
    },
};
use futures::{StreamExt, stream};
use reqwest::header::{AUTHORIZATION, HeaderMap, HeaderValue};
use secrecy::{ExposeSecret, SecretString};

use crate::cancellation::AgentCancellationToken;

use super::{
    budget::UsageBudget,
    config::{CredentialResolver, ProviderAuthMode, ProviderConfig, ProviderConfigError},
    types::{
        ModelEffectState, ModelEvent, ModelFinishReason, ModelMessage, ModelMessageRole,
        ModelProvider, ModelProviderCapabilities, ModelRequest, ModelUsage, ProviderEventStream,
        ProviderFailure, ProviderFailureKind,
    },
};

const PROVIDER_ID: &str = "openai-compatible-chat";

pub struct OpenAiCompatibleProvider {
    model: String,
    capabilities: ModelProviderCapabilities,
    budget: UsageBudget,
    http_client: reqwest::Client,
    config: ExplicitOpenAiConfig,
}

impl OpenAiCompatibleProvider {
    pub fn new(
        config: ProviderConfig,
        credentials: &dyn CredentialResolver,
    ) -> Result<Self, ProviderConfigError> {
        config.validate()?;
        let endpoint = reqwest::Url::parse(&config.endpoint_base)
            .map_err(|_| ProviderConfigError::InvalidConfiguration)?;
        Self::build(
            config,
            credentials,
            endpoint.as_str().trim_end_matches('/').to_owned(),
        )
    }

    fn build(
        config: ProviderConfig,
        credentials: &dyn CredentialResolver,
        api_base: String,
    ) -> Result<Self, ProviderConfigError> {
        let (api_key, authorization) = match config.auth.mode {
            ProviderAuthMode::None => (SecretString::from(String::new()), None),
            ProviderAuthMode::BearerToken => {
                let reference = config
                    .auth
                    .secret_ref
                    .as_ref()
                    .ok_or(ProviderConfigError::InvalidConfiguration)?;
                let value = credentials
                    .resolve(reference)
                    .map_err(|_| ProviderConfigError::CredentialStoreUnavailable)?;
                let mut authorization =
                    HeaderValue::from_str(&format!("Bearer {}", value.expose_secret()))
                        .map_err(|_| ProviderConfigError::CredentialStoreUnavailable)?;
                authorization.set_sensitive(true);
                (value, Some(authorization))
            }
        };
        let model = config.model.clone();
        let capabilities = config.capabilities();
        let budget = config.usage_budget();
        let http_client = reqwest::Client::builder()
            // Requests end only through task deadlines or explicit cancellation.
            .build()
            .map_err(|_| ProviderConfigError::InvalidConfiguration)?;
        Ok(Self {
            model,
            capabilities,
            budget,
            http_client,
            config: ExplicitOpenAiConfig {
                api_base,
                api_key,
                authorization,
                idempotency_key: None,
            },
        })
    }

    #[cfg(test)]
    pub(super) fn new_for_loopback_fixture(
        config: ProviderConfig,
        credentials: &dyn CredentialResolver,
        endpoint_base: &str,
    ) -> Result<Self, ProviderConfigError> {
        config.validate()?;
        let endpoint = reqwest::Url::parse(endpoint_base)
            .map_err(|_| ProviderConfigError::InvalidConfiguration)?;
        let loopback = endpoint.host_str().is_some_and(|host| {
            host == "localhost"
                || host
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|address| address.is_loopback())
        });
        if endpoint.scheme() != "http"
            || !loopback
            || !endpoint.username().is_empty()
            || endpoint.password().is_some()
            || endpoint.query().is_some()
            || endpoint.fragment().is_some()
        {
            return Err(ProviderConfigError::InvalidConfiguration);
        }
        Self::build(
            config,
            credentials,
            endpoint.as_str().trim_end_matches('/').to_owned(),
        )
    }

    pub fn model(&self) -> &str {
        &self.model
    }

    pub fn usage_budget(&self) -> &UsageBudget {
        &self.budget
    }

    fn make_request(
        &self,
        request: &ModelRequest,
    ) -> Result<(CreateChatCompletionRequest, HashMap<String, String>), ProviderFailure> {
        self.budget.validate_request(request)?;
        if !request.tools.is_empty() && !self.capabilities.supports_tools {
            return Err(ProviderFailure::new(
                ProviderFailureKind::CapabilityUnavailable,
                "configured provider does not support tool calls",
                false,
                ModelEffectState::None,
            ));
        }
        let output_exceeds_capability =
            match (request.output_token_limit, self.capabilities.output_tokens) {
                (Some(limit), Some(maximum)) => limit > maximum,
                _ => false,
            };
        let requested_context_tokens = request
            .estimated_context_tokens
            .checked_add(request.output_token_limit.unwrap_or(0));
        if requested_context_tokens.is_none_or(|total| total > self.capabilities.context_tokens)
            || output_exceeds_capability
        {
            return Err(ProviderFailure::new(
                ProviderFailureKind::BudgetExceeded,
                "request exceeds the configured provider capability",
                false,
                ModelEffectState::None,
            ));
        }
        if let Some(key) = request.idempotency_key.as_deref() {
            HeaderValue::from_str(key).map_err(|_| {
                ProviderFailure::new(
                    ProviderFailureKind::InvalidRequest,
                    "provider idempotency key is invalid",
                    false,
                    ModelEffectState::None,
                )
            })?;
        }
        let tool_names = request
            .tools
            .iter()
            .map(|tool| tool.name.clone())
            .chain(
                request
                    .messages
                    .iter()
                    .flat_map(|message| message.tool_calls.iter().map(|call| call.name.clone())),
            )
            .collect::<BTreeSet<_>>();
        let mut used_aliases = tool_names
            .iter()
            .filter(|name| openai_tool_name_is_valid(name))
            .cloned()
            .collect::<HashSet<_>>();
        let mut original_to_alias = HashMap::with_capacity(tool_names.len());
        let mut alias_to_original = HashMap::with_capacity(tool_names.len());
        let mut next_alias = 0_u64;
        for name in tool_names {
            let alias = if openai_tool_name_is_valid(&name) {
                name.clone()
            } else {
                loop {
                    let candidate = format!("vityo_tool_{next_alias:08}");
                    next_alias = next_alias.saturating_add(1);
                    if used_aliases.insert(candidate.clone()) {
                        break candidate;
                    }
                }
            };
            original_to_alias.insert(name.clone(), alias.clone());
            alias_to_original.insert(alias, name);
        }
        let messages = request
            .messages
            .iter()
            .map(|message| to_openai_message(message, &original_to_alias))
            .collect::<Result<Vec<_>, _>>()?;
        let tools = request
            .tools
            .iter()
            .map(|tool| {
                ChatCompletionTools::Function(ChatCompletionTool {
                    function: FunctionObject {
                        name: original_to_alias
                            .get(&tool.name)
                            .expect("tool names are aliased before encoding")
                            .clone(),
                        description: Some(tool.description.clone()),
                        parameters: Some(serde_json::Value::Object(tool.input_schema.clone())),
                        strict: None,
                    },
                })
            })
            .collect::<Vec<_>>();
        let mut builder = CreateChatCompletionRequestArgs::default();
        builder
            .model(self.model.clone())
            .messages(messages)
            .stream(true)
            .stream_options(ChatCompletionStreamOptions {
                include_usage: Some(true),
                include_obfuscation: Some(false),
            });
        if let Some(limit) = request.output_token_limit {
            builder.max_completion_tokens(limit);
        }
        if !tools.is_empty() {
            builder.tools(tools).parallel_tool_calls(false);
        }
        let body = builder.build().map_err(|_| {
            ProviderFailure::new(
                ProviderFailureKind::InvalidRequest,
                "provider request could not be encoded",
                false,
                ModelEffectState::None,
            )
        })?;
        Ok((body, alias_to_original))
    }
}

fn openai_tool_name_is_valid(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

impl ModelProvider for OpenAiCompatibleProvider {
    fn id(&self) -> &str {
        PROVIDER_ID
    }

    fn capabilities(&self) -> ModelProviderCapabilities {
        self.capabilities
    }

    fn stream(
        &self,
        request: ModelRequest,
        cancellation: AgentCancellationToken,
    ) -> ProviderEventStream {
        let result = self.make_request(&request);
        let mut config = self.config.clone();
        config.idempotency_key = request.idempotency_key.clone().and_then(|key| {
            HeaderValue::from_str(&key).ok().map(|mut value| {
                value.set_sensitive(false);
                value
            })
        });
        let client = Client::build(self.http_client.clone(), config);
        match result {
            Ok((request_body, tool_aliases)) => Box::pin(stream::unfold(
                OpenAiStreamState::new(client, request_body, request, cancellation, tool_aliases),
                |state| async move { state.next().await },
            )),
            Err(error) => Box::pin(stream::once(async move { Err(error) })),
        }
    }
}

#[allow(deprecated)]
fn to_openai_message(
    message: &ModelMessage,
    tool_aliases: &HashMap<String, String>,
) -> Result<ChatCompletionRequestMessage, ProviderFailure> {
    match message.role {
        ModelMessageRole::System
            if message.tool_calls.is_empty() && message.tool_call_id.is_none() =>
        {
            let content = message.content.clone().ok_or_else(invalid_history)?;
            Ok(ChatCompletionRequestSystemMessage::from(content).into())
        }
        ModelMessageRole::User
            if message.tool_calls.is_empty() && message.tool_call_id.is_none() =>
        {
            let content = message.content.clone().ok_or_else(invalid_history)?;
            Ok(ChatCompletionRequestUserMessage::from(content).into())
        }
        ModelMessageRole::Assistant if message.tool_call_id.is_none() => {
            let tool_calls = message
                .tool_calls
                .iter()
                .map(|call| {
                    let arguments =
                        serde_json::to_string(&call.arguments).map_err(|_| invalid_history())?;
                    if call.id.trim().is_empty() || call.name.trim().is_empty() {
                        return Err(invalid_history());
                    }
                    Ok(ChatCompletionMessageToolCalls::Function(
                        ChatCompletionMessageToolCall {
                            id: call.id.clone(),
                            function: FunctionCall {
                                name: tool_aliases
                                    .get(&call.name)
                                    .ok_or_else(invalid_history)?
                                    .clone(),
                                arguments,
                            },
                        },
                    ))
                })
                .collect::<Result<Vec<_>, ProviderFailure>>()?;
            if message.content.is_none() && tool_calls.is_empty() {
                return Err(invalid_history());
            }
            Ok(ChatCompletionRequestAssistantMessage {
                content: message.content.clone().map(Into::into),
                refusal: None,
                name: None,
                audio: None,
                tool_calls: (!tool_calls.is_empty()).then_some(tool_calls),
                function_call: None,
            }
            .into())
        }
        ModelMessageRole::Tool if message.tool_calls.is_empty() => {
            let (Some(tool_call_id), Some(content)) =
                (message.tool_call_id.clone(), message.content.clone())
            else {
                return Err(invalid_history());
            };
            if tool_call_id.trim().is_empty() {
                return Err(invalid_history());
            }
            Ok(ChatCompletionRequestToolMessage {
                content: content.into(),
                tool_call_id,
            }
            .into())
        }
        _ => Err(invalid_history()),
    }
}

fn invalid_history() -> ProviderFailure {
    ProviderFailure::new(
        ProviderFailureKind::InvalidRequest,
        "provider conversation history is invalid",
        false,
        ModelEffectState::None,
    )
}

#[derive(Clone)]
struct ExplicitOpenAiConfig {
    api_base: String,
    api_key: SecretString,
    authorization: Option<HeaderValue>,
    idempotency_key: Option<HeaderValue>,
}

impl Config for ExplicitOpenAiConfig {
    fn headers(&self) -> HeaderMap {
        let mut headers = HeaderMap::new();
        if let Some(authorization) = &self.authorization {
            headers.insert(AUTHORIZATION, authorization.clone());
        }
        if let Some(idempotency_key) = &self.idempotency_key {
            headers.insert("idempotency-key", idempotency_key.clone());
        }
        headers
    }

    fn url(&self, path: &str) -> String {
        format!(
            "{}/{path}",
            self.api_base,
            path = path.trim_start_matches('/')
        )
    }

    fn query(&self) -> Vec<(&str, &str)> {
        Vec::new()
    }

    fn api_base(&self) -> &str {
        &self.api_base
    }

    fn api_key(&self) -> &SecretString {
        &self.api_key
    }
}

struct OpenAiStreamState {
    client: Client<ExplicitOpenAiConfig>,
    request_body: Option<CreateChatCompletionRequest>,
    request: ModelRequest,
    cancellation: AgentCancellationToken,
    stream: Option<async_openai::types::chat::ChatCompletionResponseStream>,
    queued: VecDeque<Result<ModelEvent, ProviderFailure>>,
    finish_reason: Option<ModelFinishReason>,
    started: bool,
    ended: bool,
    usage_seen: bool,
    tool_aliases: HashMap<String, String>,
    wire_tool_names: HashMap<u32, WireToolName>,
}

#[derive(Default)]
struct WireToolName {
    encoded: String,
    mapped: Option<String>,
}

impl OpenAiStreamState {
    fn new(
        client: Client<ExplicitOpenAiConfig>,
        request_body: CreateChatCompletionRequest,
        request: ModelRequest,
        cancellation: AgentCancellationToken,
        tool_aliases: HashMap<String, String>,
    ) -> Self {
        Self {
            client,
            request_body: Some(request_body),
            request,
            cancellation,
            stream: None,
            queued: VecDeque::new(),
            finish_reason: None,
            started: false,
            ended: false,
            usage_seen: false,
            tool_aliases,
            wire_tool_names: HashMap::new(),
        }
    }

    async fn next(mut self) -> Option<(Result<ModelEvent, ProviderFailure>, Self)> {
        loop {
            if self.ended {
                return None;
            }
            if let Some(event) = self.queued.pop_front() {
                return Some((event, self));
            }
            if self.cancellation.is_cancelled() {
                let failure = self.cancel_failure();
                return Some((Err(failure), self));
            }
            if self
                .request
                .deadline
                .is_some_and(|deadline| deadline <= tokio::time::Instant::now())
            {
                let failure = self.deadline_failure();
                return Some((Err(failure), self));
            }
            if !self.started {
                self.started = true;
                let request = self
                    .request_body
                    .take()
                    .expect("stream request starts once");
                let client = self.client.clone();
                let stream_future = async move { client.chat().create_stream(request).await };
                let result = tokio::select! {
                    biased;
                    _ = self.cancellation.cancelled() => {
                        let failure = self.cancel_failure();
                        return Some((Err(failure), self));
                    }
                    _ = wait_until(self.request.deadline) => {
                        let failure = self.deadline_failure();
                        return Some((Err(failure), self));
                    }
                    result = stream_future => result,
                };
                match result {
                    Ok(stream) => self.stream = Some(stream),
                    Err(error) => {
                        let failure = map_openai_error(error);
                        self.ended = true;
                        return Some((Err(failure), self));
                    }
                }
                continue;
            }

            let Some(stream) = self.stream.as_mut() else {
                self.ended = true;
                return Some((Err(protocol_failure()), self));
            };
            let item = tokio::select! {
                biased;
                _ = self.cancellation.cancelled() => {
                    let failure = self.cancel_failure();
                    return Some((Err(failure), self));
                }
                _ = wait_until(self.request.deadline) => {
                    let failure = self.deadline_failure();
                    return Some((Err(failure), self));
                }
                item = stream.next() => item,
            };
            match item {
                Some(Ok(response)) => {
                    if let Some(usage) = response.usage {
                        self.usage_seen = true;
                        self.queued.push_back(Ok(ModelEvent::Usage(ModelUsage {
                            input_tokens: usage.prompt_tokens,
                            output_tokens: usage.completion_tokens,
                            cost_micros: None,
                        })));
                    }
                    if response.choices.len() > 1 {
                        self.ended = true;
                        return Some((Err(protocol_failure()), self));
                    }
                    for choice in response.choices {
                        if let Some(content) = choice.delta.content {
                            if !content.is_empty() {
                                self.queued.push_back(Ok(ModelEvent::TextDelta(content)));
                            }
                        }
                        for tool in choice.delta.tool_calls.unwrap_or_default() {
                            let function = tool.function;
                            let name = function
                                .as_ref()
                                .and_then(|call| call.name.as_deref())
                                .map(|fragment| self.map_tool_name_fragment(tool.index, fragment))
                                .transpose();
                            let name = match name {
                                Ok(name) => name.flatten(),
                                Err(failure) => {
                                    self.ended = true;
                                    return Some((Err(failure), self));
                                }
                            };
                            self.queued.push_back(Ok(ModelEvent::ToolCallDelta {
                                index: tool.index,
                                id: tool.id,
                                name,
                                arguments_fragment: function
                                    .and_then(|call| call.arguments)
                                    .unwrap_or_default(),
                            }));
                        }
                        if let Some(reason) = choice.finish_reason {
                            self.finish_reason = Some(map_finish_reason(reason));
                        }
                    }
                    if let Some(event) = self.queued.pop_front() {
                        return Some((event, self));
                    }
                }
                Some(Err(error)) => {
                    self.ended = true;
                    let mut failure = map_openai_error(error);
                    failure.effect_state = ModelEffectState::Uncertain;
                    if let Some(usage) = self.queued.iter().find_map(|event| match event {
                        Ok(ModelEvent::Usage(usage)) => Some(*usage),
                        _ => None,
                    }) {
                        failure.usage = Some(usage);
                    }
                    return Some((Err(failure), self));
                }
                None => {
                    self.ended = true;
                    let Some(reason) = self.finish_reason.take() else {
                        return Some((Err(protocol_failure()), self));
                    };
                    if self.usage_seen {
                        self.queued.push_back(Ok(ModelEvent::Completed(reason)));
                        if let Some(event) = self.queued.pop_front() {
                            return Some((event, self));
                        }
                    } else {
                        return Some((Err(protocol_failure()), self));
                    }
                }
            }
        }
    }

    fn cancel_failure(&mut self) -> ProviderFailure {
        self.ended = true;
        ProviderFailure::new(
            ProviderFailureKind::Cancelled,
            "provider request was cancelled",
            false,
            if self.started {
                ModelEffectState::Uncertain
            } else {
                ModelEffectState::None
            },
        )
    }

    fn deadline_failure(&mut self) -> ProviderFailure {
        self.ended = true;
        ProviderFailure::new(
            ProviderFailureKind::Deadline,
            "provider request deadline expired",
            false,
            if self.started {
                ModelEffectState::Uncertain
            } else {
                ModelEffectState::None
            },
        )
    }

    fn map_tool_name_fragment(
        &mut self,
        index: u32,
        fragment: &str,
    ) -> Result<Option<String>, ProviderFailure> {
        let state = self.wire_tool_names.entry(index).or_default();
        if let Some(mapped) = &state.mapped {
            if fragment == state.encoded {
                return Ok(Some(mapped.clone()));
            }
            return Err(protocol_failure());
        }
        state.encoded.push_str(fragment);
        if let Some(mapped) = self.tool_aliases.get(&state.encoded) {
            state.mapped = Some(mapped.clone());
            return Ok(state.mapped.clone());
        }
        if self
            .tool_aliases
            .keys()
            .any(|alias| alias.starts_with(&state.encoded))
        {
            return Ok(None);
        }
        Err(protocol_failure())
    }
}

async fn wait_until(deadline: Option<tokio::time::Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending::<()>().await,
    }
}

fn map_finish_reason(reason: FinishReason) -> ModelFinishReason {
    match reason {
        FinishReason::Stop | FinishReason::FunctionCall => ModelFinishReason::Completed,
        FinishReason::ToolCalls => ModelFinishReason::ToolCalls,
        FinishReason::Length => ModelFinishReason::Length,
        FinishReason::ContentFilter => ModelFinishReason::ContentFilter,
    }
}

fn map_openai_error(error: OpenAIError) -> ProviderFailure {
    match error {
        OpenAIError::ApiError(response) => match response.status_code.as_u16() {
            401 | 403 => ProviderFailure::new(
                ProviderFailureKind::Authentication,
                "provider authentication failed",
                false,
                ModelEffectState::None,
            ),
            429 => ProviderFailure::new(
                ProviderFailureKind::RateLimited,
                "provider rate limit was reached",
                true,
                ModelEffectState::None,
            )
            .with_retry_after(Duration::from_secs(1)),
            400 | 404 | 422 => ProviderFailure::new(
                ProviderFailureKind::InvalidRequest,
                "provider rejected the request",
                false,
                ModelEffectState::None,
            ),
            500..=599 => ProviderFailure::new(
                ProviderFailureKind::TransientUnavailable,
                "provider is temporarily unavailable",
                true,
                ModelEffectState::Uncertain,
            ),
            _ => ProviderFailure::new(
                ProviderFailureKind::TransientUnavailable,
                "provider request failed",
                false,
                ModelEffectState::Uncertain,
            ),
        },
        OpenAIError::Reqwest(_) => ProviderFailure::new(
            ProviderFailureKind::TransientUnavailable,
            "provider transport is unavailable",
            true,
            ModelEffectState::Uncertain,
        ),
        OpenAIError::InvalidArgument(_) => ProviderFailure::new(
            ProviderFailureKind::InvalidRequest,
            "provider request is invalid",
            false,
            ModelEffectState::None,
        ),
        OpenAIError::JSONDeserialize(_, _) | OpenAIError::StreamError(_) => protocol_failure(),
        #[allow(unreachable_patterns)]
        _ => protocol_failure(),
    }
}

fn protocol_failure() -> ProviderFailure {
    ProviderFailure::new(
        ProviderFailureKind::Protocol,
        "provider returned an invalid streaming response",
        false,
        ModelEffectState::Uncertain,
    )
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::mpsc::{self, Receiver},
        thread,
        time::Duration,
    };

    use futures::StreamExt;
    use serde_json::{Value, json};

    use super::*;
    use crate::providers::{ModelToolCall, ModelToolDefinition, ProviderStreamReducer};

    struct SyntheticCredentials;

    impl CredentialResolver for SyntheticCredentials {
        fn resolve(
            &self,
            _reference: &super::super::config::SecretReference,
        ) -> Result<SecretString, super::super::config::CredentialStoreError> {
            Ok(SecretString::from("synthetic-token-only"))
        }
    }

    struct UnavailableCredentials;

    impl CredentialResolver for UnavailableCredentials {
        fn resolve(
            &self,
            _reference: &super::super::config::SecretReference,
        ) -> Result<SecretString, super::super::config::CredentialStoreError> {
            Err(super::super::config::CredentialStoreError)
        }
    }

    #[tokio::test]
    async fn actual_sdk_streams_text_split_tool_calls_and_usage() {
        let body = concat!(
            "data: {\"id\":\"fixture\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"fixture-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Found it. \"},\"finish_reason\":null}]}\n\n",
            "data: {\"id\":\"fixture\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"fixture-model\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-next\",\"type\":\"function\",\"function\":{\"name\":\"vityo_tool_\",\"arguments\":\"{\\\"path\\\":\\\"\"}}]},\"finish_reason\":null}]}\n\n",
            "data: {\"id\":\"fixture\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"fixture-model\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"00000000\",\"arguments\":\"src/main.sty\\\"}\"}}]},\"finish_reason\":null}]}\n\n",
            "data: {\"id\":\"fixture\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"fixture-model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
            "data: {\"id\":\"fixture\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"fixture-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3,\"total_tokens\":10}}\n\n",
            "data: [DONE]\n\n"
        );
        let (endpoint, received, server) = fixture(200, body, None);
        let provider = crate::providers::build_provider_for_test(
            config(ProviderAuthMode::None),
            &SyntheticCredentials,
            &endpoint,
        )
        .unwrap();
        let mut request = request();
        request.messages.extend([
            ModelMessage::assistant_tool_calls(vec![ModelToolCall {
                id: "call-previous".to_owned(),
                name: "mcp/server/source.read".to_owned(),
                arguments: json!({"path":"src/old.sty"}).as_object().unwrap().clone(),
            }]),
            ModelMessage::tool_result("call-previous", "previous source contents"),
        ]);
        request.tools.push(ModelToolDefinition {
            name: "mcp/server/source.read".to_owned(),
            description: "Read a workspace file".to_owned(),
            input_schema: json!({"type":"object","properties":{"path":{"type":"string"}}})
                .as_object()
                .unwrap()
                .clone(),
        });

        let mut reducer = ProviderStreamReducer::new(1024, 4096, 4096, 8, 16);
        let mut events = provider.stream(request, AgentCancellationToken::new());
        while let Some(event) = events.next().await {
            reducer.add(event.unwrap()).unwrap();
        }
        let receipt = reducer
            .finish("fixture-request".to_owned(), provider.id().to_owned())
            .unwrap();
        assert_eq!(receipt.text, "Found it. ");
        assert_eq!(receipt.tool_calls.len(), 1);
        assert_eq!(receipt.tool_calls[0].id, "call-next");
        assert_eq!(receipt.tool_calls[0].name, "mcp/server/source.read");
        assert_eq!(receipt.tool_calls[0].arguments["path"], "src/main.sty");
        assert_eq!(receipt.usage.input_tokens, 7);
        assert_eq!(receipt.usage.output_tokens, 3);
        assert_eq!(receipt.finish_reason, ModelFinishReason::ToolCalls);

        let received = await_request(received).await;
        server.join().unwrap();
        assert!(header_value(&received, "authorization").is_none());
        let request_body = request_body(&received);
        let messages = request_body["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[1]["tool_calls"][0]["id"], "call-previous");
        assert_eq!(
            messages[1]["tool_calls"][0]["function"]["name"],
            "vityo_tool_00000000"
        );
        assert_eq!(
            messages[1]["tool_calls"][0]["function"]["arguments"],
            "{\"path\":\"src/old.sty\"}"
        );
        assert_eq!(messages[2]["tool_call_id"], "call-previous");
        assert_eq!(messages[2]["content"], "previous source contents");
        assert_eq!(
            request_body["tools"][0]["function"]["name"],
            "vityo_tool_00000000"
        );
    }

    #[tokio::test]
    async fn authentication_failures_are_safe_and_synthetic_credentials_stay_in_header() {
        let body = "{\"error\":{\"message\":\"synthetic-token-only https://private-endpoint.invalid/prompt\",\"type\":\"authentication_error\",\"param\":null,\"code\":null}}";
        let (endpoint, received, server) = fixture(401, body, None);
        let provider = OpenAiCompatibleProvider::new_for_loopback_fixture(
            config(ProviderAuthMode::BearerToken),
            &SyntheticCredentials,
            &endpoint,
        )
        .unwrap();
        let failure = provider
            .stream(request(), AgentCancellationToken::new())
            .next()
            .await
            .unwrap()
            .unwrap_err();
        assert_eq!(failure.kind, ProviderFailureKind::Authentication);
        assert_eq!(failure.message, "provider authentication failed");
        assert!(!failure.message.contains("synthetic-token-only"));
        assert!(!failure.message.contains("private-endpoint"));
        let received = await_request(received).await;
        server.join().unwrap();
        assert_eq!(
            header_value(&received, "authorization").as_deref(),
            Some("Bearer synthetic-token-only")
        );
        assert!(!received.contains("private-endpoint.invalid/prompt"));
    }

    #[tokio::test]
    async fn malformed_and_transport_stream_failures_are_safe_and_uncertain() {
        let (endpoint, _received, server) = fixture(
            200,
            "data: {malformed-provider-payload}\n\n".to_owned(),
            None,
        );
        let provider = OpenAiCompatibleProvider::new_for_loopback_fixture(
            config(ProviderAuthMode::None),
            &SyntheticCredentials,
            &endpoint,
        )
        .unwrap();
        let failure = provider
            .stream(request(), AgentCancellationToken::new())
            .next()
            .await
            .unwrap()
            .unwrap_err();
        assert_eq!(failure.kind, ProviderFailureKind::Protocol);
        assert_eq!(failure.effect_state, ModelEffectState::Uncertain);
        assert_eq!(
            failure.message,
            "provider returned an invalid streaming response"
        );
        server.join().unwrap();

        let (endpoint, _received, server) = fixture(
            503,
            "{\"error\":\"synthetic-token-only secret prompt\"}".to_owned(),
            None,
        );
        let provider = OpenAiCompatibleProvider::new_for_loopback_fixture(
            config(ProviderAuthMode::None),
            &SyntheticCredentials,
            &endpoint,
        )
        .unwrap();
        let failure = provider
            .stream(request(), AgentCancellationToken::new())
            .next()
            .await
            .unwrap()
            .unwrap_err();
        assert_eq!(failure.kind, ProviderFailureKind::TransientUnavailable);
        assert_eq!(failure.effect_state, ModelEffectState::Uncertain);
        assert!(!failure.message.contains("synthetic-token-only"));
        server.join().unwrap();
    }

    #[tokio::test]
    async fn cancellation_before_request_does_not_open_a_transport() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/v1", listener.local_addr().unwrap());
        drop(listener);
        let provider = OpenAiCompatibleProvider::new_for_loopback_fixture(
            config(ProviderAuthMode::None),
            &SyntheticCredentials,
            &endpoint,
        )
        .unwrap();
        let cancellation = AgentCancellationToken::new();
        cancellation.cancel();
        let failure = provider
            .stream(request(), cancellation)
            .next()
            .await
            .unwrap()
            .unwrap_err();
        assert_eq!(failure.kind, ProviderFailureKind::Cancelled);
        assert_eq!(failure.effect_state, ModelEffectState::None);
    }

    #[tokio::test]
    async fn cancellation_after_request_start_has_uncertain_effect() {
        let (release, wait_for_release) = mpsc::channel();
        let (endpoint, received, server) =
            fixture(200, "data: [DONE]\n\n".to_owned(), Some(wait_for_release));
        let provider = OpenAiCompatibleProvider::new_for_loopback_fixture(
            config(ProviderAuthMode::None),
            &SyntheticCredentials,
            &endpoint,
        )
        .unwrap();
        let cancellation = AgentCancellationToken::new();
        let mut events = provider.stream(request(), cancellation.clone());
        let pending = tokio::spawn(async move { events.next().await });
        let _request = await_request(received).await;
        cancellation.cancel();
        let failure = pending.await.unwrap().unwrap().unwrap_err();
        release.send(()).unwrap();
        server.join().unwrap();
        assert_eq!(failure.kind, ProviderFailureKind::Cancelled);
        assert_eq!(failure.effect_state, ModelEffectState::Uncertain);
    }

    #[tokio::test]
    async fn unbounded_output_omits_max_completion_tokens_and_accepts_unbounded_providers() {
        const BODY: &str = concat!(
            "data: {\"id\":\"fixture\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"fixture-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"done\"},\"finish_reason\":null}]}\n\n",
            "data: {\"id\":\"fixture\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"fixture-model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
            "data: {\"id\":\"fixture\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"fixture-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2,\"total_tokens\":6}}\n\n",
            "data: [DONE]\n\n"
        );

        let (endpoint, received, server) = fixture(200, BODY, None);
        let provider = OpenAiCompatibleProvider::new_for_loopback_fixture(
            unrestricted_config(),
            &SyntheticCredentials,
            &endpoint,
        )
        .unwrap();
        let mut unbounded = request();
        unbounded.output_token_limit = None;
        drain(provider.stream(unbounded, AgentCancellationToken::new())).await;
        let unbounded_body = request_body(&await_request(received).await);
        server.join().unwrap();
        assert!(unbounded_body.get("max_completion_tokens").is_none());

        let (endpoint, received, server) = fixture(200, BODY, None);
        let provider = OpenAiCompatibleProvider::new_for_loopback_fixture(
            unrestricted_config(),
            &SyntheticCredentials,
            &endpoint,
        )
        .unwrap();
        let mut explicit = request();
        explicit.output_token_limit = Some(64);
        drain(provider.stream(explicit, AgentCancellationToken::new())).await;
        let explicit_body = request_body(&await_request(received).await);
        server.join().unwrap();
        assert_eq!(explicit_body["max_completion_tokens"], json!(64));
    }

    #[tokio::test]
    async fn explicit_output_limit_above_a_declared_ceiling_is_rejected() {
        let provider = OpenAiCompatibleProvider::new_for_loopback_fixture(
            config(ProviderAuthMode::None),
            &SyntheticCredentials,
            "http://127.0.0.1:9/v1",
        )
        .unwrap();
        let mut request = request();
        request.output_token_limit = Some(64);
        let failure = provider
            .stream(request, AgentCancellationToken::new())
            .next()
            .await
            .unwrap()
            .unwrap_err();
        assert_eq!(failure.kind, ProviderFailureKind::BudgetExceeded);
    }

    #[tokio::test]
    async fn input_and_explicit_output_must_fit_the_full_context_window() {
        let provider = OpenAiCompatibleProvider::new_for_loopback_fixture(
            unrestricted_config(),
            &SyntheticCredentials,
            "http://127.0.0.1:9/v1",
        )
        .unwrap();
        let mut request = request();
        request.estimated_context_tokens = 97;
        request.output_token_limit = Some(32);
        let failure = provider
            .stream(request, AgentCancellationToken::new())
            .next()
            .await
            .unwrap()
            .unwrap_err();

        assert_eq!(failure.kind, ProviderFailureKind::BudgetExceeded);
    }

    #[test]
    fn local_transport_seam_rejects_non_loopback_and_production_config_rejects_http() {
        let credentials = SyntheticCredentials;
        assert!(matches!(
            ProviderConfig::parse(&config_json(
                ProviderAuthMode::None,
                "http://example.invalid/v1"
            )),
            Err(ProviderConfigError::InvalidConfiguration)
        ));
        let config = config(ProviderAuthMode::None);
        assert!(matches!(
            OpenAiCompatibleProvider::new_for_loopback_fixture(
                config,
                &credentials,
                "http://example.invalid/v1"
            ),
            Err(ProviderConfigError::InvalidConfiguration)
        ));
    }

    #[test]
    fn injected_credential_store_errors_are_typed_and_static() {
        let result = OpenAiCompatibleProvider::new_for_loopback_fixture(
            config(ProviderAuthMode::BearerToken),
            &UnavailableCredentials,
            "http://127.0.0.1:12345/v1",
        );
        let Err(failure) = result else {
            panic!("synthetic credential-store failure must reject construction");
        };
        assert_eq!(failure, ProviderConfigError::CredentialStoreUnavailable);
        assert_eq!(
            failure.safe_message(),
            "provider credentials are unavailable"
        );
    }

    fn config(mode: ProviderAuthMode) -> ProviderConfig {
        ProviderConfig::parse(&config_json(mode, "https://provider.invalid/v1")).unwrap()
    }

    fn unrestricted_config() -> ProviderConfig {
        ProviderConfig::parse(
            &json!({
                "adapter":"openai_compatible_chat",
                "endpointBase":"https://provider.invalid/v1",
                "model":"fixture-model",
                "capabilities":{
                    "contextTokens":128,
                    "supportsTools":true,
                    "maxConcurrency":2
                },
                "limits":{},
                "auth":{"mode":"none"}
            })
            .to_string()
            .into_bytes(),
        )
        .unwrap()
    }

    async fn drain(mut events: crate::providers::ProviderEventStream) {
        while let Some(event) = events.next().await {
            event.unwrap();
        }
    }

    fn config_json(mode: ProviderAuthMode, endpoint_base: &str) -> Vec<u8> {
        let auth = match mode {
            ProviderAuthMode::None => json!({"mode":"none"}),
            ProviderAuthMode::BearerToken => json!({
                "mode":"bearer_token",
                "secretRef":{"service":"vityo-test-provider","account":"synthetic-account"}
            }),
        };
        json!({
            "adapter":"openai_compatible_chat",
            "endpointBase":endpoint_base,
            "model":"fixture-model",
            "capabilities":{
                "contextTokens":128,
                "outputTokens":32,
                "supportsTools":true,
                "maxConcurrency":2
            },
            "limits":{"maxTotalTokens":128},
            "auth":auth
        })
        .to_string()
        .into_bytes()
    }

    fn request() -> ModelRequest {
        ModelRequest {
            request_id: "fixture-request".to_owned(),
            messages: vec![ModelMessage::text(ModelMessageRole::User, "read this file")],
            tools: Vec::new(),
            estimated_context_tokens: 4,
            output_token_limit: Some(16),
            retry_safety: super::super::types::ModelRetrySafety::ReadOnly,
            idempotency_key: None,
            deadline: None,
        }
    }

    fn fixture(
        status: u16,
        body: impl Into<String>,
        gated: Option<Receiver<()>>,
    ) -> (String, Receiver<String>, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/v1", listener.local_addr().unwrap());
        let (request_tx, request_rx) = mpsc::channel();
        let body = body.into();
        let server = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let request = read_request(&mut socket);
            request_tx.send(request).unwrap();
            if let Some(gate) = gated {
                let _ = gate.recv_timeout(Duration::from_secs(5));
            }
            let reason = match status {
                200 => "OK",
                401 => "Unauthorized",
                503 => "Service Unavailable",
                _ => "Fixture Response",
            };
            let content_type = if status == 200 {
                "text/event-stream"
            } else {
                "application/json"
            };
            let header = format!(
                "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = socket.write_all(header.as_bytes());
            let _ = socket.write_all(body.as_bytes());
            let _ = socket.flush();
        });
        (endpoint, request_rx, server)
    }

    fn read_request(socket: &mut impl Read) -> String {
        let mut header = Vec::new();
        let mut byte = [0_u8; 1];
        while !header.ends_with(b"\r\n\r\n") {
            socket.read_exact(&mut byte).unwrap();
            header.push(byte[0]);
        }
        let header_text = String::from_utf8(header.clone()).unwrap();
        let content_length = header_text
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            })
            .unwrap_or(0);
        let mut request = header;
        let body_start = request.len();
        request.resize(body_start + content_length, 0);
        socket.read_exact(&mut request[body_start..]).unwrap();
        String::from_utf8(request).unwrap()
    }

    async fn await_request(receiver: Receiver<String>) -> String {
        tokio::task::spawn_blocking(move || receiver.recv().unwrap())
            .await
            .unwrap()
    }

    fn header_value(request: &str, name: &str) -> Option<String> {
        request
            .split("\r\n\r\n")
            .next()?
            .lines()
            .skip(1)
            .find_map(|line| {
                let (key, value) = line.split_once(':')?;
                key.eq_ignore_ascii_case(name)
                    .then(|| value.trim().to_owned())
            })
    }

    fn request_body(request: &str) -> Value {
        let body = request.split_once("\r\n\r\n").unwrap().1;
        serde_json::from_str(body).unwrap()
    }
}
