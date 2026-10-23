//! Deterministic conversation compaction with secret redaction.

use super::evidence::ContextSensitivity;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConversationTurn {
    pub id: String,
    pub revision: u64,
    pub text: String,
    pub token_cost: usize,
    pub sensitivity: ContextSensitivity,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConversationCompaction {
    pub summary: String,
    pub summary_digest: String,
    pub hot_turns: Vec<ConversationTurn>,
    pub omitted_turn_count: usize,
    pub redacted_turn_count: usize,
    pub truncated: bool,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ConversationCompactor;

impl ConversationCompactor {
    pub fn compact(
        &self,
        turns: &[ConversationTurn],
        max_hot_turns: usize,
        max_summary_tokens: usize,
    ) -> ConversationCompaction {
        let hot_start = turns.len().saturating_sub(max_hot_turns);
        let mut lines = Vec::new();
        let mut used_tokens: usize = 0;
        for turn in &turns[..hot_start] {
            let text = if turn.sensitivity == ContextSensitivity::Secret {
                "[redacted]"
            } else {
                turn.text.as_str()
            };
            let cost = turn
                .token_cost
                .clamp(1, max_summary_tokens.saturating_add(1));
            if used_tokens.saturating_add(cost) <= max_summary_tokens {
                lines.push(format!("{}@{}: {text}", turn.id, turn.revision));
                used_tokens += cost;
            }
        }
        let summary = lines.join("\n");
        use sha2::{Digest, Sha256};
        let digest = Sha256::digest(summary.as_bytes());
        let hot_turns = turns[hot_start..]
            .iter()
            .map(redact_secret)
            .collect::<Vec<_>>();
        let redacted_turn_count = turns
            .iter()
            .filter(|turn| turn.sensitivity == ContextSensitivity::Secret)
            .count();
        ConversationCompaction {
            summary,
            summary_digest: format!("{digest:x}"),
            hot_turns,
            omitted_turn_count: hot_start,
            redacted_turn_count,
            truncated: hot_start > 0,
        }
    }
}

fn redact_secret(turn: &ConversationTurn) -> ConversationTurn {
    if turn.sensitivity != ContextSensitivity::Secret {
        return turn.clone();
    }
    ConversationTurn {
        text: "[redacted]".to_owned(),
        ..turn.clone()
    }
}
