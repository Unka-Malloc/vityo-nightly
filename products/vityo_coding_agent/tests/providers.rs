use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use futures::stream;
use vityo_coding_agent::{
    cancellation::AgentCancellationToken,
    providers::{
        ModelEffectState, ModelEvent, ModelFinishReason, ModelMessage, ModelMessageRole,
        ModelProvider, ModelProviderCapabilities, ModelRequest, ModelRetrySafety, ModelUsage,
        ProviderEventStream, ProviderFailure, ProviderFailureKind, ProviderRequirements,
        ProviderRouter, ProviderStreamReducer, UsageBudget,
    },
};

#[test]
fn usage_budget_rejects_requests_before_provider_io() {
    let budget = UsageBudget {
        max_context_tokens: 8,
        max_output_tokens: Some(4),
        max_total_tokens: Some(10),
        max_cost_micros: Some(20),
        ..UsageBudget::default()
    };
    let mut request = request();
    request.estimated_context_tokens = 7;
    request.output_token_limit = Some(4);
    assert_eq!(
        budget.validate_request(&request).unwrap_err().kind,
        ProviderFailureKind::BudgetExceeded
    );
    assert_eq!(
        budget
            .validate_usage(ModelUsage {
                input_tokens: 7,
                output_tokens: 4,
                cost_micros: Some(1),
            })
            .unwrap_err()
            .kind,
        ProviderFailureKind::BudgetExceeded
    );
}

#[test]
fn usage_budget_allows_unbounded_output_only_within_the_context_window() {
    let budget = UsageBudget {
        max_context_tokens: 8,
        max_output_tokens: None,
        max_total_tokens: None,
        ..UsageBudget::default()
    };
    let mut request = request();
    request.estimated_context_tokens = 8;
    request.output_token_limit = None;
    assert!(budget.validate_request(&request).is_ok());
    assert!(
        budget
            .validate_usage(ModelUsage {
                input_tokens: 4,
                output_tokens: 4,
                cost_micros: None,
            })
            .is_ok()
    );
    assert_eq!(
        budget
            .validate_usage(ModelUsage {
                input_tokens: 8,
                output_tokens: 1,
                cost_micros: None,
            })
            .unwrap_err()
            .kind,
        ProviderFailureKind::BudgetExceeded,
        "unbounded output still fits only within the full context window"
    );

    request.output_token_limit = Some(u32::MAX);
    assert_eq!(
        budget.validate_request(&request).unwrap_err().kind,
        ProviderFailureKind::BudgetExceeded,
        "an explicit output limit reserves space inside the context window"
    );
    request.estimated_context_tokens = 9;
    request.output_token_limit = None;
    assert_eq!(
        budget.validate_request(&request).unwrap_err().kind,
        ProviderFailureKind::BudgetExceeded,
        "the required context ceiling must still be enforced"
    );
}

#[test]
fn stream_reducer_assembles_utf8_text_and_fragmented_tool_arguments() {
    let mut reducer = reducer();
    reducer.add(ModelEvent::TextDelta("hé".to_owned())).unwrap();
    reducer
        .add(ModelEvent::ToolCallDelta {
            index: 2,
            id: Some("call-2".to_owned()),
            name: Some("workspace.read".to_owned()),
            arguments_fragment: "{\"uri\":".to_owned(),
        })
        .unwrap();
    reducer
        .add(ModelEvent::ToolCallDelta {
            index: 2,
            id: None,
            name: None,
            arguments_fragment: "\"workspace://root/a.sty\"}".to_owned(),
        })
        .unwrap();
    reducer
        .add(ModelEvent::Usage(ModelUsage {
            input_tokens: 3,
            output_tokens: 1,
            cost_micros: None,
        }))
        .unwrap();
    reducer
        .add(ModelEvent::Completed(ModelFinishReason::ToolCalls))
        .unwrap();
    let result = reducer
        .finish("request-1".to_owned(), "fixture".to_owned())
        .unwrap();
    assert_eq!(result.text, "hé");
    assert_eq!(result.tool_calls.len(), 1);
    assert_eq!(result.tool_calls[0].name, "workspace.read");
    assert_eq!(
        result.tool_calls[0].arguments["uri"],
        "workspace://root/a.sty"
    );
}

