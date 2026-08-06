// OpenAI Responses REQUEST → IR (client side: what Codex sends the gateway with
// wire_api="responses").

use super::helpers::{effort_to_budget, effort_to_reasoning_effort};
use super::history::{append_history_tool_call, response_history_tool_call, response_tool_output_text};
use super::parts::{
    append_reasoning_content, parts_images, parts_text, reasoning_item_text, response_item_call_id,
};
use super::tools::CodexToolContext;
use super::validate::validate_call_output_pairs;
use llm_connector::types::{ChatRequest, Message, MessageBlock, Role, ToolChoice};
use serde_json::Value;

/// Decode an OpenAI Responses REQUEST json (what Codex sends with wire_api="responses") into the
/// IR. Handles the full item vocabulary of an agentic history: message items (user input_text /
/// input_image, assistant output_text), all client-executed tool call/output item types, and `reasoning`
/// items — whose text is bridged onto the adjacent assistant message as `reasoning_content`,
/// because thinking chat upstreams (Kimi/Moonshot, DeepSeek, …) reject assistant tool-call
/// history that lost its reasoning. System/developer items collapse into ONE leading system
/// message: strict providers (MiniMax) reject `role:system` anywhere but the head. Custom,
/// tool-search, and namespace tools are flattened to chat functions and restored with the returned
/// [`CodexToolContext`].
pub fn decode_request(req: &Value) -> Result<ChatRequest, String> {
    decode_request_with_context(req).map(|(request, _)| request)
}

pub fn decode_request_with_context(req: &Value) -> Result<(ChatRequest, CodexToolContext), String> {
    validate_call_output_pairs(req)?;
    let model = req
        .get("model")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let tool_context = CodexToolContext::from_request(req);
    let mut messages: Vec<Message> = vec![];
    // All system text (instructions + system/developer message items), merged to the head.
    let mut system_texts: Vec<String> = vec![];
    // Reasoning waiting for the assistant message it belongs to (model output order is
    // reasoning → prose → tool calls, so reasoning usually precedes its assistant message).
    let mut pending_reasoning: Option<String> = None;

    if let Some(instr) = req.get("instructions").and_then(|v| v.as_str()) {
        if !instr.trim().is_empty() {
            system_texts.push(instr.to_string());
        }
    }

    match req.get("input") {
        Some(Value::String(s)) => {
            if !s.is_empty() {
                messages.push(Message::text(Role::User, s.clone()));
            }
        }
        Some(Value::Array(items)) => {
            for item in items {
                // Bare `{role, content}` items (no "type") are legal Responses input; treat them
                // as message items.
                let ty = item.get("type").and_then(|v| v.as_str()).unwrap_or(
                    if item.get("role").is_some() {
                        "message"
                    } else {
                        ""
                    },
                );
                match ty {
                    "message" => {
                        let role = item.get("role").and_then(|v| v.as_str()).unwrap_or("user");
                        let content = item.get("content").cloned().unwrap_or(Value::Null);
                        let text = parts_text(&content);
                        match role {
                            "assistant" => {
                                if !text.is_empty() {
                                    let mut m = Message::text(Role::Assistant, text);
                                    if let Some(r) = pending_reasoning.take() {
                                        append_reasoning_content(&mut m, &r);
                                    }
                                    messages.push(m);
                                }
                            }
                            "system" | "developer" => {
                                pending_reasoning = None;
                                if !text.trim().is_empty() {
                                    system_texts.push(text);
                                }
                            }
                            _ => {
                                pending_reasoning = None;
                                let mut blocks: Vec<MessageBlock> = vec![];
                                if !text.is_empty() {
                                    blocks.push(MessageBlock::text(text));
                                }
                                blocks.extend(parts_images(&content));
                                if !blocks.is_empty() {
                                    messages.push(Message::new(Role::User, blocks));
                                }
                            }
                        }
                    }
                    "reasoning" => {
                        // Belongs to the assistant step it neighbors: fold backward onto a
                        // directly preceding assistant message, else hold for the next one.
                        if let Some(text) = reasoning_item_text(item) {
                            match messages.last_mut() {
                                Some(m) if m.role == Role::Assistant => {
                                    append_reasoning_content(m, &text)
                                }
                                _ => match &mut pending_reasoning {
                                    Some(existing) if !existing.is_empty() => {
                                        existing.push_str("\n\n");
                                        existing.push_str(text.trim());
                                    }
                                    slot => *slot = Some(text.trim().to_string()),
                                },
                            }
                        }
                    }
                    "function_call" | "custom_tool_call" | "tool_search_call" => {
                        if let Some(call) = response_history_tool_call(item, &tool_context) {
                            let item_reasoning = item
                                .get("reasoning_content")
                                .or_else(|| item.get("reasoning"))
                                .and_then(Value::as_str);
                            append_history_tool_call(
                                &mut messages,
                                &mut pending_reasoning,
                                item_reasoning,
                                call,
                            );
                        }
                    }
                    "function_call_output" | "custom_tool_call_output" | "tool_search_output" => {
                        pending_reasoning = None;
                        let id = response_item_call_id(item).unwrap_or("").to_string();
                        if !id.is_empty() {
                            messages.push(Message::tool(response_tool_output_text(item), id));
                        }
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }

    if !system_texts.is_empty() {
        messages.insert(0, Message::text(Role::System, system_texts.join("\n\n")));
    }

    let mut cr = ChatRequest::new(model).with_messages(messages);
    if let Some(mt) = req.get("max_output_tokens").and_then(|v| v.as_u64()) {
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
    let tools = tool_context.ir_tools();
    if !tools.is_empty() {
        cr = cr.with_tools(tools);
    }
    // tool_choice: mode strings pass through; both the flattened Responses object form
    // ({type:"function",name}) and the nested Chat form pin a specific function.
    if let Some(tc) = req.get("tool_choice") {
        if let Some(mode) = tc.as_str() {
            if matches!(mode, "auto" | "none" | "required") {
                cr.tool_choice = Some(ToolChoice::Mode(mode.to_string()));
            }
        } else if let Some(kind) = tc.get("type").and_then(Value::as_str) {
            let selected = match kind {
                "function" => tc
                    .get("name")
                    .and_then(Value::as_str)
                    .or_else(|| {
                        tc.get("function")
                            .and_then(|f| f.get("name"))
                            .and_then(Value::as_str)
                    })
                    .map(|name| {
                        tool_context.chat_name_for_response_tool(
                            name,
                            tc.get("namespace").and_then(Value::as_str),
                        )
                    }),
                "custom" => tc
                    .get("name")
                    .and_then(Value::as_str)
                    .map(|name| tool_context.chat_name_for_custom_tool(name)),
                "tool_search" => Some(tool_context.chat_name_for_tool_search()),
                _ => None,
            };
            if let Some(name) = selected {
                cr.tool_choice = Some(ToolChoice::function(name));
            }
        }
    }
    // Preserve both representations: Anthropic-family encoders consume the thinking budget,
    // while OpenAI-compatible Chat encoders consume reasoning_effort. Higher Responses tiers do
    // not exist in the connector enum, so xhigh/max/ultra intentionally collapse to High there.
    if let Some(effort) = req
        .get("reasoning")
        .and_then(|r| r.get("effort"))
        .and_then(|v| v.as_str())
    {
        cr = cr
            .with_enable_thinking(true)
            .with_thinking_budget(effort_to_budget(effort))
            .with_reasoning_effort(effort_to_reasoning_effort(effort));
    }
    Ok((cr, tool_context))
}
