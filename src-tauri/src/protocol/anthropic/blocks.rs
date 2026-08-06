// Anthropic content blocks → IR pieces. Claude Code sends user/system blocks as
// `{"type":"input_text"}` (not `text`) — recognizing that is load-bearing: missing it silently
// drops content and the upstream answers 422.

use llm_connector::types::{FunctionCall, Message, MessageBlock, Role, Tool, ToolCall};
use serde_json::{json, Value};

/// Pull plain text out of an Anthropic content value (string, or array of text/input_text blocks).
pub(super) fn blocks_text(content: &Value) -> String {
    if let Some(s) = content.as_str() {
        return s.to_string();
    }
    let arr = match content.as_array() {
        Some(a) => a,
        None => return String::new(),
    };
    let mut out: Vec<String> = vec![];
    for b in arr {
        match b.get("type").and_then(|t| t.as_str()) {
            // Claude Code sends `input_text`; the Anthropic API also uses `text`. Accept both.
            Some("text") | Some("input_text") => {
                if let Some(t) = b.get("text").and_then(|t| t.as_str()) {
                    out.push(t.to_string());
                }
            }
            _ => {}
        }
    }
    out.join("\n")
}

/// Image blocks in an Anthropic content array → IR image blocks (base64 or url).
pub(super) fn image_blocks(content: &Value) -> Vec<MessageBlock> {
    let arr = match content.as_array() {
        Some(a) => a,
        None => return vec![],
    };
    let mut out = vec![];
    for b in arr {
        if b.get("type").and_then(|t| t.as_str()) != Some("image") {
            continue;
        }
        let src = b.get("source").cloned().unwrap_or(Value::Null);
        match src.get("type").and_then(|t| t.as_str()) {
            Some("base64") => {
                let mt = src.get("media_type").and_then(|v| v.as_str()).unwrap_or("image/png");
                let data = src.get("data").and_then(|v| v.as_str()).unwrap_or("");
                if !data.is_empty() {
                    out.push(MessageBlock::image_base64(mt, data));
                }
            }
            Some("url") => {
                if let Some(u) = src.get("url").and_then(|v| v.as_str()) {
                    out.push(MessageBlock::image_url_anthropic(u));
                }
            }
            _ => {}
        }
    }
    out
}

/// tool_result blocks in a user turn → their own `role:tool` IR messages (OpenAI shape). Anthropic
/// nests tool results inside a user message; OpenAI wants each as a standalone tool message.
pub(super) fn tool_result_messages(content: &Value) -> Vec<Message> {
    let arr = match content.as_array() {
        Some(a) => a,
        None => return vec![],
    };
    let mut out = vec![];
    for b in arr {
        if b.get("type").and_then(|t| t.as_str()) != Some("tool_result") {
            continue;
        }
        let id = b.get("tool_use_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
        // tool_result content is a string or an array of text blocks.
        let text = match b.get("content") {
            Some(Value::String(s)) => s.clone(),
            Some(c @ Value::Array(_)) => blocks_text(c),
            _ => String::new(),
        };
        out.push(Message::tool(text, id));
    }
    out
}

/// tool_use blocks in an assistant turn → IR ToolCalls (OpenAI function-call shape).
pub(super) fn tool_use_calls(content: &Value) -> Vec<ToolCall> {
    let arr = match content.as_array() {
        Some(a) => a,
        None => return vec![],
    };
    let mut out = vec![];
    for b in arr {
        if b.get("type").and_then(|t| t.as_str()) != Some("tool_use") {
            continue;
        }
        let id = b.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let name = b.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let args = b.get("input").cloned().unwrap_or_else(|| json!({}));
        out.push(ToolCall {
            id,
            call_type: "function".to_string(),
            function: FunctionCall {
                name,
                arguments: serde_json::to_string(&args).unwrap_or_else(|_| "{}".to_string()),
                thought_signature: None,
            },
            index: None,
            thought_signature: None,
        });
    }
    out
}

/// Anthropic `system` (string or array of text blocks) → a leading system Message.
pub(super) fn system_message(req: &Value) -> Option<Message> {
    let sys = req.get("system")?;
    let text = if sys.is_string() { sys.as_str().unwrap_or("").to_string() } else { blocks_text(sys) };
    let text = text.trim();
    if text.is_empty() {
        None
    } else {
        Some(Message::text(Role::System, text))
    }
}

/// Anthropic `tools` → IR function tools. `input_schema` maps to the function `parameters`.
pub(super) fn tools(req: &Value) -> Option<Vec<Tool>> {
    let arr = req.get("tools").and_then(|v| v.as_array())?;
    let mut out = vec![];
    for t in arr {
        let name = t.get("name").and_then(|v| v.as_str())?;
        let desc = t.get("description").and_then(|v| v.as_str()).map(|s| s.to_string());
        let params = t.get("input_schema").cloned().unwrap_or_else(|| json!({ "type": "object" }));
        out.push(Tool::function(name, desc, params));
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}
