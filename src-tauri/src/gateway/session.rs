use serde_json::Value;

pub(super) fn request_session_id(body: &Value) -> Option<String> {
    // Claude Code: metadata.user_id is a JSON string carrying session_id.
    if let Some(raw) = body.pointer("/metadata/user_id").and_then(Value::as_str) {
        if let Ok(metadata) = serde_json::from_str::<Value>(raw.trim()) {
            if let Some(session) = metadata.get("session_id").and_then(Value::as_str)
                .filter(|session| !session.is_empty())
            {
                return Some(session.to_string());
            }
        }
    }
    // Codex (Responses client): prompt_cache_key carries the conversation id.
    body.get("prompt_cache_key").and_then(Value::as_str)
        .map(str::trim)
        .filter(|session| !session.is_empty())
        .map(str::to_string)
}

pub(super) fn codex_history_scope_for_session(request_session: Option<&str>) -> String {
    request_session.unwrap_or("").to_string()
}

pub(super) fn response_tool_calls(
    response: &llm_connector::types::ChatResponse,
) -> Vec<crate::protocol::stream::CapturedToolCall> {
    response.choices.first().and_then(|choice| choice.message.tool_calls.as_ref())
        .map(|calls| calls.iter().map(|call| {
            crate::protocol::stream::CapturedToolCall {
                call_id: call.id.clone(),
                name: call.function.name.clone(),
                arguments: call.function.arguments.clone(),
                thought_signature: crate::protocol::tool_call_thought_signature(call),
            }
        }).collect())
        .unwrap_or_default()
}

pub(super) fn response_tool_calls_with_client_ids(
    response: &llm_connector::types::ChatResponse,
    encoded_response: &Value,
) -> Vec<crate::protocol::stream::CapturedToolCall> {
    let mut captured = response_tool_calls(response);
    let client_ids = encoded_response
        .get("output")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|item| {
            matches!(
                item.get("type").and_then(Value::as_str),
                Some("function_call" | "custom_tool_call" | "tool_search_call")
            )
        })
        .filter_map(|item| item.get("call_id").and_then(Value::as_str));
    for (call, client_id) in captured.iter_mut().zip(client_ids) {
        call.call_id = client_id.to_string();
    }
    captured
}
