// Small shared conversions used by both Responses halves: call-id scoping, custom-tool argument
// wrapping, and the reasoning-effort ↔ thinking-budget mapping.

use super::tools::CUSTOM_TOOL_INPUT_FIELD;
use llm_connector::types::ReasoningEffort;
use serde_json::{json, Value};
use sha1::{Digest, Sha1};

/// Client-visible call ids must be unique even when an OpenAI-compatible upstream repeats or
/// omits its own ids for parallel calls. Scope them to the response and output position; the
/// client echoes this id, so subsequent translated history remains unambiguous.
pub(crate) fn response_scoped_call_id(response_id: &str, index: usize) -> String {
    let mut digest = Sha1::new();
    digest.update(response_id.as_bytes());
    let digest = format!("{:x}", digest.finalize());
    format!("call_{}_{}", &digest[..16], index)
}

pub(crate) fn custom_tool_input_from_chat_arguments(arguments: &str) -> String {
    if arguments.trim().is_empty() {
        return String::new();
    }
    match serde_json::from_str::<Value>(arguments) {
        Ok(Value::Object(object)) => object
            .get(CUSTOM_TOOL_INPUT_FIELD)
            .and_then(Value::as_str)
            .unwrap_or(arguments)
            .to_string(),
        _ => arguments.to_string(),
    }
}

pub(super) fn wrap_custom_tool_input(input: &Value) -> String {
    let input = input
        .as_str()
        .map(ToString::to_string)
        .unwrap_or_else(|| input.to_string());
    json!({ "input": input }).to_string()
}

pub(super) fn parse_tool_arguments_object(arguments: &str) -> Value {
    if arguments.trim().is_empty() {
        return json!({});
    }
    serde_json::from_str::<Value>(arguments)
        .ok()
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({ "query": arguments }))
}

/// Map a thinking budget (tokens) to a Responses reasoning effort tier.
pub(super) fn budget_to_effort(budget: Option<u32>) -> &'static str {
    match budget {
        Some(b) if b >= 8192 => "high",
        Some(b) if b >= 2048 => "medium",
        _ => "low",
    }
}

/// Reverse of budget_to_effort: a Responses reasoning effort tier → a thinking budget (tokens).
pub(super) fn effort_to_budget(effort: &str) -> u32 {
    match effort {
        "ultra" | "max" => 32768,
        "xhigh" => 24576,
        "high" => 16384,
        "medium" => 4096,
        _ => 1024, // "low" / "minimal"
    }
}

pub(super) fn effort_to_reasoning_effort(effort: &str) -> ReasoningEffort {
    match effort {
        "medium" => ReasoningEffort::Medium,
        "high" | "xhigh" | "max" | "ultra" => ReasoningEffort::High,
        _ => ReasoningEffort::Low,
    }
}

pub(super) fn response_incomplete_reason(finish_reason: Option<&str>) -> Option<&'static str> {
    match finish_reason {
        Some("length" | "max_tokens" | "model_context_window_exceeded") => {
            Some("max_output_tokens")
        }
        Some("content_filter") => Some("content_filter"),
        _ => None,
    }
}
