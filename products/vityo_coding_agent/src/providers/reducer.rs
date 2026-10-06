//! Bounded assembly of streamed text and fragmented tool calls.

use std::collections::BTreeMap;

use super::types::{
    ModelEffectState, ModelEvent, ModelExecutionReceipt, ModelFinishReason, ModelToolCall,
    ModelUsage, ProviderFailure, ProviderFailureKind,
};

pub struct ProviderStreamReducer {
    max_buffered_output_bytes: usize,
    max_tool_argument_bytes: usize,
    max_buffered_tool_bytes: usize,
    max_pending_tool_calls: usize,
    max_tool_calls: usize,
    text: String,
    text_bytes: usize,
    tool_bytes: usize,
    pending: BTreeMap<u32, ToolCallBuilder>,
    completed: Vec<ModelToolCall>,
    usage: Option<ModelUsage>,
    finish_reason: Option<ModelFinishReason>,
}

impl ProviderStreamReducer {
    pub fn new(
        max_buffered_output_bytes: usize,
        max_tool_argument_bytes: usize,
        max_buffered_tool_bytes: usize,
        max_pending_tool_calls: usize,
        max_tool_calls: usize,
    ) -> Self {
        Self {
            max_buffered_output_bytes,
            max_tool_argument_bytes,
            max_buffered_tool_bytes,
            max_pending_tool_calls,
            max_tool_calls,
            text: String::new(),
            text_bytes: 0,
            tool_bytes: 0,
            pending: BTreeMap::new(),
            completed: Vec::new(),
            usage: None,
            finish_reason: None,
        }
    }

    pub fn observed_usage(&self) -> Option<ModelUsage> {
        self.usage
    }

    pub fn add(&mut self, event: ModelEvent) -> Result<(), ProviderFailure> {
        if self.finish_reason.is_some() {
            return Err(protocol("provider emitted an event after completion"));
        }
        match event {
            ModelEvent::TextDelta(text) => {
                let bytes = text.len();
                if self.text_bytes.saturating_add(bytes) > self.max_buffered_output_bytes {
                    return Err(budget("provider text exceeds the bounded output buffer"));
                }
                self.text_bytes += bytes;
                self.text.push_str(&text);
            }
            ModelEvent::ToolCallDelta {
                index,
                id,
                name,
                arguments_fragment,
            } => self.add_tool_delta(index, id, name, arguments_fragment)?,
            ModelEvent::Usage(usage) => {
                if self.usage.replace(usage).is_some() {
                    return Err(protocol("provider emitted more than one usage receipt"));
                }
            }
            ModelEvent::Completed(reason) => {
                if self.usage.is_none() {
                    return Err(protocol("provider completed without a usage receipt"));
                }
                self.finish_reason = Some(reason);
            }
        }
        Ok(())
    }

    pub fn finish(
        &mut self,
        request_id: String,
        provider_id: String,
    ) -> Result<ModelExecutionReceipt, ProviderFailure> {
        let Some(finish_reason) = self.finish_reason else {
            return Err(protocol("provider stream ended without a completion event"));
        };
        if !self.pending.is_empty() {
            if finish_reason != ModelFinishReason::ToolCalls {
                return Err(protocol("provider completed with a fragmented tool call"));
            }
            for (_, pending) in std::mem::take(&mut self.pending) {
                self.completed.push(pending.finish()?);
            }
        }
        Ok(ModelExecutionReceipt {
            request_id,
            provider_id,
            text: self.text.clone(),
            tool_calls: self.completed.clone(),
            usage: self.usage.expect("completion required usage"),
            finish_reason,
        })
    }

    fn add_tool_delta(
        &mut self,
        index: u32,
        id: Option<String>,
        name: Option<String>,
        arguments_fragment: String,
    ) -> Result<(), ProviderFailure> {
        if !self.pending.contains_key(&index)
            && self.completed.len() + self.pending.len() >= self.max_tool_calls
        {
            return Err(budget("provider emitted too many tool calls"));
        }
        if !self.pending.contains_key(&index) && self.pending.len() >= self.max_pending_tool_calls {
            return Err(budget("provider has too many fragmented tool calls"));
        }
        let fragment_bytes = arguments_fragment.len();
        if self.tool_bytes.saturating_add(fragment_bytes) > self.max_buffered_tool_bytes {
            return Err(budget("tool arguments exceed the bounded fragment buffer"));
        }
        let builder = self.pending.entry(index).or_default();
        if builder.argument_bytes.saturating_add(fragment_bytes) > self.max_tool_argument_bytes {
            return Err(budget("tool arguments exceed the bounded fragment buffer"));
        }
        if let Some(id) = id {
            if id.trim().is_empty() || builder.id.as_ref().is_some_and(|known| known != &id) {
                return Err(protocol(
                    "provider changed the tool call id during streaming",
                ));
            }
            builder.id = Some(id);
        }
        if let Some(name) = name {
            if name.trim().is_empty() || builder.name.as_ref().is_some_and(|known| known != &name) {
                return Err(protocol(
                    "provider changed the tool call name during streaming",
                ));
            }
            builder.name = Some(name);
        }
        builder.arguments.push_str(&arguments_fragment);
        builder.argument_bytes += fragment_bytes;
        self.tool_bytes += fragment_bytes;
        Ok(())
    }
}

#[derive(Default)]
struct ToolCallBuilder {
    id: Option<String>,
    name: Option<String>,
    arguments: String,
    argument_bytes: usize,
}

impl ToolCallBuilder {
    fn finish(self) -> Result<ModelToolCall, ProviderFailure> {
        let Some(id) = self.id.filter(|id| !id.trim().is_empty()) else {
            return Err(protocol("completed tool call has no id"));
        };
        let Some(name) = self.name.filter(|name| !name.trim().is_empty()) else {
            return Err(protocol("completed tool call has no name"));
        };
        let value = serde_json::from_str::<serde_json::Value>(&self.arguments)
            .map_err(|_| protocol("tool arguments are not valid JSON object data"))?;
        let Some(arguments) = value.as_object() else {
            return Err(protocol("tool arguments are not valid JSON object data"));
        };
        Ok(ModelToolCall {
            id,
            name,
            arguments: arguments.clone(),
        })
    }
}

fn protocol(message: &'static str) -> ProviderFailure {
    ProviderFailure::new(
        ProviderFailureKind::Protocol,
        message,
        false,
        ModelEffectState::Uncertain,
    )
}

fn budget(message: &'static str) -> ProviderFailure {
    ProviderFailure::new(
        ProviderFailureKind::BudgetExceeded,
        message,
        false,
        ModelEffectState::Uncertain,
    )
}
