// Converting Qoder's append-only wire records into the Claude-like records the shared history
// shaper consumes, plus the content sniff for transcripts that lost their container path. Moved
// verbatim from qoder.rs.

use serde_json::{json, Value};
use std::collections::HashMap;

fn has_value(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::String(value) => !value.trim().is_empty(),
        Value::Array(value) => !value.is_empty(),
        Value::Object(value) => !value.is_empty(),
        Value::Bool(_) | Value::Number(_) => true,
    }
}

fn without_redacted_thinking(record: &Value) -> Value {
    let mut record = record.clone();
    if let Some(content) = record
        .get_mut("message")
        .and_then(|message| message.get_mut("content"))
        .and_then(Value::as_array_mut)
    {
        content
            .retain(|block| block.get("type").and_then(Value::as_str) != Some("redacted_thinking"));
    }
    record
}

fn merge_assistant_wrapper(target: &mut Value, wrapper: &Value) {
    let Some(source_message) = wrapper.get("message").and_then(Value::as_object) else {
        return;
    };
    let Some(target_message) = target.get_mut("message").and_then(Value::as_object_mut) else {
        return;
    };

    if let Some(source_content) = source_message.get("content").and_then(Value::as_array) {
        match target_message.get_mut("content") {
            Some(Value::Array(target_content)) => {
                target_content.extend(source_content.iter().cloned())
            }
            Some(Value::Null) | None => {
                target_message.insert("content".to_string(), Value::Array(source_content.clone()));
            }
            Some(_) => {}
        }
    }

    for field in ["model", "usage", "stop_reason"] {
        if let Some(value) = source_message.get(field).filter(|value| has_value(value)) {
            target_message.insert(field.to_string(), value.clone());
        }
    }
}

fn queued_command_as_user(record: &Value) -> Option<Value> {
    let attachment = record.get("attachment")?;
    if attachment.get("type").and_then(Value::as_str) != Some("queued_command") {
        return None;
    }
    let prompt = attachment
        .get("prompt")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let mut normalized = record.clone();
    let object = normalized.as_object_mut()?;
    object.insert("type".to_string(), Value::String("user".to_string()));
    object.insert(
        "message".to_string(),
        json!({ "role": "user", "content": prompt }),
    );
    object.remove("attachment");
    Some(normalized)
}

/// Content sniff for qoder transcripts that lost their container path (import copies, bundle
/// zips): the inline metadata / queued-command record types are qoder-only vocabulary that no
/// Claude Code or Codex transcript produces.
pub(crate) fn looks_qoder_records(records: &[Value]) -> bool {
    records.iter().any(|record| match record.get("type").and_then(Value::as_str) {
        Some("agent-setting") | Some("ai-title") | Some("custom-title") | Some("last-prompt")
        | Some("workspace-directories") | Some("runtime-config") => true,
        Some("attachment") => {
            record
                .get("attachment")
                .and_then(|attachment| attachment.get("type"))
                .and_then(Value::as_str)
                == Some("queued_command")
        }
        _ => false,
    })
}

/// Convert Qoder's append-only wire records into the Claude-like records expected by the shared
/// history shaper. Atomic assistant wrappers with the same `message.id` collapse at their first
/// position, queued prompts become user messages, and opaque duplicate thinking blocks are
/// discarded in favor of the corresponding ordinary `thinking` block.
pub(crate) fn normalize_records(records: &[Value]) -> Vec<Value> {
    let mut normalized = Vec::with_capacity(records.len());
    let mut assistant_by_message_id: HashMap<String, usize> = HashMap::new();

    for record in records {
        if let Some(user) = queued_command_as_user(record) {
            normalized.push(user);
            continue;
        }
        if record.get("type").and_then(Value::as_str) != Some("assistant") {
            normalized.push(record.clone());
            continue;
        }

        let wrapper = without_redacted_thinking(record);
        let message_id = wrapper
            .get("message")
            .and_then(|message| message.get("id"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .map(str::to_owned);
        if let Some(message_id) = message_id {
            if let Some(index) = assistant_by_message_id.get(&message_id).copied() {
                merge_assistant_wrapper(&mut normalized[index], &wrapper);
            } else {
                assistant_by_message_id.insert(message_id, normalized.len());
                normalized.push(wrapper);
            }
        } else {
            normalized.push(wrapper);
        }
    }

    normalized
}
