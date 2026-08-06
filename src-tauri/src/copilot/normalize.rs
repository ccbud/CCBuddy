// Event log → history::Norm: tool-name mapping onto the renderer's native vocabulary, then
// the per-line walk that builds the message timeline.

use crate::history::Norm;
use serde_json::{json, Value};

/// Copilot tool name + arguments (already an object) → (renderer tool name, renderer input).
fn map_tool(name: &str, args: &Value) -> (String, Value) {
    let s = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let keep = |v: &Value| if v.is_object() { v.clone() } else { json!({}) };
    match name {
        "bash" => {
            let mut input = json!({ "command": s("command") });
            if !s("description").is_empty() {
                input["description"] = json!(s("description"));
            }
            ("Bash".into(), input)
        }
        "view" => ("Read".into(), json!({ "file_path": s("path") })),
        "edit" | "str_replace" => (
            "Edit".into(),
            json!({ "file_path": s("path"), "old_string": s("old_str"), "new_string": s("new_str") }),
        ),
        "create" => ("Write".into(), json!({ "file_path": s("path"), "content": s("file_text") })),
        "rg" => {
            let mut input = json!({ "pattern": s("pattern") });
            if let Some(p) = args.get("paths") {
                input["path"] = if p.is_array() {
                    json!(p.as_array().unwrap().iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(" "))
                } else {
                    p.clone()
                };
            }
            if !s("glob").is_empty() {
                input["glob"] = json!(s("glob"));
            }
            ("Grep".into(), input)
        }
        "glob" => ("Glob".into(), json!({ "pattern": s("pattern"), "path": s("paths") })),
        "apply_patch" => ("ApplyPatch".into(), json!({ "patch": s("str") })),
        _ => (name.to_string(), keep(args)),
    }
}

/// Normalize parsed event records into the renderer's message model.
pub fn normalize(recs: &[Value]) -> Norm {
    let mut n = Norm::default();
    for rec in recs {
        let ty = rec.get("type").and_then(|v| v.as_str()).unwrap_or("");
        let data = rec.get("data").cloned().unwrap_or(Value::Null);
        let ts = rec.get("timestamp").and_then(|v| v.as_str());
        let with_ts = |mut m: Value| {
            if let Some(t) = ts {
                m["ts"] = json!(t);
            }
            m
        };
        match ty {
            "session.start" => {
                if n.session_id.is_none() {
                    n.session_id = data.get("sessionId").and_then(|v| v.as_str()).map(|s| s.to_string());
                }
                if n.version.is_none() {
                    n.version = data.get("copilotVersion").and_then(|v| v.as_str()).map(|s| s.to_string());
                }
                if n.cwd.is_none() {
                    n.cwd = data
                        .get("context")
                        .and_then(|c| c.get("cwd"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());
                }
                if n.git_branch.is_none() {
                    n.git_branch = data
                        .get("context")
                        .and_then(|c| c.get("branch"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());
                }
            }
            "session.model_change" => {
                if let Some(m) = data.get("newModel").and_then(|v| v.as_str()) {
                    n.model = Some(m.to_string());
                }
            }
            "user.message" => {
                let text = data.get("content").and_then(|v| v.as_str()).unwrap_or("");
                if !text.trim().is_empty() {
                    n.messages
                        .push(with_ts(json!({ "role": "user", "content": [{ "type": "text", "text": text }] })));
                }
            }
            "assistant.message" => {
                if let Some(m) = data.get("model").and_then(|v| v.as_str()) {
                    n.model = Some(m.to_string());
                }
                let mut blocks: Vec<Value> = vec![];
                let text = data.get("content").and_then(|v| v.as_str()).unwrap_or("");
                if !text.trim().is_empty() {
                    blocks.push(json!({ "type": "text", "text": text }));
                }
                if let Some(calls) = data.get("toolRequests").and_then(|c| c.as_array()) {
                    for call in calls {
                        let name = call.get("name").and_then(|v| v.as_str()).unwrap_or("tool");
                        let args = call.get("arguments").cloned().unwrap_or(json!({}));
                        let (tname, input) = map_tool(name, &args);
                        let id = call.get("toolCallId").and_then(|v| v.as_str()).unwrap_or("");
                        blocks.push(json!({ "type": "tool_use", "id": id, "name": tname, "input": input }));
                    }
                }
                if !blocks.is_empty() {
                    let mut m = json!({ "role": "assistant", "content": blocks });
                    if let Some(md) = &n.model {
                        m["modelActual"] = json!(md);
                    }
                    n.messages.push(with_ts(m));
                }
            }
            "tool.execution_complete" => {
                let id = data.get("toolCallId").and_then(|v| v.as_str()).unwrap_or("");
                let text = data
                    .get("result")
                    .and_then(|r| r.get("content"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let mut tr = json!({ "type": "tool_result", "tool_use_id": id, "content": text });
                if data.get("success").and_then(|v| v.as_bool()) == Some(false) {
                    tr["is_error"] = json!(true);
                }
                n.messages.push(with_ts(json!({ "role": "user", "content": [tr] })));
            }
            _ => {} // session.info / system.* / turn markers / execution_start: harness plumbing
        }
    }
    n.first_ts = n.messages.first().and_then(|m| m.get("ts")).and_then(|v| v.as_str()).map(|s| s.to_string());
    n.last_ts = n.messages.last().and_then(|m| m.get("ts")).and_then(|v| v.as_str()).map(|s| s.to_string());
    n
}
