// Deciding whether a request's input (or a single history item) can be materialized verbatim for
// a different provider.

use super::cache_items::{
    is_call_item_type, is_call_output_item_type, is_empty_value, response_item_call_id,
};
use serde_json::Value;

pub(super) fn request_input_items(request: &Value) -> Vec<Value> {
    match request.get("input") {
        Some(Value::Array(items)) => items.clone(),
        Some(Value::Object(object)) => vec![Value::Object(object.clone())],
        Some(Value::String(value)) => vec![serde_json::json!({
            "type": "message",
            "role": "user",
            "content": value,
        })],
        _ => Vec::new(),
    }
}

pub(super) fn request_input_is_materializable(request: &Value) -> bool {
    match request.get("input") {
        None | Some(Value::String(_)) => true,
        Some(Value::Array(items)) => items.iter().all(history_item_is_materializable),
        Some(item @ Value::Object(_)) => history_item_is_materializable(item),
        _ => false,
    }
}

pub(super) fn history_item_is_materializable(item: &Value) -> bool {
    let Some(object) = item.as_object() else {
        return false;
    };
    let item_type = object
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_else(|| {
            if object.get("role").is_some() {
                "message"
            } else {
                ""
            }
        });
    match item_type {
        // Responses Lite carries request-scoped tool declarations as a developer input item.
        // They are ordinary JSON tool definitions and can be replayed when CC Buddy has to
        // materialize a previous response across providers.
        "additional_tools" => object.get("tools").is_some_and(Value::is_array),
        "message" => object
            .get("content")
            .map_or(true, history_content_is_materializable),
        "reasoning" => {
            let has_opaque_reasoning = object
                .get("encrypted_content")
                .is_some_and(|value| !is_empty_value(value));
            !has_opaque_reasoning
                && object
                    .get("summary")
                    .map_or(true, history_content_is_materializable)
                && object
                    .get("content")
                    .map_or(true, history_content_is_materializable)
        }
        item_type if is_call_item_type(item_type) || is_call_output_item_type(item_type) => true,
        _ => false,
    }
}

pub(super) fn history_content_is_materializable(content: &Value) -> bool {
    match content {
        Value::Null | Value::String(_) => true,
        Value::Array(parts) => parts.iter().all(|part| {
            let Some(part_type) = part.get("type").and_then(Value::as_str) else {
                return false;
            };
            match part_type {
                "input_text" | "output_text" | "text" | "summary_text" => {
                    part.get("text").is_some_and(Value::is_string)
                }
                "input_image" => part
                    .get("image_url")
                    .and_then(|value| {
                        value
                            .as_str()
                            .or_else(|| value.get("url").and_then(Value::as_str))
                    })
                    .is_some(),
                _ => false,
            }
        }),
        _ => false,
    }
}

pub(super) fn cached_item_matches_input(cached: &Value, input: &Value) -> bool {
    let cached_type = cached.get("type").and_then(Value::as_str);
    let input_type = input.get("type").and_then(Value::as_str);
    if cached_type.is_some_and(is_call_item_type) {
        return input_type.is_some_and(is_call_item_type)
            && response_item_call_id(cached).is_some_and(|call_id| {
                response_item_call_id(input).as_deref() == Some(call_id.as_str())
            });
    }

    if let Some(id) = cached
        .get("id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|id| !id.is_empty())
    {
        return cached_type == input_type
            && input
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|input_id| input_id.trim() == id);
    }
    cached == input
}