#[test]
fn stream_reducer_rejects_malformed_tool_arguments_and_over_budget_output() {
    let mut malformed = reducer();
    malformed
        .add(ModelEvent::ToolCallDelta {
            index: 0,
            id: Some("call".to_owned()),
            name: Some("workspace.read".to_owned()),
            arguments_fragment: "{bad".to_owned(),
        })
        .unwrap();
    malformed
        .add(ModelEvent::Usage(ModelUsage::default()))
        .unwrap();
    malformed
        .add(ModelEvent::Completed(ModelFinishReason::ToolCalls))
        .unwrap();
    assert_eq!(
        malformed
            .finish("request".to_owned(), "fixture".to_owned())
            .unwrap_err()
            .kind,
        ProviderFailureKind::Protocol
    );

    let mut oversized = ProviderStreamReducer::new(2, 8, 8, 2, 2);
    let failure = oversized
        .add(ModelEvent::TextDelta("abc".to_owned()))
        .unwrap_err();
    assert_eq!(failure.kind, ProviderFailureKind::BudgetExceeded);
    assert_eq!(failure.effect_state, ModelEffectState::Uncertain);
}

#[test]
fn representative_stream_payload_respects_the_exact_memory_bound() {
    let bound = 64 * 1024;
    let mut reducer = ProviderStreamReducer::new(bound, 8, 8, 2, 2);
    reducer
        .add(ModelEvent::TextDelta("x".repeat(bound)))
        .unwrap();
    let failure = reducer
        .add(ModelEvent::TextDelta("y".to_owned()))
        .unwrap_err();
    assert_eq!(failure.kind, ProviderFailureKind::BudgetExceeded);
    assert_eq!(failure.effect_state, ModelEffectState::Uncertain);
}

#[test]
fn fallback_requires_replay_safety_and_a_known_empty_effect() {
    let retryable = ProviderFailure::new(
        ProviderFailureKind::RateLimited,
        "rate limited",
        true,
        ModelEffectState::None,
    );
    let mut read_only = request();
    assert!(retryable.permits_fallback(&read_only));
    read_only.retry_safety = ModelRetrySafety::UnsafeMutation;
    assert!(!retryable.permits_fallback(&read_only));
    read_only.retry_safety = ModelRetrySafety::IdempotentMutation;
    assert!(!retryable.permits_fallback(&read_only));
    read_only.idempotency_key = Some("request-key".to_owned());
    assert!(retryable.permits_fallback(&read_only));
    let uncertain = ProviderFailure {
        effect_state: ModelEffectState::Uncertain,
        ..retryable
    };
    assert!(!uncertain.permits_fallback(&read_only));
}

