// Response-id minting plus Gemini/OpenAI "thought signature" plumbing: providers round-trip an
// opaque reasoning token on tool calls, and it must survive translation in both directions or the
// upstream rejects the follow-up turn.

use llm_connector::types::ToolCall;
use serde_json::{json, Value};

/// Unique id for a synthesized response ("msg_ccbud_<ms>_<n>"). Clients persist these ids into
/// their history, and usage analytics de-dupes assistant messages BY id — a constant fallback id
/// would collapse every translated turn into a single counted request.
pub fn uid(prefix: &str) -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    format!("{}_{}_{}", prefix, ms, N.fetch_add(1, Ordering::Relaxed))
}

/// Extract Gemini's opaque thought signature from its OpenAI-compatible wire location, or from
/// an internal/native spelling encountered while translating. The canonical OpenAI compatibility
/// shape is `extra_content.google.thought_signature`.
pub(crate) fn json_thought_signature(value: &Value) -> Option<String> {
    value
        .pointer("/extra_content/google/thought_signature")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .or_else(|| {
            value
                .get("thought_signature")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
        })
        .or_else(|| {
            value
                .pointer("/function/thought_signature")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
        })
        .map(str::to_string)
}

/// Read the signature from the llm-connector IR. The crate supports both placements for native
/// Gemini, so accept either while keeping a single canonical wire representation at the edge.
pub(crate) fn tool_call_thought_signature(call: &ToolCall) -> Option<String> {
    call.thought_signature
        .as_deref()
        .filter(|s| !s.is_empty())
        .or_else(|| {
            call.function
                .thought_signature
                .as_deref()
                .filter(|s| !s.is_empty())
        })
        .map(str::to_string)
}

fn strip_internal_thought_signature(call: &mut Value) {
    let Some(call_obj) = call.as_object_mut() else {
        return;
    };
    call_obj.remove("thought_signature");
    if let Some(function) = call_obj.get_mut("function").and_then(Value::as_object_mut) {
        function.remove("thought_signature");
    }
}

fn set_google_thought_signature(call: &mut Value, signature: &str) {
    strip_internal_thought_signature(call);
    call["extra_content"]["google"]["thought_signature"] = json!(signature);
}

/// llm-connector serializes its internal signature fields literally. Rewrite them into Gemini's
/// OpenAI-compatible `extra_content.google.thought_signature` before forwarding.
pub(super) fn normalize_openai_request_thought_signatures(body: &mut Value) {
    let Some(messages) = body.get_mut("messages").and_then(Value::as_array_mut) else {
        return;
    };
    for message in messages {
        let Some(calls) = message.get_mut("tool_calls").and_then(Value::as_array_mut) else {
            continue;
        };
        for call in calls {
            if let Some(signature) = json_thought_signature(call) {
                set_google_thought_signature(call, &signature);
            }
        }
    }
}

/// Thinking chat upstreams (Kimi/Moonshot, DeepSeek, …) require every assistant message that
/// carries `tool_calls` to also carry a non-empty `reasoning_content`, and answer
/// "reasoning_content is missing in assistant tool call message" otherwise. Real reasoning is
/// bridged from the client history where available (thinking blocks, Responses reasoning items);
/// this is the last-resort placeholder for turns whose reasoning didn't survive the wire.
/// Providers without the requirement ignore the extra field.
pub(super) fn ensure_chat_tool_call_reasoning_content(body: &mut Value) {
    let Some(messages) = body.get_mut("messages").and_then(Value::as_array_mut) else {
        return;
    };
    for message in messages {
        let has_tool_calls = message.get("role").and_then(Value::as_str) == Some("assistant")
            && message
                .get("tool_calls")
                .and_then(Value::as_array)
                .is_some_and(|c| !c.is_empty());
        if !has_tool_calls {
            continue;
        }
        let missing = message
            .get("reasoning_content")
            .and_then(Value::as_str)
            .map_or(true, |s| s.trim().is_empty());
        if missing {
            message["reasoning_content"] = json!("tool call");
        }
    }
}

/// Gemini/OpenRouter/Cloudflare return provider metadata in `extra_content`, which serde ignores
/// when llm-connector parses a standard OpenAI ToolCall. Copy the opaque signature into the
/// crate's internal field before parsing; the original response remains otherwise unchanged.
pub(super) fn normalize_openai_response_thought_signatures(body: &mut Value) {
    let Some(choices) = body.get_mut("choices").and_then(Value::as_array_mut) else {
        return;
    };
    for choice in choices {
        let Some(calls) = choice
            .get_mut("message")
            .and_then(|message| message.get_mut("tool_calls"))
            .and_then(Value::as_array_mut)
        else {
            continue;
        };
        for call in calls {
            if let Some(signature) = json_thought_signature(call) {
                call["thought_signature"] = json!(signature);
            }
        }
    }
}
