// Title / workspace / model extraction from Qoder's inline metadata records. Moved verbatim
// from qoder.rs.

use serde_json::Value;

fn trimmed_string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn latest_inline_string(records: &[Value], record_type: &str, field: &str) -> Option<String> {
    records.iter().rev().find_map(|record| {
        (record.get("type").and_then(Value::as_str) == Some(record_type))
            .then(|| trimmed_string(record.get(field)))
            .flatten()
    })
}

fn text_content(value: &Value) -> Option<String> {
    if let Some(text) = value.as_str() {
        let text = text.trim();
        return (!text.is_empty()).then(|| text.to_owned());
    }
    if let Some(blocks) = value.as_array() {
        let parts: Vec<&str> = blocks
            .iter()
            .filter_map(|block| {
                if let Some(text) = block.as_str() {
                    return Some(text);
                }
                let kind = block.get("type").and_then(Value::as_str).unwrap_or("");
                matches!(kind, "text" | "input_text")
                    .then(|| block.get("text").and_then(Value::as_str))
                    .flatten()
            })
            .map(str::trim)
            .filter(|part| !part.is_empty())
            .collect();
        if !parts.is_empty() {
            return Some(parts.join("\n"));
        }
    }
    value
        .get("text")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

fn summary_from(records: &[Value]) -> Option<String> {
    records.iter().rev().find_map(|record| {
        if record.get("type").and_then(Value::as_str) != Some("summary") {
            return None;
        }
        trimmed_string(record.get("summary"))
            .or_else(|| record.get("content").and_then(text_content))
            .or_else(|| {
                record
                    .get("message")
                    .and_then(|message| message.get("content"))
                    .and_then(text_content)
            })
    })
}

fn first_user_text_from(records: &[Value]) -> Option<String> {
    records
        .iter()
        .find_map(|record| match record.get("type").and_then(Value::as_str) {
            Some("user")
                if record.get("isMeta").and_then(Value::as_bool) != Some(true)
                    && record.get("isCompactSummary").and_then(Value::as_bool) != Some(true) =>
            {
                record
                    .get("message")
                    .and_then(|message| message.get("content"))
                    .and_then(text_content)
            }
            Some("attachment")
                if record
                    .get("attachment")
                    .and_then(|attachment| attachment.get("type"))
                    .and_then(Value::as_str)
                    == Some("queued_command") =>
            {
                trimmed_string(
                    record
                        .get("attachment")
                        .and_then(|attachment| attachment.get("prompt")),
                )
            }
            _ => None,
        })
}

/// Qoder's inline title, in the same precedence used by its own conversation list. Repeated
/// metadata records are append-only updates, so the last non-empty value wins within each tier.
pub(crate) fn session_title_from(records: &[Value]) -> Option<String> {
    latest_inline_string(records, "custom-title", "customTitle")
        .or_else(|| latest_inline_string(records, "ai-title", "aiTitle"))
        .or_else(|| latest_inline_string(records, "last-prompt", "lastPrompt"))
        .or_else(|| summary_from(records))
        .or_else(|| first_user_text_from(records))
}

/// Primary workspace from Qoder's latest inline `workspace-directories` record.
pub(crate) fn working_dir_from(records: &[Value]) -> Option<String> {
    records.iter().rev().find_map(|record| {
        if record.get("type").and_then(Value::as_str) != Some("workspace-directories") {
            return None;
        }
        record
            .get("directories")
            .and_then(Value::as_array)
            .and_then(|directories| {
                directories
                    .iter()
                    .find_map(|value| trimmed_string(Some(value)))
            })
    })
}

/// Effective model from Qoder's latest inline `runtime-config` update.
pub(crate) fn model_from(records: &[Value]) -> Option<String> {
    latest_inline_string(records, "runtime-config", "model")
}