#[tokio::test]
async fn router_uses_an_ordered_compatible_fallback() {
    let first_calls = Arc::new(AtomicUsize::new(0));
    let second_calls = Arc::new(AtomicUsize::new(0));
    let first: Arc<dyn ModelProvider> = Arc::new(FixtureProvider {
        id: "rate-limited".to_owned(),
        calls: Arc::clone(&first_calls),
        events: vec![Err(ProviderFailure::new(
            ProviderFailureKind::RateLimited,
            "provider rate limit was reached",
            true,
            ModelEffectState::None,
        ))],
        capabilities: capabilities(),
    });
    let second: Arc<dyn ModelProvider> = Arc::new(FixtureProvider {
        id: "fallback".to_owned(),
        calls: Arc::clone(&second_calls),
        events: success_events(),
        capabilities: capabilities(),
    });
    let router = ProviderRouter::new(vec![first, second], UsageBudget::default()).unwrap();
    let receipt = router
        .generate(
            request(),
            ProviderRequirements::default(),
            AgentCancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(receipt.provider_id, "fallback");
    assert_eq!(receipt.text, "ready");
    assert_eq!(first_calls.load(Ordering::Relaxed), 1);
    assert_eq!(second_calls.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn routed_fallback_usage_uses_generation_budget_not_per_attempt_context() {
    let first_calls = Arc::new(AtomicUsize::new(0));
    let second_calls = Arc::new(AtomicUsize::new(0));
    let first: Arc<dyn ModelProvider> = Arc::new(FixtureProvider {
        id: "first-attempt".to_owned(),
        calls: Arc::clone(&first_calls),
        events: vec![Err(ProviderFailure::new(
            ProviderFailureKind::RateLimited,
            "provider rate limit was reached",
            true,
            ModelEffectState::None,
        )
        .with_usage(ModelUsage {
            input_tokens: 4,
            output_tokens: 4,
            cost_micros: None,
        }))],
        capabilities: capabilities(),
    });
    let second: Arc<dyn ModelProvider> = Arc::new(FixtureProvider {
        id: "second-attempt".to_owned(),
        calls: Arc::clone(&second_calls),
        events: success_events(),
        capabilities: capabilities(),
    });
    let router = ProviderRouter::new(
        vec![first, second],
        UsageBudget {
            max_context_tokens: 8,
            max_output_tokens: Some(4),
            max_total_tokens: Some(16),
            ..UsageBudget::default()
        },
    )
    .unwrap();
    let mut request = request();
    request.estimated_context_tokens = 4;
    request.output_token_limit = Some(4);
    let receipt = router
        .generate(
            request,
            ProviderRequirements::default(),
            AgentCancellationToken::new(),
        )
        .await
        .unwrap();

    assert_eq!(receipt.provider_id, "second-attempt");
    assert_eq!(receipt.usage.input_tokens, 5);
    assert_eq!(receipt.usage.output_tokens, 5);
    assert_eq!(first_calls.load(Ordering::Relaxed), 1);
    assert_eq!(second_calls.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn routed_fallback_stops_before_the_total_generation_budget_is_exceeded() {
    let first_calls = Arc::new(AtomicUsize::new(0));
    let second_calls = Arc::new(AtomicUsize::new(0));
    let first: Arc<dyn ModelProvider> = Arc::new(FixtureProvider {
        id: "first-attempt".to_owned(),
        calls: Arc::clone(&first_calls),
        events: vec![Err(ProviderFailure::new(
            ProviderFailureKind::RateLimited,
            "provider rate limit was reached",
            true,
            ModelEffectState::None,
        )
        .with_usage(ModelUsage {
            input_tokens: 6,
            output_tokens: 2,
            cost_micros: None,
        }))],
        capabilities: capabilities(),
    });
    let second: Arc<dyn ModelProvider> = Arc::new(FixtureProvider {
        id: "must-not-run".to_owned(),
        calls: Arc::clone(&second_calls),
        events: success_events(),
        capabilities: capabilities(),
    });
    let router = ProviderRouter::new(
        vec![first, second],
        UsageBudget {
            max_context_tokens: 8,
            max_output_tokens: Some(4),
            max_total_tokens: Some(12),
            ..UsageBudget::default()
        },
    )
    .unwrap();
    let mut request = request();
    request.estimated_context_tokens = 4;
    request.output_token_limit = Some(4);
    let failure = router
        .generate(
            request,
            ProviderRequirements::default(),
            AgentCancellationToken::new(),
        )
        .await
        .unwrap_err();

    assert_eq!(failure.kind, ProviderFailureKind::BudgetExceeded);
    assert_eq!(first_calls.load(Ordering::Relaxed), 1);
    assert_eq!(second_calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn router_requires_input_and_requested_output_to_fit_the_provider_window() {
    let calls = Arc::new(AtomicUsize::new(0));
    let provider: Arc<dyn ModelProvider> = Arc::new(FixtureProvider {
        id: "small-window".to_owned(),
        calls: Arc::clone(&calls),
        events: success_events(),
        capabilities: ModelProviderCapabilities {
            context_tokens: 8,
            output_tokens: Some(4),
            ..capabilities()
        },
    });
    let router = ProviderRouter::new(vec![provider], UsageBudget::default()).unwrap();
    let mut request = request();
    request.estimated_context_tokens = 5;
    request.output_token_limit = Some(4);
    let failure = router
        .generate(
            request,
            ProviderRequirements::default(),
            AgentCancellationToken::new(),
        )
        .await
        .unwrap_err();

    assert_eq!(failure.kind, ProviderFailureKind::CapabilityUnavailable);
    assert_eq!(calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn router_does_not_replay_after_an_uncertain_provider_effect() {
    let first_calls = Arc::new(AtomicUsize::new(0));
    let second_calls = Arc::new(AtomicUsize::new(0));
    let first: Arc<dyn ModelProvider> = Arc::new(FixtureProvider {
        id: "uncertain".to_owned(),
        calls: Arc::clone(&first_calls),
        events: vec![Err(ProviderFailure::new(
            ProviderFailureKind::TransientUnavailable,
            "provider transport is unavailable",
            true,
            ModelEffectState::Uncertain,
        ))],
        capabilities: capabilities(),
    });
    let second: Arc<dyn ModelProvider> = Arc::new(FixtureProvider {
        id: "must-not-run".to_owned(),
        calls: Arc::clone(&second_calls),
        events: success_events(),
        capabilities: capabilities(),
    });
    let router = ProviderRouter::new(vec![first, second], UsageBudget::default()).unwrap();
    let failure = router
        .generate(
            request(),
            ProviderRequirements::default(),
            AgentCancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert_eq!(failure.effect_state, ModelEffectState::Uncertain);
    assert_eq!(first_calls.load(Ordering::Relaxed), 1);
    assert_eq!(second_calls.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn router_accepts_a_provider_without_a_declared_output_ceiling() {
    let calls = Arc::new(AtomicUsize::new(0));
    let provider: Arc<dyn ModelProvider> = Arc::new(FixtureProvider {
        id: "unbounded".to_owned(),
        calls: Arc::clone(&calls),
        events: success_events(),
        capabilities: ModelProviderCapabilities {
            output_tokens: None,
            ..capabilities()
        },
    });
    let router = ProviderRouter::new(vec![provider], UsageBudget::default()).unwrap();
    let mut request = request();
    request.output_token_limit = Some(64);
    let receipt = router
        .generate(
            request,
            ProviderRequirements::default(),
            AgentCancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(receipt.provider_id, "unbounded");
    assert_eq!(receipt.text, "ready");
}

fn request() -> ModelRequest {
    ModelRequest {
        request_id: "request-1".to_owned(),
        messages: vec![ModelMessage::text(ModelMessageRole::User, "hello")],
        tools: Vec::new(),
        estimated_context_tokens: 1,
        output_token_limit: Some(8),
        retry_safety: ModelRetrySafety::ReadOnly,
        idempotency_key: None,
        deadline: None,
    }
}

fn reducer() -> ProviderStreamReducer {
    ProviderStreamReducer::new(16, 64, 64, 4, 8)
}

fn capabilities() -> ModelProviderCapabilities {
    ModelProviderCapabilities {
        context_tokens: 128,
        output_tokens: Some(32),
        supports_tools: true,
        max_concurrency: 2,
    }
}

fn success_events() -> Vec<Result<ModelEvent, ProviderFailure>> {
    vec![
        Ok(ModelEvent::TextDelta("ready".to_owned())),
        Ok(ModelEvent::Usage(ModelUsage {
            input_tokens: 1,
            output_tokens: 1,
            cost_micros: None,
        })),
        Ok(ModelEvent::Completed(ModelFinishReason::Completed)),
    ]
}

struct FixtureProvider {
    id: String,
    calls: Arc<AtomicUsize>,
    events: Vec<Result<ModelEvent, ProviderFailure>>,
    capabilities: ModelProviderCapabilities,
}

impl ModelProvider for FixtureProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn capabilities(&self) -> ModelProviderCapabilities {
        self.capabilities
    }

    fn stream(
        &self,
        _request: ModelRequest,
        _cancellation: AgentCancellationToken,
    ) -> ProviderEventStream {
        self.calls.fetch_add(1, Ordering::Relaxed);
        Box::pin(stream::iter(self.events.clone()))
    }
}
