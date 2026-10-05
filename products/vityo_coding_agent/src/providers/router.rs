//! Capability-aware provider routing, bounded usage, and safe failover.

use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::Duration,
};

use futures::StreamExt;
use tokio::{
    sync::{Mutex, OwnedSemaphorePermit, Semaphore},
    time::Instant,
};

use crate::cancellation::AgentCancellationToken;

use super::{
    budget::UsageBudget,
    reducer::ProviderStreamReducer,
    types::{
        ModelEffectState, ModelExecutionReceipt, ModelProvider, ModelRequest, ModelUsage,
        ProviderFailure, ProviderFailureKind, ProviderRequirements,
    },
};

pub struct ProviderRouter {
    providers: Vec<ProviderSlot>,
    budget: UsageBudget,
    unavailable_until: Mutex<HashMap<String, Instant>>,
}

struct ProviderSlot {
    provider: Arc<dyn ModelProvider>,
    permits: Arc<Semaphore>,
}

struct SelectedProvider {
    index: usize,
    _permit: OwnedSemaphorePermit,
}

impl ProviderRouter {
    pub fn new(
        providers: Vec<Arc<dyn ModelProvider>>,
        budget: UsageBudget,
    ) -> Result<Self, ProviderFailure> {
        if providers.is_empty() {
            return Err(route_unavailable("no provider is configured"));
        }
        let mut ids = HashSet::with_capacity(providers.len());
        let mut slots = Vec::with_capacity(providers.len());
        for provider in providers {
            let id = provider.id();
            let capabilities = provider.capabilities();
            if id.trim().is_empty()
                || !ids.insert(id.to_owned())
                || capabilities.max_concurrency == 0
            {
                return Err(ProviderFailure::new(
                    ProviderFailureKind::InvalidRequest,
                    "provider configuration is invalid",
                    false,
                    ModelEffectState::None,
                ));
            }
            slots.push(ProviderSlot {
                provider,
                permits: Arc::new(Semaphore::new(capabilities.max_concurrency)),
            });
        }
        Ok(Self {
            providers: slots,
            budget,
            unavailable_until: Mutex::new(HashMap::new()),
        })
    }

    pub async fn generate(
        &self,
        request: ModelRequest,
        requirements: ProviderRequirements,
        cancellation: AgentCancellationToken,
    ) -> Result<ModelExecutionReceipt, ProviderFailure> {
        self.budget.validate_request(&request)?;
        if requirements.requires_tools && request.tools.is_empty() {
            return Err(ProviderFailure::new(
                ProviderFailureKind::InvalidRequest,
                "a tool-capable request must include selected tool schemas",
                false,
                ModelEffectState::None,
            ));
        }
        let requirements = ProviderRequirements {
            requires_tools: requirements.requires_tools || !request.tools.is_empty(),
            ..requirements
        };
        let mut attempted = HashSet::with_capacity(self.providers.len());
        let mut accrued_usage = ModelUsage::default();
        let mut last_failure = None;

        while attempted.len() < self.providers.len() {
            check_cancelled_or_deadline(&request, &cancellation)?;
            let selected = match self
                .select(&request, requirements, &attempted, &cancellation)
                .await
            {
                Ok(selected) => selected,
                Err(failure) => return Err(last_failure.unwrap_or(failure)),
            };
            attempted.insert(selected.index);
            let slot = &self.providers[selected.index];
            let provider = Arc::clone(&slot.provider);
            let mut reducer = ProviderStreamReducer::new(
                self.budget.max_buffered_output_bytes,
                self.budget.max_tool_argument_bytes,
                self.budget.max_buffered_tool_bytes,
                self.budget.max_pending_tool_calls,
                self.budget.max_tool_calls,
            );
            let mut stream = provider.stream(request.clone(), cancellation.clone());
            let result = async {
                while let Some(event) = stream.next().await {
                    reducer.add(event?)?;
                }
                reducer.finish(request.request_id.clone(), provider.id().to_owned())
            }
            .await;

            match result {
                Ok(mut receipt) => {
                    self.budget.validate_attempt_usage(receipt.usage)?;
                    accrued_usage = add_usage(accrued_usage, receipt.usage)?;
                    self.budget.validate_routed_usage(accrued_usage)?;
                    receipt.usage = accrued_usage;
                    return Ok(receipt);
                }
                Err(mut failure) => {
                    if failure.usage.is_none() {
                        failure.usage = reducer.observed_usage();
                    }
                    if let Some(usage) = failure.usage {
                        self.budget.validate_attempt_usage(usage)?;
                        accrued_usage = add_usage(accrued_usage, usage)?;
                        self.budget.validate_routed_usage(accrued_usage)?;
                    }
                    self.mark_unavailable(provider.id(), &failure).await;
                    if !failure.permits_fallback(&request) {
                        return Err(failure);
                    }
                    self.budget
                        .validate_fallback_request(&request, accrued_usage)?;
                    last_failure = Some(failure);
                }
            }
            drop(selected._permit);
        }
        Err(last_failure.unwrap_or_else(|| route_unavailable("no provider route is available")))
    }

