// IR → a synthesized OpenAI Responses SSE event sequence (client side: what Codex reads when the
// upstream was translated buffered).

use super::encode_response::encode_response_with_context;
use super::tools::CodexToolContext;
use llm_connector::types::ChatResponse;
use serde_json::{json, Value};

fn sse_ev(data: &Value) -> String {
    let t = data
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("message");
    format!(
        "event: {}\ndata: {}\n\n",
        t,
        serde_json::to_string(data).unwrap_or_default()
    )
}

/// Synthesize an OpenAI Responses SSE event sequence from a finished IR response. Used when the
/// client (Codex) asked to stream but the upstream was translated buffered — the client still gets
/// a valid `response.created → output_item.added/delta/done per item → terminal event` stream, just
/// delivered at once. Codex materializes items only from `response.output_item.done`; truncations
/// terminate with `response.incomplete` instead of being mislabeled completed.
pub fn encode_response_sse(resp: &ChatResponse, client_model: &str) -> String {
    encode_response_sse_with_context(resp, client_model, &CodexToolContext::default())
}

pub fn encode_response_sse_with_context(
    resp: &ChatResponse,
    client_model: &str,
    tool_context: &CodexToolContext,
) -> String {
    let full = encode_response_with_context(resp, client_model, tool_context);
    let rid = full
        .get("id")
        .and_then(|v| v.as_str())
        .unwrap_or("resp_ccbud")
        .to_string();
    let mut out = String::new();
    out.push_str(&sse_ev(&json!({ "type": "response.created",
        "response": { "id": rid, "object": "response", "status": "in_progress", "model": client_model } })));

    let items = full
        .get("output")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    for (idx, item) in items.iter().enumerate() {
        let item_id = item
            .get("id")
            .and_then(|v| v.as_str())
            .unwrap_or("item")
            .to_string();
        match item.get("type").and_then(|v| v.as_str()).unwrap_or("") {
            "message" => {
                let text = item["content"][0]["text"].as_str().unwrap_or("");
                out.push_str(&sse_ev(&json!({ "type": "response.output_item.added", "output_index": idx,
                    "item": { "type": "message", "id": item_id, "status": "in_progress", "role": "assistant", "content": [] } })));
                out.push_str(&sse_ev(
                    &json!({ "type": "response.content_part.added", "item_id": item_id,
                    "output_index": idx, "content_index": 0,
                    "part": { "type": "output_text", "annotations": [], "text": "" } }),
                ));
                if !text.is_empty() {
                    out.push_str(&sse_ev(
                        &json!({ "type": "response.output_text.delta", "item_id": item_id,
                        "output_index": idx, "content_index": 0, "delta": text }),
                    ));
                }
                out.push_str(&sse_ev(
                    &json!({ "type": "response.output_text.done", "item_id": item_id,
                    "output_index": idx, "content_index": 0, "text": text }),
                ));
                out.push_str(&sse_ev(
                    &json!({ "type": "response.content_part.done", "item_id": item_id,
                    "output_index": idx, "content_index": 0,
                    "part": { "type": "output_text", "annotations": [], "text": text } }),
                ));
                out.push_str(&sse_ev(&json!({ "type": "response.output_item.done", "output_index": idx, "item": item })));
            }
            "function_call" => {
                let args = item
                    .get("arguments")
                    .and_then(|v| v.as_str())
                    .unwrap_or("{}");
                let mut added = item.clone();
                added["status"] = json!("in_progress");
                added["arguments"] = json!("");
                out.push_str(&sse_ev(&json!({ "type": "response.output_item.added", "output_index": idx, "item": added })));
                out.push_str(&sse_ev(
                    &json!({ "type": "response.function_call_arguments.delta", "item_id": item_id,
                    "output_index": idx, "delta": args }),
                ));
                out.push_str(&sse_ev(
                    &json!({ "type": "response.function_call_arguments.done", "item_id": item_id,
                    "output_index": idx, "arguments": args }),
                ));
                out.push_str(&sse_ev(&json!({ "type": "response.output_item.done", "output_index": idx, "item": item })));
            }
            "custom_tool_call" => {
                let input = item.get("input").and_then(Value::as_str).unwrap_or("");
                let mut added = item.clone();
                added["status"] = json!("in_progress");
                added["input"] = json!("");
                out.push_str(&sse_ev(&json!({ "type": "response.output_item.added", "output_index": idx, "item": added })));
                if !input.is_empty() {
                    out.push_str(&sse_ev(&json!({ "type": "response.custom_tool_call_input.delta",
                        "item_id": item_id, "call_id": item.get("call_id").cloned().unwrap_or(json!("")),
                        "output_index": idx, "delta": input })));
                }
                out.push_str(&sse_ev(&json!({ "type": "response.custom_tool_call_input.done",
                    "item_id": item_id, "call_id": item.get("call_id").cloned().unwrap_or(json!("")),
                    "output_index": idx, "input": input })));
                out.push_str(&sse_ev(&json!({ "type": "response.output_item.done", "output_index": idx, "item": item })));
            }
            "tool_search_call" => {
                let mut added = item.clone();
                added["status"] = json!("in_progress");
                out.push_str(&sse_ev(&json!({ "type": "response.output_item.added", "output_index": idx, "item": added })));
                out.push_str(&sse_ev(&json!({ "type": "response.output_item.done", "output_index": idx, "item": item })));
            }
            "reasoning" => {
                let think = item["summary"][0]["text"].as_str().unwrap_or("");
                out.push_str(&sse_ev(
                    &json!({ "type": "response.output_item.added", "output_index": idx,
                    "item": { "type": "reasoning", "id": item_id, "summary": [] } }),
                ));
                if !think.is_empty() {
                    out.push_str(&sse_ev(&json!({ "type": "response.reasoning_summary_text.delta", "item_id": item_id,
                        "output_index": idx, "summary_index": 0, "delta": think })));
                }
                out.push_str(&sse_ev(&json!({ "type": "response.output_item.done", "output_index": idx, "item": item })));
            }
            _ => {
                out.push_str(&sse_ev(&json!({ "type": "response.output_item.done", "output_index": idx, "item": item })));
            }
        }
    }

    let terminal_type = if full.get("status").and_then(Value::as_str) == Some("incomplete") {
        "response.incomplete"
    } else {
        "response.completed"
    };
    out.push_str(&sse_ev(&json!({ "type": terminal_type, "response": full })));
    out
}
