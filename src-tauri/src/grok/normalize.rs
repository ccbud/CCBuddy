// chat_history.jsonl → history::Norm: harness-wrapper stripping, tool-name mapping onto the
// renderer's native vocabulary, and the per-line walk that builds the message timeline.

use crate::history::{image_block, Norm};
use serde_json::{json, Value};

pub(super) fn rfc3339_ms(s: &str) -> Option<f64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|d| d.timestamp_millis() as f64)
}

/// Harness-injected user text (environment wrappers) — hidden from the timeline.
fn is_meta_user_text(t: &str) -> bool {
    let t = t.trim_start();
    ["<user_info>", "<git_status>", "<system-reminder>", "<project_layout", "<workspace_"]
        .iter()
        .any(|p| t.starts_with(p))
}

/// Unwrap `<user_query>…</user_query>` (the human prose envelope grok writes).
fn unwrap_user_query(t: &str) -> String {
    match t.split_once("<user_query>") {
        Some((_, rest)) => rest.split("</user_query>").next().unwrap_or(rest).trim().to_string(),
        None => t.trim().to_string(),
    }
}

/// Grok tool name + parsed arguments → (renderer tool name, renderer input). Covers both grok
/// tool-name generations (snake_case and CamelCase).
fn map_tool(name: &str, args: &Value) -> (String, Value) {
    let s = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let keep = |v: &Value| if v.is_object() { v.clone() } else { json!({}) };
    match name {
        "run_terminal_command" | "Shell" => {
            let mut input = json!({ "command": s("command") });
            if !s("description").is_empty() {
                input["description"] = json!(s("description"));
            }
            ("Bash".into(), input)
        }
        "read_file" | "Read" => {
            let path = if !s("target_file").is_empty() { s("target_file") } else { s("path") };
            let mut input = json!({ "file_path": path });
            for k in ["offset", "limit"] {
                if let Some(v) = args.get(k) {
                    if !v.is_null() {
                        input[k] = v.clone();
                    }
                }
            }
            ("Read".into(), input)
        }
        "grep" | "Grep" | "grep_search" => {
            let mut input = json!({ "pattern": if !s("pattern").is_empty() { s("pattern") } else { s("query") } });
            if !s("path").is_empty() {
                input["path"] = json!(s("path"));
            }
            ("Grep".into(), input)
        }
        "search_replace" => ("Edit".into(), keep(args)),
        "StrReplace" => (
            "Edit".into(),
            json!({ "file_path": s("path"), "old_string": s("old_string"), "new_string": s("new_string") }),
        ),
        "write" => ("Write".into(), keep(args)),
        "Write" => ("Write".into(), json!({ "file_path": s("path"), "content": s("contents") })),
        "list_dir" => ("LS".into(), json!({ "path": s("target_directory") })),
        "Glob" => ("Glob".into(), json!({ "pattern": s("glob_pattern"), "path": s("target_directory") })),
        "todo_write" | "TodoWrite" => ("TodoWrite".into(), keep(args)),
        "web_fetch" | "WebFetch" => ("WebFetch".into(), json!({ "url": s("url") })),
        "WebSearch" => ("WebSearch".into(), json!({ "query": s("search_term") })),
        _ => (name.to_string(), keep(args)),
    }
}

