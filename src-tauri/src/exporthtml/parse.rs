// Transcript reading and the per-field capping that keeps the embedded JSON bounded. Moved
// verbatim from exporthtml.rs.

use serde_json::{json, Value};
use std::fs;
use std::path::Path;

use super::assets::{
    CAP_CONTENT, CAP_PROMPT, CAP_RESULT, CAP_SKILL_SNAPSHOT, CAP_TEXT, CAP_THINKING,
};

fn cap(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        let truncated: String = s.chars().take(n).collect();
        let dropped = s.chars().count() - n;
        format!("{}\n…[truncated {} chars]", truncated, dropped)
    } else {
        s.to_string()
    }
}

pub(super) fn parse_jsonl_result(file: &Path) -> std::io::Result<Vec<Value>> {
    let qoder = crate::qoder::looks_qoder_path(file);
    let raw = if qoder { crate::qoder::read_text(file) } else { fs::read_to_string(file) }?;
    let records: Vec<Value> = raw
        .split('\n')
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .collect();
    Ok(if qoder {
        crate::qoder::normalize_records(&records)
    } else {
        records
    })
}

/// Skip-on-error variant for subagent sidecars — one broken agent file must not sink the export.
/// The MAIN transcript goes through parse_jsonl_result so a read failure surfaces to the caller
/// instead of exporting an empty page.
pub(super) fn parse_jsonl(file: &Path) -> Vec<Value> {
    parse_jsonl_result(file).unwrap_or_default()
}

pub(super) fn usage_of(u: &Value) -> Value {
    let mut usage = json!({
        "in": u.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "out": u.get("output_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "cacheRead": u.get("cache_read_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "cacheCreation": u.get("cache_creation_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
    });
    let object = usage.as_object_mut().unwrap();
    for (source, target) in [
        ("credits", "credits"),
        ("original_credits", "originalCredits"),
        ("context_usage_ratio", "contextUsageRatio"),
    ] {
        if let Some(value) = u.get(source).filter(|value| value.is_number()) {
            object.insert(target.to_string(), value.clone());
        }
    }
    usage
}

pub(super) fn cap_content(content: &Value) -> Value {
    if let Some(s) = content.as_str() {
        return json!(cap(s, CAP_TEXT));
    }
    let arr = match content.as_array() {
        Some(a) => a,
        None => return content.clone(),
    };
    let mapped: Vec<Value> = arr
        .iter()
        .map(|b| {
            let ty = b.get("type").and_then(|t| t.as_str()).unwrap_or("");
            match ty {
                "text" => json!({ "type": "text", "text": cap(b.get("text").and_then(|t| t.as_str()).unwrap_or(""), CAP_TEXT) }),
                "thinking" => json!({ "type": "thinking", "thinking": cap(b.get("thinking").and_then(|t| t.as_str()).unwrap_or(""), CAP_THINKING) }),
                "skill_load" => json!({
                    "type": "skill_load",
                    "name": b.get("name").cloned().unwrap_or(Value::Null),
                    "path": b.get("path").cloned().unwrap_or(Value::Null),
                    "snapshot": b
                        .get("snapshot")
                        .and_then(|v| v.as_str())
                        .map(|v| json!(cap(v, CAP_SKILL_SNAPSHOT)))
                        .unwrap_or(Value::Null),
                }),
                "tool_use" => {
                    let mut input = b.get("input").cloned().unwrap_or(json!({}));
                    if let Some(obj) = input.as_object_mut() {
                        if let Some(p) = obj.get("prompt").and_then(|v| v.as_str()) {
                            let c = cap(p, CAP_PROMPT);
                            obj.insert("prompt".into(), json!(c));
                        }
                        if let Some(p) = obj.get("content").and_then(|v| v.as_str()) {
                            let c = cap(p, CAP_CONTENT);
                            obj.insert("content".into(), json!(c));
                        }
                        if let Some(p) = obj.get("patch").and_then(|v| v.as_str()) {
                            let c = cap(p, CAP_CONTENT); // codex ApplyPatch envelopes can be huge
                            obj.insert("patch".into(), json!(c));
                        }
                        if let Some(p) = obj.get("code").and_then(|v| v.as_str()) {
                            let c = cap(p, CAP_CONTENT); // code-mode Script bodies
                            obj.insert("code".into(), json!(c));
                        }
                    }
                    json!({ "type": "tool_use", "id": b.get("id").cloned().unwrap_or(Value::Null), "name": b.get("name").cloned().unwrap_or(Value::Null), "input": input })
                }
                "tool_result" => {
                    let c = match b.get("content") {
                        Some(Value::String(s)) => json!(cap(s, CAP_RESULT)),
                        Some(Value::Array(ca)) => Value::Array(
                            ca.iter()
                                .map(|x| {
                                    if x.get("type").and_then(|t| t.as_str()) == Some("text") {
                                        json!({ "type": "text", "text": cap(x.get("text").and_then(|t| t.as_str()).unwrap_or(""), CAP_RESULT) })
                                    } else {
                                        x.clone()
                                    }
                                })
                                .collect(),
                        ),
                        other => other.cloned().unwrap_or(Value::Null),
                    };
                    json!({ "type": "tool_result", "tool_use_id": b.get("tool_use_id").cloned().unwrap_or(Value::Null), "is_error": b.get("is_error").and_then(|v| v.as_bool()).unwrap_or(false), "content": c })
                }
                "image" => {
                    let oversized = b.get("source").and_then(|s| s.get("data")).and_then(|d| d.as_str()).map(|d| d.len() > 600000).unwrap_or(false);
                    if oversized {
                        json!({ "type": "image", "source": { "media_type": b.get("source").and_then(|s| s.get("media_type")).and_then(|m| m.as_str()).unwrap_or("image/png"), "oversized": true } })
                    } else {
                        b.clone()
                    }
                }
                _ => b.clone(),
            }
        })
        .collect();
    Value::Array(mapped)
}
