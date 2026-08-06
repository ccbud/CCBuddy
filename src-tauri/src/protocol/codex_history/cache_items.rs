// Reading call / call-output items out of a cached response, and grafting cached metadata back
// onto a client-supplied call item.

use serde_json::Value;

pub(super) fn cached_call_item(item: &Value) -> Option<(String, Value)> {
    if !item
        .get("type")
        .and_then(Value::as_str)
        .is_some_and(is_call_item_type)
    {
        return None;
    }
    let call_id = response_item_call_id(item)?;
    Some((call_id, item.clone()))
}

pub(super) fn cached_output_item(item: &Value) -> Option<Value> {
    match item.get("type").and_then(Value::as_str) {
        Some("reasoning") => Some(item.clone()),
        Some("message")
            if item
                .get("role")
                .and_then(Value::as_str)
                .map_or(true, |role| role == "assistant") =>
        {
            Some(item.clone())
        }
        Some(item_type) if is_call_item_type(item_type) => Some(item.clone()),
        _ => None,
    }
}

pub(super) fn response_item_call_id(item: &Value) -> Option<String> {
    item.get("call_id")
        .or_else(|| item.get("id"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

pub(super) fn is_call_item_type(item_type: &str) -> bool {
    matches!(
        item_type,
        "function_call" | "custom_tool_call" | "tool_search_call"
    )
}

pub(super) fn is_call_output_item_type(item_type: &str) -> bool {
    matches!(
        item_type,
        "function_call_output" | "custom_tool_call_output" | "tool_search_output"
    )
}

pub(super) fn is_empty_value(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::String(value) => value.trim().is_empty(),
        Value::Array(value) => value.is_empty(),
        Value::Object(value) => value.is_empty(),
        _ => false,
    }
}

pub(super) fn enrich_call_item_from_cache(item: &mut Value, cached: &Value) -> bool {
    let mut changed = false;
    for key in [
        "name",
        "namespace",
        "arguments",
        "input",
        "status",
        "execution",
        "reasoning_content",
        "reasoning",
    ] {
        if item.get(key).is_some_and(|value| !is_empty_value(value)) {
            continue;
        }
        let Some(value) = cached.get(key).filter(|value| !is_empty_value(value)) else {
            continue;
        };
        if let Some(object) = item.as_object_mut() {
            object.insert(key.to_string(), value.clone());
            changed = true;
        }
    }
    changed
}