/// Normalize parsed chat_history records (+ the sibling summary) into the renderer's message
/// model. Lines carry no timestamps — session-level times come from summary.json.
pub fn normalize(recs: &[Value], summary: Option<&Value>) -> Norm {
    let mut n = Norm::default();
    let sum = summary.cloned().unwrap_or(Value::Null);
    n.model = sum.get("current_model_id").and_then(|v| v.as_str()).map(|s| s.to_string());
    n.cwd = sum
        .get("info")
        .and_then(|i| i.get("cwd"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    n.session_id = sum
        .get("info")
        .and_then(|i| i.get("id"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    n.git_branch = sum.get("head_branch").and_then(|v| v.as_str()).map(|s| s.to_string());
    n.first_ts = sum.get("created_at").and_then(|v| v.as_str()).map(|s| s.to_string());
    n.last_ts = sum
        .get("last_active_at")
        .or_else(|| sum.get("updated_at"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    for rec in recs {
        let ty = rec.get("type").and_then(|v| v.as_str()).unwrap_or("");
        match ty {
            "user" => {
                let mut blocks: Vec<Value> = vec![];
                if let Some(arr) = rec.get("content").and_then(|c| c.as_array()) {
                    for b in arr {
                        match b.get("type").and_then(|t| t.as_str()).unwrap_or("") {
                            "text" => {
                                let raw = b.get("text").and_then(|t| t.as_str()).unwrap_or("");
                                if is_meta_user_text(raw) && !raw.contains("<user_query>") {
                                    continue;
                                }
                                let text = unwrap_user_query(raw);
                                if !text.is_empty() {
                                    blocks.push(json!({ "type": "text", "text": text }));
                                }
                            }
                            "image" => {
                                if let Some(img) =
                                    b.get("url").and_then(|u| u.as_str()).and_then(image_block)
                                {
                                    blocks.push(img);
                                }
                            }
                            _ => {}
                        }
                    }
                } else if let Some(t) = rec.get("content").and_then(|c| c.as_str()) {
                    let text = unwrap_user_query(t);
                    if !text.is_empty() && !is_meta_user_text(t) {
                        blocks.push(json!({ "type": "text", "text": text }));
                    }
                }
                if !blocks.is_empty() {
                    n.messages.push(json!({ "role": "user", "content": blocks }));
                }
            }
            "reasoning" => {
                let txt = rec
                    .get("summary")
                    .and_then(|s| s.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
                            .collect::<Vec<_>>()
                            .join("\n")
                    })
                    .unwrap_or_default();
                if !txt.trim().is_empty() {
                    let mut m = json!({ "role": "assistant", "content": [{ "type": "thinking", "thinking": txt }] });
                    if let Some(md) = &n.model {
                        m["modelActual"] = json!(md);
                    }
                    n.messages.push(m);
                }
            }
            "assistant" => {
                let mut blocks: Vec<Value> = vec![];
                let text = rec.get("content").and_then(|c| c.as_str()).unwrap_or("");
                if !text.trim().is_empty() {
                    blocks.push(json!({ "type": "text", "text": text }));
                }
                if let Some(calls) = rec.get("tool_calls").and_then(|c| c.as_array()) {
                    for call in calls {
                        let name = call.get("name").and_then(|v| v.as_str()).unwrap_or("tool");
                        let args: Value = call
                            .get("arguments")
                            .and_then(|v| v.as_str())
                            .and_then(|s| serde_json::from_str(s).ok())
                            .unwrap_or_else(|| call.get("arguments").cloned().unwrap_or(json!({})));
                        let (tname, input) = map_tool(name, &args);
                        let id = call.get("id").and_then(|v| v.as_str()).unwrap_or("");
                        blocks.push(json!({ "type": "tool_use", "id": id, "name": tname, "input": input }));
                    }
                }
                if !blocks.is_empty() {
                    let mut m = json!({ "role": "assistant", "content": blocks });
                    if let Some(md) = &n.model {
                        m["modelActual"] = json!(md);
                    }
                    n.messages.push(m);
                }
            }
            "tool_result" => {
                let id = rec.get("tool_call_id").and_then(|v| v.as_str()).unwrap_or("");
                let text = rec.get("content").and_then(|c| c.as_str()).unwrap_or("").to_string();
                let images: Vec<Value> = rec
                    .get("images")
                    .and_then(|a| a.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|b| b.get("url").and_then(|u| u.as_str()).and_then(image_block))
                            .collect()
                    })
                    .unwrap_or_default();
                let content: Value = if images.is_empty() {
                    json!(text)
                } else {
                    let mut blocks = vec![json!({ "type": "text", "text": text })];
                    blocks.extend(images);
                    json!(blocks)
                };
                n.messages
                    .push(json!({ "role": "user", "content": [{ "type": "tool_result", "tool_use_id": id, "content": content }] }));
            }
            _ => {} // system / unknown: harness plumbing, not conversation
        }
    }
    n
}