    async fn select(
        &self,
        request: &ModelRequest,
        requirements: ProviderRequirements,
        attempted: &HashSet<usize>,
        cancellation: &AgentCancellationToken,
    ) -> Result<SelectedProvider, ProviderFailure> {
        let unavailable = self.unavailable_until.lock().await;
        let now = Instant::now();
        let mut saturated = None;
        let mut has_compatible = false;
        let requested_context_tokens = request
            .estimated_context_tokens
            .checked_add(request.output_token_limit.unwrap_or(0));
        for (index, slot) in self.providers.iter().enumerate() {
            if attempted.contains(&index) {
                continue;
            }
            let id = slot.provider.id();
            if unavailable.get(id).is_some_and(|until| *until > now) {
                continue;
            }
            let capabilities = slot.provider.capabilities();
            let output_compatible = match (capabilities.output_tokens, request.output_token_limit) {
                (Some(available), Some(required)) => available >= required,
                _ => true,
            };
            if !requirements.accepts(capabilities)
                || requested_context_tokens
                    .is_none_or(|tokens| capabilities.context_tokens < tokens)
                || !output_compatible
            {
                continue;
            }
            has_compatible = true;
            if let Ok(permit) = Arc::clone(&slot.permits).try_acquire_owned() {
                return Ok(SelectedProvider {
                    index,
                    _permit: permit,
                });
            }
            saturated.get_or_insert(index);
        }
        drop(unavailable);
        let Some(index) = saturated.filter(|_| has_compatible) else {
            return Err(route_unavailable(
                "no healthy provider satisfies the request capabilities",
            ));
        };
        let acquire = Arc::clone(&self.providers[index].permits).acquire_owned();
        let permit = tokio::select! {
            biased;
            _ = cancellation.cancelled() => return Err(cancelled_failure(ModelEffectState::None)),
            _ = wait_until(request.deadline) => return Err(deadline_failure(ModelEffectState::None)),
            result = acquire => result.map_err(|_| route_unavailable("provider route is unavailable"))?,
        };
        Ok(SelectedProvider {
            index,
            _permit: permit,
        })
    }

    async fn mark_unavailable(&self, provider_id: &str, failure: &ProviderFailure) {
        if matches!(
            failure.kind,
            ProviderFailureKind::RateLimited | ProviderFailureKind::TransientUnavailable
        ) {
            let until = Instant::now() + failure.retry_after.unwrap_or(Duration::from_secs(1));
            self.unavailable_until
                .lock()
                .await
                .insert(provider_id.to_owned(), until);
        }
    }
}

fn add_usage(left: ModelUsage, right: ModelUsage) -> Result<ModelUsage, ProviderFailure> {
    let input_tokens = left.input_tokens.checked_add(right.input_tokens);
    let output_tokens = left.output_tokens.checked_add(right.output_tokens);
    let cost_micros = match (left.cost_micros, right.cost_micros) {
        (Some(left), Some(right)) => Some(left.checked_add(right)),
        _ => None,
    };
    let (Some(input_tokens), Some(output_tokens)) = (input_tokens, output_tokens) else {
        return Err(usage_budget_failure());
    };
    let cost_micros = match cost_micros {
        Some(Some(cost)) => Some(cost),
        Some(None) => return Err(usage_budget_failure()),
        None => None,
    };
    Ok(ModelUsage {
        input_tokens,
        output_tokens,
        cost_micros,
    })
}

fn usage_budget_failure() -> ProviderFailure {
    ProviderFailure::new(
        ProviderFailureKind::BudgetExceeded,
        "provider usage exceeds the configured generation budget",
        false,
        ModelEffectState::None,
    )
}

fn check_cancelled_or_deadline(
    request: &ModelRequest,
    cancellation: &AgentCancellationToken,
) -> Result<(), ProviderFailure> {
    if cancellation.is_cancelled() {
        return Err(cancelled_failure(ModelEffectState::None));
    }
    if request
        .deadline
        .is_some_and(|deadline| deadline <= Instant::now())
    {
        return Err(deadline_failure(ModelEffectState::None));
    }
    Ok(())
}

async fn wait_until(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending::<()>().await,
    }
}

fn route_unavailable(message: &'static str) -> ProviderFailure {
    ProviderFailure::new(
        ProviderFailureKind::CapabilityUnavailable,
        message,
        false,
        ModelEffectState::None,
    )
}

fn cancelled_failure(effect_state: ModelEffectState) -> ProviderFailure {
    ProviderFailure::new(
        ProviderFailureKind::Cancelled,
        "provider request was cancelled",
        false,
        effect_state,
    )
}

fn deadline_failure(effect_state: ModelEffectState) -> ProviderFailure {
    ProviderFailure::new(
        ProviderFailureKind::Deadline,
        "provider request deadline expired",
        false,
        effect_state,
    )
}
