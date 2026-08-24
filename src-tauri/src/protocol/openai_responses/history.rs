// Turning Responses history items (tool calls and their outputs) into IR assistant/tool messages.

use super::helpers::wrap_custom_tool_input;
use super::parts::{append_reasoning_content, parts_text, response_item_call_id};
use super::tools::CodexToolContext;
use llm_connector::types::{FunctionCall, Message, Role, ToolCall};
use serde_json::{json, Value};

pub(super) fn response_history_tool_call(
    item: &Value,
    context: &CodexToolContext,
) -> Option<ToolCall> {
    let ty = item.get("type").and_then(Value::as_str).unwrap_or("");
    let id = response_item_call_id(item).unwrap_or("").to_string();
    if id.is_empty() {
        return None;
    }
    let (name, arguments) = match ty {
        "function_call" => {
            let original_name = item.get("name").and_then(Value::as_str).unwrap_or("");
            let namespace = item.get("namespace").and_then(Value::as_str);
            let name = context.chat_name_for_response_tool(original_name, namespace);
            let arguments = match item.get("arguments") {
                Some(Value::String(arguments)) => arguments.clone(),
                Some(arguments) if !arguments.is_null() => arguments.to_string(),
                _ => "{}".to_string(),
            };
            (name, arguments)
        }
        "custom_tool_call" => {
            let original_name = item.get("name").and_then(Value::as_str).unwrap_or("");
            let name = context.chat_name_for_custom_tool(original_name);
            let input = item
                .get("input")
                .cloned()
                .unwrap_or(Value::String(String::new()));
            (name, wrap_custom_tool_input(&input))
        }
        "tool_search_call" => {
            let arguments = item
                .get("arguments")
                .map(|value| {
                    if let Some(arguments) = value.as_str() {
                        arguments.to_string()
                    } else {
                        value.to_string()
                    }
                })
                .unwrap_or_else(|| "{}".to_string());
            (context.chat_name_for_tool_search(), arguments)
        }
        _ => return None,
    };
    if name.is_empty() {
        return None;
    }
    Some(ToolCall {
        id,
        call_type: "function".to_string(),
        function: FunctionCall {
            name,
            arguments,
            thought_signature: None,
        },
        index: None,
        thought_signature: None,
    })
}

pub(super) fn append_history_tool_call(
    messages: &mut Vec<Message>,
    pending_reasoning: &mut Option<String>,
    item_reasoning: Option<&str>,
    call: ToolCall,
) {
    // Codex emits a turn's prose and tool calls as sibling items. Fold the calls into the trailing
    // assistant message so Chat/Anthropic upstreams receive one coherent assistant turn.
    match messages.last_mut() {
        Some(message) if message.role == Role::Assistant => {
            if let Some(reasoning) = pending_reasoning.take() {
                append_reasoning_content(message, &reasoning);
            }
            if let Some(reasoning) = item_reasoning {
                append_reasoning_content(message, reasoning);
            }
            message.tool_calls.get_or_insert_with(Vec::new).push(call);
        }
        _ => {
            let mut message = Message::new(Role::Assistant, vec![]);
            if let Some(reasoning) = pending_reasoning.take() {
                append_reasoning_content(&mut message, &reasoning);
            }
            if let Some(reasoning) = item_reasoning {
                append_reasoning_content(&mut message, reasoning);
            }
            message.tool_calls = Some(vec![call]);
            messages.push(message);
        }
    }
}

pub(super) fn response_tool_output_text(item: &Value) -> String {
    if item.get("type").and_then(Value::as_str) == Some("tool_search_output") {
        return json!({
            "status": item.get("status").cloned().unwrap_or(json!("completed")),
            "execution": item.get("execution").cloned().unwrap_or(json!("client")),
            "tools": item.get("tools").cloned().unwrap_or_else(|| json!([])),
        })
        .to_string();
    }
    match item.get("output") {
        Some(Value::String(output)) => output.clone(),
        Some(output @ Value::Array(_)) => {
            let text = parts_text(output);
            if text.is_empty() {
                output.to_string()
            } else {
                text
            }
        }
        Some(Value::Object(object)) => object
            .get("content")
            .map(|content| {
                let text = parts_text(content);
                if text.is_empty() {
                    content.to_string()
                } else {
                    text
                }
            })
            .unwrap_or_else(|| Value::Object(object.clone()).to_string()),
        _ => String::new(),
    }
}
