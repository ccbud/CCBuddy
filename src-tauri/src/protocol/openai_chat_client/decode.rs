// Chat Completions REQUEST json → llm-connector ChatRequest IR.

use llm_connector::types::{
    ChatRequest, FunctionCall, Message, MessageBlock, Role, Tool, ToolCall,
};
use serde_json::{json, Value};

fn content_to_blocks(content: &Value) -> Vec<MessageBlock> {
    if let Some(s) = content.as_str() {
        return if s.is_empty() {
            vec![]
        } else {
            vec![MessageBlock::text(s)]
        };
    }
    let arr = match content.as_array() {
        Some(a) => a,
        None => return vec![],
    };
    let mut out = vec![];
    for part in arr {
        match part.get("type").and_then(|t| t.as_str()) {
            Some("text") => {
                if let Some(t) = part.get("text").and_then(|v| v.as_str()) {
                    out.push(MessageBlock::text(t));
                }
            }
            Some("image_url") => {
                if let Some(u) = part
                    .get("image_url")
                    .and_then(|i| i.get("url"))
                    .and_then(|v| v.as_str())
                {
                    out.push(MessageBlock::image_url(u));
                }
            }
            _ => {}
        }
    }
    out
}

/// Decode an OpenAI Chat Completions REQUEST json into the IR.
pub fn decode_request(req: &Value) -> Result<ChatRequest, String> {
    let model = req
        .get("model")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let mut messages: Vec<Message> = vec![];
    for m in req
        .get("messages")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
        .iter()
    {
        let role = match m.get("role").and_then(|v| v.as_str()) {
            Some("system") | Some("developer") => Role::System,
            Some("assistant") => Role::Assistant,
            Some("tool") => Role::Tool,
            _ => Role::User,
        };
        let content = m.get("content").cloned().unwrap_or(Value::Null);
        let mut msg = Message::new(role, content_to_blocks(&content));
        if let Some(name) = m.get("name").and_then(|v| v.as_str()) {
            msg.name = Some(name.to_string());
        }
        if let Some(tcid) = m.get("tool_call_id").and_then(|v| v.as_str()) {
            msg.tool_call_id = Some(tcid.to_string());
        }
        if let Some(tcs) = m.get("tool_calls").and_then(|v| v.as_array()) {
            let calls: Vec<ToolCall> = tcs
                .iter()
                .map(|tc| ToolCall {
                    id: tc
                        .get("id")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                    call_type: "function".to_string(),
                    function: FunctionCall {
                        name: tc
                            .get("function")
                            .and_then(|f| f.get("name"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string(),
                        arguments: tc
                            .get("function")
                            .and_then(|f| f.get("arguments"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("{}")
                            .to_string(),
                        thought_signature: None,
                    },
                    index: None,
                    thought_signature: None,
                })
                .collect();
            if !calls.is_empty() {
                msg.tool_calls = Some(calls);
            }
        }
        messages.push(msg);
    }

    let mut cr = ChatRequest::new(model).with_messages(messages);
    if let Some(mt) = req.get("max_tokens").and_then(|v| v.as_u64()) {
        cr = cr.with_max_tokens(mt as u32);
    }
    if let Some(mt) = req.get("max_completion_tokens").and_then(|v| v.as_u64()) {
        cr = cr.with_max_tokens(mt as u32);
    }
    if let Some(t) = req.get("temperature").and_then(|v| v.as_f64()) {
        cr = cr.with_temperature(t as f32);
    }
    if let Some(p) = req.get("top_p").and_then(|v| v.as_f64()) {
        cr = cr.with_top_p(p as f32);
    }
    if req.get("stream").and_then(|v| v.as_bool()).unwrap_or(false) {
        cr = cr.with_stream(true);
    }
    if let Some(tools) = req.get("tools").and_then(|v| v.as_array()) {
        let ts: Vec<Tool> = tools
            .iter()
            .filter_map(|t| {
                let f = t.get("function")?;
                let name = f.get("name").and_then(|v| v.as_str())?;
                let desc = f
                    .get("description")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                let params = f
                    .get("parameters")
                    .cloned()
                    .unwrap_or_else(|| json!({ "type": "object" }));
                Some(Tool::function(name, desc, params))
            })
            .collect();
        if !ts.is_empty() {
            cr = cr.with_tools(ts);
        }
    }
    Ok(cr)
}
