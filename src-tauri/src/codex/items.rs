// normalize()'s "response_item" match arm, moved verbatim out of normalize.rs so both files
// stay under the split's size cap. Called once per record from normalize()'s loop; `return`
// here matches the original `continue` (this match was the loop body's last statement), and
// the `with_ts` closure is duplicated verbatim from that loop.

use crate::history::image_block;
use serde_json::{json, Value};

use super::exec::{exec_text_err, map_exec_script};
use super::records::{is_agents_bootstrap, is_meta_user_text, skill_load_block};
use super::titles::{joined_text, joined_user_text};
use super::tools::{join_argv, map_tool, shape_output};

pub(super) fn on_response_item(p: &Value, ts: Option<&str>, model: &Option<String>, messages: &mut Vec<Value>) {
    let with_ts = |mut m: Value| {
        if let Some(t) = ts {
            m["ts"] = json!(t);
        }
        m
    };
    let it = p.get("type").and_then(|v| v.as_str()).unwrap_or("");
    match it {
        "message" => {
            let role = p.get("role").and_then(|v| v.as_str()).unwrap_or("");
            let content = p.get("content").cloned().unwrap_or(Value::Null);
            if role == "assistant" {
                let text = joined_text(&content, &["output_text", "text"]);
                if !text.trim().is_empty() {
                    let mut m = json!({ "role": "assistant", "content": [{ "type": "text", "text": text }] });
                    if let Some(md) = &model {
                        m["modelActual"] = json!(md);
                    }
                    messages.push(with_ts(m));
                }
            } else if role == "user" {
                let text = joined_user_text(&content);
                if let Some(skill) = skill_load_block(&text) {
                    messages.push(with_ts(json!({
                        "role": "user",
                        "_meta": true,
                        "content": [skill],
                    })));
                    return; // `continue` in the original normalize() loop
                }
                if is_meta_user_text(&text) {
                    return; // `continue` in the original normalize() loop
                }
                let mut blocks: Vec<Value> = vec![];
                if !text.trim().is_empty() {
                    blocks.push(json!({ "type": "text", "text": text }));
                }
                if let Some(arr) = content.as_array() {
                    for b in arr {
                        if b.get("type").and_then(|t| t.as_str()) == Some("input_image") {
                            if let Some(img) = b
                                .get("image_url")
                                .and_then(|u| u.as_str())
                                .and_then(image_block)
                            {
                                blocks.push(img);
                            }
                        }
                    }
                }
                if !blocks.is_empty() {
                    let mut message = json!({ "role": "user", "content": blocks });
                    if is_agents_bootstrap(&text) {
                        message["_meta"] = json!(true);
                    }
                    messages.push(with_ts(message));
                }
            } // system / developer turns: harness plumbing, not conversation
        }
        "reasoning" => {
            let mut txt = joined_text(&p.get("summary").cloned().unwrap_or(Value::Null), &["summary_text", "text"]);
            let extra = joined_text(&p.get("content").cloned().unwrap_or(Value::Null), &["reasoning_text", "text"]);
            if !extra.trim().is_empty() {
                if !txt.trim().is_empty() {
                    txt.push_str("\n\n");
                }
                txt.push_str(&extra);
            }
            if !txt.trim().is_empty() {
                let mut m = json!({ "role": "assistant", "content": [{ "type": "thinking", "thinking": txt }] });
                if let Some(md) = &model {
                    m["modelActual"] = json!(md);
                }
                messages.push(with_ts(m));
            }
        }
        "function_call" => {
            let name = p.get("name").and_then(|v| v.as_str()).unwrap_or("tool");
            let args: Value = p
                .get("arguments")
                .and_then(|v| v.as_str())
                .and_then(|s| serde_json::from_str(s).ok())
                .unwrap_or_else(|| p.get("arguments").cloned().unwrap_or(json!({})));
            let (tname, input) = map_tool(name, &args);
            let id = p
                .get("call_id")
                .or_else(|| p.get("id"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let mut m = json!({
                "role": "assistant",
                "content": [{ "type": "tool_use", "id": id, "name": tname, "input": input }],
            });
            if let Some(md) = &model {
                m["modelActual"] = json!(md);
            }
            messages.push(with_ts(m));
        }
        "local_shell_call" => {
            let cmd = p
                .get("action")
                .and_then(|a| a.get("command"))
                .cloned()
                .unwrap_or(Value::Null);
            let id = p
                .get("call_id")
                .or_else(|| p.get("id"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let mut m = json!({
                "role": "assistant",
                "content": [{ "type": "tool_use", "id": id, "name": "Bash", "input": { "command": join_argv(&cmd) } }],
            });
            if let Some(md) = &model {
                m["modelActual"] = json!(md);
            }
            messages.push(with_ts(m));
        }
        "custom_tool_call" => {
            let name = p.get("name").and_then(|v| v.as_str()).unwrap_or("tool");
            let input_s = p.get("input").and_then(|v| v.as_str()).unwrap_or("");
            let (tname, input) = if name == "apply_patch" {
                ("ApplyPatch".to_string(), json!({ "patch": input_s }))
            } else if name == "exec" {
                map_exec_script(input_s)
            } else {
                (name.to_string(), json!({ "input": input_s }))
            };
            let id = p
                .get("call_id")
                .or_else(|| p.get("id"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let mut m = json!({
                "role": "assistant",
                "content": [{ "type": "tool_use", "id": id, "name": tname, "input": input }],
            });
            if let Some(md) = &model {
                m["modelActual"] = json!(md);
            }
            messages.push(with_ts(m));
        }
        "function_call_output" | "custom_tool_call_output" => {
            let out = p.get("output").cloned().unwrap_or(Value::Null);
            let id = p.get("call_id").and_then(|v| v.as_str()).unwrap_or("");
            // Newer code-mode outputs are block ARRAYS — {input_text} chunks (status
            // header + stdout, concatenated verbatim) plus optional {input_image}
            // screenshots, which become renderer image blocks.
            let (content, err) = if let Some(arr) = out.as_array() {
                let text: String = arr
                    .iter()
                    .filter(|b| {
                        matches!(
                            b.get("type").and_then(|t| t.as_str()),
                            Some("input_text") | Some("output_text") | Some("text")
                        )
                    })
                    .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
                    .collect();
                let images: Vec<Value> = arr
                    .iter()
                    .filter(|b| b.get("type").and_then(|t| t.as_str()) == Some("input_image"))
                    .filter_map(|b| b.get("image_url").and_then(|u| u.as_str()).and_then(image_block))
                    .collect();
                let err = exec_text_err(&text);
                if images.is_empty() {
                    (json!(text), err)
                } else {
                    let mut blocks = vec![json!({ "type": "text", "text": text })];
                    blocks.extend(images);
                    (Value::Array(blocks), err)
                }
            } else {
                let (text, err) = shape_output(&out);
                (json!(text), err)
            };
            let mut tr = json!({ "type": "tool_result", "tool_use_id": id, "content": content });
            if err {
                tr["is_error"] = json!(true);
            }
            messages.push(with_ts(json!({ "role": "user", "content": [tr] })));
        }
        "web_search_call" => {
            let q = p
                .get("action")
                .and_then(|a| a.get("query"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let id = p
                .get("id")
                .or_else(|| p.get("call_id"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let mut m = json!({
                "role": "assistant",
                "content": [{ "type": "tool_use", "id": id, "name": "WebSearch", "input": { "query": q } }],
            });
            if let Some(md) = &model {
                m["modelActual"] = json!(md);
            }
            messages.push(with_ts(m));
        }
        _ => {}
    }
}
