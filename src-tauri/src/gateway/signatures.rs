use std::collections::HashMap;

use super::history_args::{canonical_tool_arguments, current_tool_turn_start};
use super::redact::now_ms;

// Claude Code rebuilds assistant tool_use history from its known fields and drops provider
// metadata, so Gemini's signature cannot round-trip through the Anthropic wire. Keep a bounded,
// session-scoped server-side copy and restore it before the next Google/OpenAI-compatible request.
pub(super) const THOUGHT_SIGNATURE_TTL_MS: i64 = 6 * 60 * 60 * 1000;
const THOUGHT_SIGNATURE_CACHE_MAX: usize = 2048;
pub(super) const GEMINI_SIGNATURE_FALLBACK: &str = "skip_thought_signature_validator";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct CachedToolCall {
    call_id: String,
    name: String,
    arguments: String,
    signature: Option<String>,
}

#[derive(Clone, Debug)]
pub(super) struct ThoughtSignatureBatch {
    pub(super) calls: Vec<CachedToolCall>,
    pub(super) touched_at: i64,
}

#[derive(Default)]
pub(super) struct ThoughtSignatureCache {
    pub(super) batches: HashMap<(String, String), ThoughtSignatureBatch>,
}

impl ThoughtSignatureCache {
    fn prune(&mut self, now: i64) {
        self.batches.retain(|_, batch| {
            now.saturating_sub(batch.touched_at) <= THOUGHT_SIGNATURE_TTL_MS
        });
    }

    pub(super) fn remember(
        &mut self,
        provider_id: &str,
        session_id: Option<&str>,
        captured_calls: &[crate::protocol::stream::CapturedToolCall],
    ) {
        let now = now_ms();
        self.prune(now);
        let Some(session_id) = session_id else { return };
        let calls: Vec<CachedToolCall> = captured_calls.iter().map(|call| CachedToolCall {
            call_id: call.call_id.clone(),
            name: call.name.clone(),
            arguments: canonical_tool_arguments(&call.arguments),
            signature: call.thought_signature.as_deref()
                .filter(|signature| !signature.is_empty())
                .map(str::to_string),
        }).collect();
        let key = (provider_id.to_string(), session_id.to_string());
        if !calls.iter().any(|call| call.signature.is_some()) {
            if !calls.is_empty() {
                self.batches.remove(&key);
            }
            return;
        }

        if self.batches.len() >= THOUGHT_SIGNATURE_CACHE_MAX && !self.batches.contains_key(&key) {
            if let Some(oldest) = self.batches.iter()
                .min_by_key(|(_, batch)| batch.touched_at)
                .map(|(key, _)| key.clone())
            {
                self.batches.remove(&oldest);
            }
        }
        // Replacing the latest batch also makes terminal/EOF observations idempotent.
        self.batches.insert(key, ThoughtSignatureBatch {
            calls,
            touched_at: now,
        });
    }

    pub(super) fn restore(
        &mut self,
        provider_id: &str,
        session_id: Option<&str>,
        request: &mut llm_connector::types::ChatRequest,
    ) -> usize {
        let now = now_ms();
        self.prune(now);
        let Some(session_id) = session_id else { return 0 };
        let current_turn = current_tool_turn_start(request);
        let Some(message_index) = request.messages.iter()
            .enumerate()
            .skip(current_turn)
            .rev()
            .find_map(|(message_index, message)| {
                message.tool_calls.as_ref()
                    .filter(|calls| !calls.is_empty())
                    .map(|_| message_index)
            })
            else { return 0 };
        let Some(calls) = request.messages[message_index].tool_calls.as_mut() else { return 0 };
        let key = (provider_id.to_string(), session_id.to_string());
        let Some(batch) = self.batches.get_mut(&key) else { return 0 };
        if batch.calls.len() != calls.len()
            || !batch.calls.iter().zip(calls.iter()).all(|(cached, current)| {
                cached.call_id == current.id
                    && cached.name == current.function.name
                    && cached.arguments == canonical_tool_arguments(&current.function.arguments)
            })
        {
            return 0;
        }
        batch.touched_at = now;
        let mut restored = 0usize;
        for (call, cached) in calls.iter_mut().zip(&batch.calls) {
            if crate::protocol::tool_call_thought_signature(call).is_none() {
                if let Some(signature) = &cached.signature {
                    call.thought_signature = Some(signature.clone());
                    restored += 1;
                }
            }
        }
        restored
    }
}

/// Google documents this sentinel for function-call history that did not originate from the
/// current API response (transferred/synthetic history). We use it only when Claude stripped the
/// real signature and the session cache cannot recover it. For parallel calls, only the first call
/// in a model step gets a signature, matching Gemini's validation contract.
pub(super) fn apply_gemini_signature_fallback(request: &mut llm_connector::types::ChatRequest) -> usize {
    let mut applied = 0usize;
    // Gemini validates only the current turn: everything after the most recent ordinary user
    // message. Tool results decode as Role::Tool, so sequential tool steps remain in this slice.
    let current_turn = current_tool_turn_start(request);
    for message in request.messages.iter_mut().skip(current_turn) {
        let Some(calls) = message.tool_calls.as_mut() else { continue };
        if calls.is_empty()
            || crate::protocol::tool_call_thought_signature(&calls[0]).is_some()
        {
            continue;
        }
        calls[0].thought_signature = Some(GEMINI_SIGNATURE_FALLBACK.to_string());
        applied += 1;
    }
    applied
}
