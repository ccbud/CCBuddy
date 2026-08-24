// ---- shared Responses-side item builders (final `output_item.done` / `completed` payloads) ----

use super::super::openai_responses::CodexToolContext;
use super::common::ev;
use serde_json::{json, Value};

pub(super) fn resp_message_item(id: &str, text: &str) -> Value {
    json!({ "type": "message", "id": id, "status": "completed", "role": "assistant",
        "content": [{ "type": "output_text", "annotations": [], "text": text }] })
}

pub(super) fn resp_function_call_item(id: &str, call_id: &str, name: &str, args: &str) -> Value {
    json!({ "type": "function_call", "id": id, "status": "completed", "call_id": call_id,
        "name": name, "arguments": if args.is_empty() { "{}" } else { args } })
}

pub(super) fn resp_in_progress_tool_item(
    context: &CodexToolContext,
    id: &str,
    call_id: &str,
    name: &str,
    reasoning: Option<&str>,
) -> Value {
    let mut item =
        context.response_tool_item_with_reasoning(id, "in_progress", call_id, name, "", reasoning);
    if item.get("type").and_then(Value::as_str) == Some("function_call") {
        item["arguments"] = json!("");
    }
    item
}

pub(super) fn normalized_tool_arguments(arguments: &str) -> &str {
    if arguments.trim().is_empty() {
        "{}"
    } else {
        arguments
    }
}

pub(super) fn resp_reasoning_item(id: &str, text: &str) -> Value {
    json!({ "type": "reasoning", "id": id, "summary": [{ "type": "summary_text", "text": text }] })
}

pub(super) fn response_scoped_item_id(prefix: &str, response_id: &str, index: usize) -> String {
    format!(
        "{}_{}_{}",
        prefix,
        response_id.trim_start_matches("resp_"),
        index
    )
}

/// The terminal `response.completed` event. Codex parses `response.id` + `response.usage` from it
/// and treats a stream that closes without it as an error, so every Responses-emitting transcoder
/// must end with this exactly once.
pub(super) fn resp_completed(
    id: &str,
    model: &str,
    output: Vec<Value>,
    input: i64,
    cached: i64,
    output_tokens: i64,
) -> String {
    ev(
        "response.completed",
        json!({ "type": "response.completed", "response": {
            "id": id, "object": "response", "status": "completed", "model": model,
            "output": output,
            "usage": {
                "input_tokens": input.max(0),
                "input_tokens_details": { "cached_tokens": cached.max(0) },
                "output_tokens": output_tokens.max(0),
                "output_tokens_details": { "reasoning_tokens": 0 },
                "total_tokens": (input + output_tokens).max(0),
            } } }),
    )
}

pub(super) fn resp_incomplete(
    id: &str,
    model: &str,
    output: Vec<Value>,
    input: i64,
    cached: i64,
    output_tokens: i64,
    reason: &str,
) -> String {
    ev(
        "response.incomplete",
        json!({ "type": "response.incomplete", "response": {
            "id": id, "object": "response", "status": "incomplete", "model": model,
            "output": output,
            "incomplete_details": { "reason": reason },
            "usage": {
                "input_tokens": input.max(0),
                "input_tokens_details": { "cached_tokens": cached.max(0) },
                "output_tokens": output_tokens.max(0),
                "output_tokens_details": { "reasoning_tokens": 0 },
                "total_tokens": (input + output_tokens).max(0),
            } } }),
    )
}

pub(super) fn incomplete_reason(stop_reason: Option<&str>) -> Option<&'static str> {
    match stop_reason {
        Some("length" | "max_tokens" | "model_context_window_exceeded") => {
            Some("max_output_tokens")
        }
        Some("content_filter") => Some("content_filter"),
        _ => None,
    }
}

pub(super) fn resp_failed(id: &str, message: &str) -> String {
    ev(
        "response.failed",
        json!({ "type": "response.failed", "response": {
            "id": id, "object": "response", "status": "failed",
            "error": { "code": "upstream_error", "message": message }
        } }),
    )
}
