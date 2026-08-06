// One transcript line → one viewer message, plus the small text helpers the title and the
// filename derive from. Moved verbatim from exporthtml.rs.

use serde_json::{json, Value};

use super::parse::{cap_content, usage_of};

pub(super) fn line_to_msg(rec: &Value) -> Option<Value> {
    let ty = rec.get("type").and_then(|v| v.as_str())?;
    if ty != "user" && ty != "assistant" {
        return None;
    }
    let m = rec.get("message")?;
    m.get("role").and_then(|v| v.as_str())?;
    let mut out = json!({
        "role": m.get("role").cloned().unwrap_or(Value::Null),
        "content": cap_content(m.get("content").unwrap_or(&Value::Null)),
        "ts": rec.get("timestamp").cloned().unwrap_or(Value::Null),
        "meta": rec.get("isMeta").and_then(|v| v.as_bool()).unwrap_or(false),
    });
    if ty == "assistant" {
        let o = out.as_object_mut().unwrap();
        o.insert(
            "model".into(),
            m.get("model").cloned().unwrap_or(Value::Null),
        );
        o.insert(
            "usage".into(),
            m.get("usage").map(usage_of).unwrap_or(Value::Null),
        );
        o.insert(
            "stop".into(),
            m.get("stop_reason").cloned().unwrap_or(Value::Null),
        );
    }
    Some(out)
}

fn content_text(content: &Value) -> String {
    if let Some(s) = content.as_str() {
        return s.to_string();
    }
    if let Some(arr) = content.as_array() {
        return arr
            .iter()
            .filter(|b| b.get("type").and_then(|t| t.as_str()) == Some("text"))
            .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
            .collect::<Vec<_>>()
            .join(" ");
    }
    String::new()
}
fn command_label(raw: &str) -> String {
    let name = raw
        .split_once("<command-name>")
        .and_then(|(_, r)| r.split_once("</command-name>"))
        .map(|(n, _)| n.trim().to_string())
        .unwrap_or_default();
    if name.is_empty() {
        return String::new();
    }
    let args = raw
        .split_once("<command-args>")
        .and_then(|(_, r)| r.split_once("</command-args>"))
        .map(|(a, _)| a.trim().to_string())
        .unwrap_or_default();
    format!("{} {}", name, args).trim().to_string()
}
pub(super) fn first_user_text(messages: &[Value]) -> String {
    let mut fallback = String::new();
    for m in messages {
        if m.get("role").and_then(|r| r.as_str()) != Some("user")
            || m.get("meta").and_then(|v| v.as_bool()).unwrap_or(false)
        {
            continue;
        }
        let raw = content_text(m.get("content").unwrap_or(&Value::Null));
        let raw = raw.trim();
        if raw.is_empty() {
            continue;
        }
        if raw.starts_with('<') {
            if fallback.is_empty() {
                fallback = command_label(raw);
            }
            continue;
        }
        let t: String = raw.split_whitespace().collect::<Vec<_>>().join(" ");
        if t.starts_with("[Request interrupted") || t.starts_with("Caveat:") {
            continue;
        }
        return t.chars().take(100).collect();
    }
    fallback.chars().take(100).collect()
}
pub(super) fn base_name(p: &str) -> String {
    p.split('/')
        .filter(|s| !s.is_empty())
        .last()
        .unwrap_or(p)
        .to_string()
}
