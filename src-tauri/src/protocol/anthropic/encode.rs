// llm-connector ChatResponse IR → Anthropic Messages RESPONSE json, buffered and as SSE.

use llm_connector::types::ChatResponse;
use serde_json::{json, Value};

/// Map an OpenAI/IR finish_reason to an Anthropic stop_reason.
fn stop_reason(finish: Option<&str>, had_tool_calls: bool) -> &'static str {
    match finish {
        Some("length") => "max_tokens",
        Some("tool_calls") | Some("function_call") => "tool_use",
        Some("content_filter") => "end_turn",
        _ if had_tool_calls => "tool_use",
        _ => "end_turn",
    }
}

/// Encode the IR response back into an Anthropic Messages RESPONSE json. `client_model` is the name
/// the client asked for (so Claude Code sees its own model, not the upstream's).
pub fn encode_response(resp: &ChatResponse, client_model: &str) -> Value {
    let choice = resp.choices.first();
    let msg = choice.map(|c| &c.message);

    let mut content: Vec<Value> = vec![];
    // assistant thinking (if the provider surfaced reasoning) → an Anthropic thinking block first.
    if let Some(m) = msg {
        if let Some(reasoning) = m.reasoning_any() {
            if !reasoning.trim().is_empty() {
                content.push(json!({ "type": "thinking", "thinking": reasoning }));
            }
        }
    }
    // assistant text. The crate parks text in choices[].message.content normally, but when a turn
    // ALSO has tool_calls it keeps the text only in the top-level ChatResponse.content — so fall
    // back to that (else assistant prose is dropped whenever a tool is called in the same turn).
    let text = {
        let t = msg.map(|m| m.content_as_text()).unwrap_or_default();
        if t.is_empty() {
            resp.content.clone()
        } else {
            t
        }
    };
    if !text.is_empty() {
        content.push(json!({ "type": "text", "text": text }));
    }
    // tool calls → tool_use blocks
    let mut had_tool_calls = false;
    if let Some(m) = msg {
        if let Some(calls) = &m.tool_calls {
            for tc in calls {
                had_tool_calls = true;
                let input: Value = tc.arguments_value().unwrap_or_else(|_| json!({}));
                content.push(json!({
                    "type": "tool_use",
                    "id": if tc.id.is_empty() { format!("toolu_{}", content.len()) } else { tc.id.clone() },
                    "name": tc.function.name,
                    "input": input,
                }));
            }
        }
    }
    if content.is_empty() {
        content.push(json!({ "type": "text", "text": "" }));
    }

    let finish = choice.and_then(|c| c.finish_reason.as_deref());
    let usage = resp.usage.as_ref();
    let input_tokens = usage.map(|u| u.prompt_tokens).unwrap_or(0);
    let output_tokens = usage.map(|u| u.completion_tokens).unwrap_or(0);

    json!({
        // never a constant fallback — clients persist this id and usage de-dupes by it
        "id": if resp.id.is_empty() { crate::protocol::uid("msg_ccbud") } else { resp.id.clone() },
        "type": "message",
        "role": "assistant",
        "model": client_model,
        "content": content,
        "stop_reason": stop_reason(finish, had_tool_calls),
        "stop_sequence": Value::Null,
        "usage": { "input_tokens": input_tokens, "output_tokens": output_tokens },
    })
}

/// Synthesize a complete Anthropic Messages SSE event sequence from a finished IR response. Used
/// when the client (Claude Code) asked to stream but the upstream was translated buffered — the
/// client still gets a valid, ordered `message_start → content_block_* → message_delta →
/// message_stop` stream, just delivered at once. True token-by-token transcoding is P2.
pub fn encode_response_sse(resp: &ChatResponse, client_model: &str) -> String {
    let full = encode_response(resp, client_model);
    let content = full
        .get("content")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let stop_reason = full
        .get("stop_reason")
        .cloned()
        .unwrap_or(json!("end_turn"));
    let usage = full
        .get("usage")
        .cloned()
        .unwrap_or(json!({ "input_tokens": 0, "output_tokens": 0 }));
    let id = full.get("id").cloned().unwrap_or(json!("msg_ccbud"));
    let input_tokens = usage.get("input_tokens").cloned().unwrap_or(json!(0));
    let output_tokens = usage.get("output_tokens").cloned().unwrap_or(json!(0));

    let ev = |event: &str, data: Value| {
        format!(
            "event: {}\ndata: {}\n\n",
            event,
            serde_json::to_string(&data).unwrap_or_default()
        )
    };
    let mut out = String::new();

    // message_start (usage input tokens known up front; output filled at message_delta)
    out.push_str(&ev(
        "message_start",
        json!({ "type": "message_start", "message": {
            "id": id, "type": "message", "role": "assistant", "model": client_model,
            "content": [], "stop_reason": Value::Null, "stop_sequence": Value::Null,
            "usage": { "input_tokens": input_tokens, "output_tokens": 0 },
        }}),
    ));

    for (i, block) in content.iter().enumerate() {
        let bt = block.get("type").and_then(|v| v.as_str()).unwrap_or("text");
        match bt {
            "text" => {
                let text = block.get("text").and_then(|v| v.as_str()).unwrap_or("");
                out.push_str(&ev("content_block_start", json!({ "type": "content_block_start", "index": i, "content_block": { "type": "text", "text": "" } })));
                if !text.is_empty() {
                    out.push_str(&ev("content_block_delta", json!({ "type": "content_block_delta", "index": i, "delta": { "type": "text_delta", "text": text } })));
                }
                out.push_str(&ev(
                    "content_block_stop",
                    json!({ "type": "content_block_stop", "index": i }),
                ));
            }
            "thinking" => {
                let think = block.get("thinking").and_then(|v| v.as_str()).unwrap_or("");
                out.push_str(&ev("content_block_start", json!({ "type": "content_block_start", "index": i, "content_block": { "type": "thinking", "thinking": "" } })));
                if !think.is_empty() {
                    out.push_str(&ev("content_block_delta", json!({ "type": "content_block_delta", "index": i, "delta": { "type": "thinking_delta", "thinking": think } })));
                }
                out.push_str(&ev(
                    "content_block_stop",
                    json!({ "type": "content_block_stop", "index": i }),
                ));
            }
            "tool_use" => {
                let empty = json!({});
                let input = block.get("input").unwrap_or(&empty);
                out.push_str(&ev("content_block_start", json!({ "type": "content_block_start", "index": i, "content_block": { "type": "tool_use", "id": block.get("id").cloned().unwrap_or(json!("")), "name": block.get("name").cloned().unwrap_or(json!("")), "input": {} } })));
                out.push_str(&ev("content_block_delta", json!({ "type": "content_block_delta", "index": i, "delta": { "type": "input_json_delta", "partial_json": serde_json::to_string(input).unwrap_or_else(|_| "{}".to_string()) } })));
                out.push_str(&ev(
                    "content_block_stop",
                    json!({ "type": "content_block_stop", "index": i }),
                ));
            }
            _ => {}
        }
    }

    out.push_str(&ev(
        "message_delta",
        json!({ "type": "message_delta", "delta": { "stop_reason": stop_reason, "stop_sequence": Value::Null }, "usage": { "output_tokens": output_tokens } }),
    ));
    out.push_str(&ev("message_stop", json!({ "type": "message_stop" })));
    out
}
