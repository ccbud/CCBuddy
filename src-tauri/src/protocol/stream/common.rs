// Pieces shared by every transcoder: the captured-tool-call record the gateway reads back, SSE
// event framing, upstream error detection, and the OpenAI→Anthropic stop-reason mapping.

use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapturedToolCall {
    pub call_id: String,
    pub name: String,
    pub arguments: String,
    pub thought_signature: Option<String>,
}

pub(super) fn ev(event: &str, data: Value) -> String {
    format!(
        "event: {}\ndata: {}\n\n",
        event,
        serde_json::to_string(&data).unwrap_or_default()
    )
}

pub(super) fn upstream_error_message(event: &Value) -> Option<&str> {
    let error = event.get("error").filter(|value| !value.is_null());
    let is_error = error.is_some() || event.get("type").and_then(Value::as_str) == Some("error");
    if !is_error {
        return None;
    }
    error
        .and_then(|value| value.get("message").and_then(Value::as_str))
        .or_else(|| error.and_then(Value::as_str))
        .or_else(|| event.get("message").and_then(Value::as_str))
        .or(Some("upstream error"))
}

pub(super) fn map_stop(finish: Option<&str>, had_tool: bool) -> &'static str {
    match finish {
        Some("length") => "max_tokens",
        Some("tool_calls") | Some("function_call") => "tool_use",
        _ if had_tool => "tool_use",
        _ => "end_turn",
    }
}
