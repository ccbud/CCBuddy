use serde_json::{json, Value};

pub(super) fn canonical_tool_arguments(arguments: &str) -> String {
    if arguments.trim().is_empty() {
        return "{}".to_string();
    }
    serde_json::from_str::<Value>(arguments)
        .map(|v| v.to_string())
        .unwrap_or_else(|_| arguments.to_string())
}

/// Codex records a model-emitted function call even when the host cannot parse its arguments, then
/// sends that failed call back on the next Responses turn beside the router error. OpenAI accepts
/// the arguments as an opaque string, but stricter chat providers (notably Gemini) parse every
/// historical `tool_calls[].function.arguments` value and reject the whole request when a model
/// appended prose or a second object. Preserve valid object arguments byte-for-byte so cached
/// thought signatures still match; otherwise salvage the first complete object, or wrap the raw
/// text in a valid object as a last resort.
pub(super) fn provider_safe_history_tool_arguments(arguments: &str) -> Option<String> {
    let trimmed = arguments.trim();
    if trimmed.is_empty() {
        return Some("{}".to_string());
    }
    match serde_json::from_str::<Value>(arguments) {
        Ok(Value::Object(_)) => return None,
        Ok(value) => return Some(json!({ "_ccbuddy_value": value }).to_string()),
        Err(_) => {}
    }
    if let Some(Ok(Value::Object(object))) = serde_json::Deserializer::from_str(trimmed)
        .into_iter::<Value>()
        .next()
    {
        return Some(Value::Object(object).to_string());
    }
    Some(json!({ "_ccbuddy_raw_arguments": arguments }).to_string())
}

pub(super) fn sanitize_provider_history_tool_arguments(
    request: &mut llm_connector::types::ChatRequest,
) -> usize {
    let mut repaired = 0usize;
    for message in &mut request.messages {
        let Some(calls) = message.tool_calls.as_mut() else { continue };
        for call in calls {
            let Some(arguments) = provider_safe_history_tool_arguments(&call.function.arguments)
            else { continue };
            call.function.arguments = arguments;
            // A provider signature authenticates the exact call payload. Repaired arguments must
            // use the documented synthetic-history fallback instead of a now-stale real signature.
            call.thought_signature = None;
            call.function.thought_signature = None;
            repaired += 1;
        }
    }
    repaired
}

pub(super) fn current_tool_turn_start(request: &llm_connector::types::ChatRequest) -> usize {
    request.messages.iter()
        .rposition(|message| message.role == llm_connector::types::Role::User)
        .map(|index| index + 1)
        .unwrap_or(0)
}
