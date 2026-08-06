// IR → OpenAI Responses RESPONSE json (client side: the buffered body Codex consumes).

use super::helpers::{response_incomplete_reason, response_scoped_call_id};
use super::tools::CodexToolContext;
use llm_connector::types::ChatResponse;
use serde_json::{json, Value};

/// Encode the IR response back into an OpenAI Responses RESPONSE json. `client_model` is the name
/// the client asked for (so Codex sees its own model, not the upstream's). Unlike the crate's
/// chat_response_to_responses_response this maps tool_calls → function_call items and provider
/// reasoning → a reasoning item — both load-bearing for Codex's agent loop.
pub fn encode_response(resp: &ChatResponse, client_model: &str) -> Value {
    encode_response_with_context(resp, client_model, &CodexToolContext::default())
}

pub fn encode_response_with_context(
    resp: &ChatResponse,
    client_model: &str,
    tool_context: &CodexToolContext,
) -> Value {
    let choice = resp.choices.first();
    let msg = choice.map(|c| &c.message);
    // Same fallback as anthropic.rs: when a turn has tool_calls the crate parks the prose only in
    // the top-level ChatResponse.content.
    let text = {
        let t = msg.map(|m| m.content_as_text()).unwrap_or_default();
        if t.is_empty() {
            resp.content.clone()
        } else {
            t
        }
    };
    // never a constant fallback — item ids derive from this and land in client history
    let rid = if resp.id.is_empty() {
        super::super::uid("ccbud")
    } else {
        resp.id.clone()
    };

    let mut output: Vec<Value> = vec![];
    if let Some(reasoning) = msg.and_then(|m| m.reasoning_any()) {
        if !reasoning.trim().is_empty() {
            output.push(json!({ "type": "reasoning", "id": format!("rs_{}", rid),
                "summary": [{ "type": "summary_text", "text": reasoning }] }));
        }
    }
    if !text.is_empty() {
        output.push(
            json!({ "type": "message", "id": format!("msg_{}", rid), "status": "completed",
            "role": "assistant",
            "content": [{ "type": "output_text", "annotations": [], "text": text }] }),
        );
    }
    if let Some(m) = msg {
        if let Some(calls) = &m.tool_calls {
            for (i, tc) in calls.iter().enumerate() {
                let call_id = response_scoped_call_id(&format!("resp_{}", rid), i);
                let item_id = tool_context.response_item_id(&tc.function.name, &rid, i);
                output.push(tool_context.response_tool_item_with_reasoning(
                    &item_id,
                    "completed",
                    &call_id,
                    &tc.function.name,
                    &tc.function.arguments,
                    m.reasoning_any(),
                ));
            }
        }
    }
    if output.is_empty() {
        // Codex builds the turn from output items; an empty message beats an empty array.
        output.push(json!({ "type": "message", "id": format!("msg_{}", rid), "status": "completed",
            "role": "assistant", "content": [{ "type": "output_text", "annotations": [], "text": "" }] }));
    }

    let usage = resp.usage.as_ref();
    let input_tokens = usage.map(|u| u.prompt_tokens).unwrap_or(0) as i64;
    let output_tokens = usage.map(|u| u.completion_tokens).unwrap_or(0) as i64;
    let total =
        (usage.map(|u| u.total_tokens).unwrap_or(0) as i64).max(input_tokens + output_tokens);
    let incomplete_reason =
        response_incomplete_reason(choice.and_then(|choice| choice.finish_reason.as_deref()));
    let mut response = json!({
        "id": format!("resp_{}", rid),
        "object": "response",
        "created_at": resp.created,
        "status": if incomplete_reason.is_some() { "incomplete" } else { "completed" },
        "model": client_model,
        "output": output,
        "output_text": text,
        "usage": {
            "input_tokens": input_tokens,
            "input_tokens_details": { "cached_tokens": 0 },
            "output_tokens": output_tokens,
            "output_tokens_details": { "reasoning_tokens": 0 },
            "total_tokens": total,
        }
    });
    if let Some(reason) = incomplete_reason {
        response["incomplete_details"] = json!({ "reason": reason });
    }
    response
}
