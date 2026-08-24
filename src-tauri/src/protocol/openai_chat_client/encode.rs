// llm-connector ChatResponse IR → Chat Completions RESPONSE json, buffered and as SSE.

use llm_connector::types::ChatResponse;
use serde_json::{json, Value};

/// IR ChatResponse → OpenAI Chat Completions RESPONSE json.
pub fn encode_response(resp: &ChatResponse, client_model: &str) -> Value {
    let choice = resp.choices.first();
    let msg = choice.map(|c| &c.message);
    let text = {
        let t = msg.map(|m| m.content_as_text()).unwrap_or_default();
        if t.is_empty() {
            resp.content.clone()
        } else {
            t
        }
    };
    let mut message = json!({ "role": "assistant", "content": if text.is_empty() { Value::Null } else { json!(text) } });
    // Normalize the finish reason to OpenAI vocabulary (the IR may carry an Anthropic stop_reason
    // when the upstream was Anthropic).
    let mut finish = match choice.and_then(|c| c.finish_reason.as_deref()) {
        Some("end_turn") | Some("stop") | None => "stop",
        Some("max_tokens") | Some("length") => "length",
        Some("tool_use") | Some("tool_calls") => "tool_calls",
        Some(other) => other,
    }
    .to_string();
    if let Some(m) = msg {
        if let Some(calls) = &m.tool_calls {
            if !calls.is_empty() {
                let tcs: Vec<Value> = calls
                    .iter()
                    .enumerate()
                    .map(|(i, tc)| json!({
                        "index": i,
                        "id": if tc.id.is_empty() { format!("call_{}", i) } else { tc.id.clone() },
                        "type": "function",
                        "function": { "name": tc.function.name, "arguments": tc.function.arguments },
                    }))
                    .collect();
                message["tool_calls"] = json!(tcs);
                finish = "tool_calls".to_string();
            }
        }
    }
    let usage = resp.usage.as_ref();
    json!({
        // never a constant fallback — clients persist this id and usage de-dupes by it
        "id": if resp.id.is_empty() { crate::protocol::uid("chatcmpl-ccbud") } else { resp.id.clone() },
        "object": "chat.completion",
        "created": 0,
        "model": client_model,
        "choices": [{ "index": 0, "finish_reason": finish, "message": message }],
        "usage": {
            "prompt_tokens": usage.map(|u| u.prompt_tokens).unwrap_or(0),
            "completion_tokens": usage.map(|u| u.completion_tokens).unwrap_or(0),
            "total_tokens": usage.map(|u| u.total_tokens).unwrap_or(0),
        }
    })
}

/// IR ChatResponse → OpenAI Chat SSE stream (buffered synthesize: role chunk, content chunk(s),
/// tool_call chunk(s), final finish chunk, `[DONE]`).
pub fn encode_response_sse(resp: &ChatResponse, client_model: &str) -> String {
    let full = encode_response(resp, client_model);
    let choice = &full["choices"][0];
    let message = &choice["message"];
    let finish = choice
        .get("finish_reason")
        .and_then(|v| v.as_str())
        .unwrap_or("stop");
    let id = full.get("id").cloned().unwrap_or(json!("chatcmpl-ccbud"));
    let chunk = |delta: Value, fin: Value| {
        format!(
            "data: {}\n\n",
            serde_json::to_string(&json!({
                "id": id, "object": "chat.completion.chunk", "created": 0, "model": client_model,
                "choices": [{ "index": 0, "delta": delta, "finish_reason": fin }],
            }))
            .unwrap_or_default()
        )
    };
    let mut out = String::new();
    out.push_str(&chunk(json!({ "role": "assistant" }), Value::Null));
    if let Some(t) = message.get("content").and_then(|v| v.as_str()) {
        if !t.is_empty() {
            out.push_str(&chunk(json!({ "content": t }), Value::Null));
        }
    }
    if let Some(tcs) = message.get("tool_calls").and_then(|v| v.as_array()) {
        out.push_str(&chunk(json!({ "tool_calls": tcs }), Value::Null));
    }
    out.push_str(&chunk(json!({}), json!(finish)));
    out.push_str("data: [DONE]\n\n");
    out
}
