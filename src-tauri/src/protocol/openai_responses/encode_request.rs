// IR → OpenAI Responses REQUEST (provider side: the gateway talking to a Responses upstream).

use super::helpers::budget_to_effort;
use llm_connector::types::{ChatRequest, Role};
use serde_json::{json, Value};

/// IR (ChatRequest) → OpenAI Responses request BODY. `outgoing_model` is the provider's real model.
pub fn encode_request(ir: &ChatRequest, outgoing_model: &str, stream: bool) -> Value {
    let mut instructions: Option<String> = None;
    let mut input: Vec<Value> = vec![];

    for m in &ir.messages {
        match m.role {
            Role::System => {
                // Responses carries the system prompt in `instructions`, not the input array.
                let t = m.content_as_text();
                if !t.trim().is_empty() {
                    instructions = Some(match instructions.take() {
                        Some(prev) => format!("{}\n{}", prev, t),
                        None => t,
                    });
                }
            }
            Role::Tool => {
                // a tool result → function_call_output item
                input.push(json!({
                    "type": "function_call_output",
                    "call_id": m.tool_call_id.clone().unwrap_or_default(),
                    "output": m.content_as_text(),
                }));
            }
            Role::User => {
                let text = m.content_as_text();
                let mut content: Vec<Value> = vec![];
                if !text.is_empty() {
                    content.push(json!({ "type": "input_text", "text": text }));
                }
                for b64 in m.content_as_images_base64() {
                    content.push(json!({ "type": "input_image", "image_url": format!("data:image/png;base64,{}", b64) }));
                }
                if !content.is_empty() {
                    input.push(json!({ "type": "message", "role": "user", "content": content }));
                }
            }
            Role::Assistant => {
                let text = m.content_as_text();
                if !text.is_empty() {
                    input.push(json!({ "type": "message", "role": "assistant",
                        "content": [{ "type": "output_text", "text": text }] }));
                }
                if let Some(calls) = &m.tool_calls {
                    for tc in calls {
                        input.push(json!({
                            "type": "function_call",
                            "call_id": tc.id,
                            "name": tc.function.name,
                            "arguments": tc.function.arguments,
                        }));
                    }
                }
            }
        }
    }

    let mut body = json!({
        "model": outgoing_model,
        "input": input,
        "stream": stream,
    });
    if let Some(instr) = instructions {
        body["instructions"] = json!(instr);
    }
    if let Some(mt) = ir.max_tokens {
        body["max_output_tokens"] = json!(mt);
    }
    if let Some(t) = ir.temperature {
        body["temperature"] = json!(t);
    }
    if let Some(p) = ir.top_p {
        body["top_p"] = json!(p);
    }
    // tools → Responses function tools (fields flattened at the item level, not nested under
    // "function" like Chat Completions).
    if let Some(tools) = &ir.tools {
        let arr: Vec<Value> = tools
            .iter()
            .map(|t| {
                json!({
                    "type": "function",
                    "name": t.function.name,
                    "description": t.function.description,
                    "parameters": t.function.parameters,
                })
            })
            .collect();
        if !arr.is_empty() {
            body["tools"] = json!(arr);
        }
    }
    // Anthropic extended thinking → Responses reasoning effort.
    if ir.enable_thinking == Some(true) {
        body["reasoning"] = json!({ "effort": budget_to_effort(ir.thinking_budget) });
    }
    body
}
