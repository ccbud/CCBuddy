// OpenAI Responses RESPONSE → IR (provider side: parsing what a Responses upstream returned).

use llm_connector::core::Protocol;
use llm_connector::protocols::adapters::openai::OpenAIProtocol;
use llm_connector::types::ChatResponse;
use serde_json::{json, Value};

/// OpenAI Responses RESPONSE (buffered) → IR. We reshape the Responses reply into an OpenAI Chat
/// completion and let the crate's parse_response build the IR — reusing its battle-tested mapping.
pub fn decode_response(text: &str) -> Result<ChatResponse, String> {
    let v: Value = serde_json::from_str(text).map_err(|e| format!("responses parse: {}", e))?;
    if v.get("status").and_then(Value::as_str) == Some("failed") {
        let message = v
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("upstream Responses request failed");
        return Err(message.to_string());
    }
    let output = v
        .get("output")
        .and_then(|o| o.as_array())
        .cloned()
        .unwrap_or_default();

    let mut content = String::new();
    let mut tool_calls: Vec<Value> = vec![];
    let mut had_tool = false;
    for item in &output {
        match item.get("type").and_then(|t| t.as_str()) {
            Some("message") => {
                if let Some(cs) = item.get("content").and_then(|c| c.as_array()) {
                    for c in cs {
                        if let Some(t) = c.get("text").and_then(|v| v.as_str()) {
                            content.push_str(t);
                        }
                    }
                }
            }
            Some("function_call") => {
                had_tool = true;
                tool_calls.push(json!({
                    "id": item.get("call_id").or_else(|| item.get("id")).cloned().unwrap_or(json!("")),
                    "type": "function",
                    "function": {
                        "name": item.get("name").cloned().unwrap_or(json!("")),
                        "arguments": item.get("arguments").and_then(|v| v.as_str()).unwrap_or("{}"),
                    }
                }));
            }
            _ => {}
        }
    }
    // fall back to the flattened output_text if no message items carried content
    if content.is_empty() {
        if let Some(t) = v.get("output_text").and_then(|v| v.as_str()) {
            content = t.to_string();
        }
    }

    let usage = v.get("usage").cloned().unwrap_or(json!({}));
    let mut message = json!({ "role": "assistant", "content": content });
    if !tool_calls.is_empty() {
        message["tool_calls"] = json!(tool_calls);
    }
    let finish_reason = if v.get("status").and_then(Value::as_str) == Some("incomplete") {
        match v
            .pointer("/incomplete_details/reason")
            .and_then(Value::as_str)
        {
            Some("content_filter") => "content_filter",
            _ => "length",
        }
    } else if had_tool {
        "tool_calls"
    } else {
        "stop"
    };
    let chat = json!({
        "id": v.get("id").cloned().unwrap_or(json!("resp")),
        "object": "chat.completion",
        "created": 0,
        "model": v.get("model").cloned().unwrap_or(json!("")),
        "choices": [{ "index": 0, "finish_reason": finish_reason, "message": message }],
        "usage": {
            "prompt_tokens": usage.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
            "completion_tokens": usage.get("output_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
            "total_tokens": usage.get("total_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        }
    });
    OpenAIProtocol::new("")
        .parse_response(&chat.to_string())
        .map_err(|e| e.to_string())
}
