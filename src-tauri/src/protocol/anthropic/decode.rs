// Anthropic Messages REQUEST json → llm-connector ChatRequest IR.

use super::blocks::{blocks_text, image_blocks, system_message, tool_result_messages, tool_use_calls, tools};
use llm_connector::types::{ChatRequest, Message, MessageBlock, Role};
use serde_json::Value;

/// Decode an Anthropic Messages REQUEST json into the llm-connector IR. `model` is left as the
/// request's model (gateway.rs already rewrote it to the provider's outgoing model before this).
pub fn decode_request(req: &Value) -> Result<ChatRequest, String> {
    let model = req.get("model").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let mut messages: Vec<Message> = vec![];

    if let Some(sys) = system_message(req) {
        messages.push(sys);
    }

    let turns = req.get("messages").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    for m in &turns {
        let role = m.get("role").and_then(|v| v.as_str()).unwrap_or("user");
        let content = m.get("content").cloned().unwrap_or(Value::Null);
        match role {
            "assistant" => {
                // assistant turn: text (+ optional thinking) + tool_use → tool_calls
                let mut blocks: Vec<MessageBlock> = vec![];
                let text = blocks_text(&content);
                if !text.is_empty() {
                    blocks.push(MessageBlock::text(text));
                }
                let calls = tool_use_calls(&content);
                let mut msg = Message::new(Role::Assistant, blocks);
                if !calls.is_empty() {
                    msg.tool_calls = Some(calls);
                }
                messages.push(msg);
            }
            _ => {
                // user turn: tool_result blocks split off into their own tool messages FIRST
                // (they answer the prior assistant tool_calls), then any remaining text/images.
                for tm in tool_result_messages(&content) {
                    messages.push(tm);
                }
                let mut blocks: Vec<MessageBlock> = vec![];
                let text = blocks_text(&content);
                if !text.is_empty() {
                    blocks.push(MessageBlock::text(text));
                }
                blocks.extend(image_blocks(&content));
                if !blocks.is_empty() {
                    messages.push(Message::new(Role::User, blocks));
                }
            }
        }
    }

    let mut cr = ChatRequest::new(model).with_messages(messages);
    if let Some(mt) = req.get("max_tokens").and_then(|v| v.as_u64()) {
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
    if let Some(stop) = req.get("stop_sequences").and_then(|v| v.as_array()) {
        let v: Vec<String> = stop.iter().filter_map(|s| s.as_str().map(|x| x.to_string())).collect();
        if !v.is_empty() {
            cr = cr.with_stop(v);
        }
    }
    if let Some(ts) = tools(req) {
        cr = cr.with_tools(ts);
    }
    // Anthropic extended thinking → IR thinking budget (+ enable). Downstream OpenAI-chat drops it;
    // Responses maps the budget to reasoning.effort (handled in the responses codec).
    if let Some(th) = req.get("thinking") {
        let enabled = th.get("type").and_then(|v| v.as_str()) == Some("enabled");
        if enabled {
            cr = cr.with_enable_thinking(true);
            if let Some(b) = th.get("budget_tokens").and_then(|v| v.as_u64()) {
                cr = cr.with_thinking_budget(b as u32);
            }
        }
    }

    Ok(cr)
}
