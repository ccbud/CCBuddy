use super::*;
use serde_json::{json, Value};

#[test]
fn encodes_ir_to_responses_request() {
    let anthropic = json!({
        "model": "claude-x", "max_tokens": 500,
        "system": "be terse",
        "tools": [{ "name": "grep", "description": "search", "input_schema": { "type": "object" } }],
        "thinking": { "type": "enabled", "budget_tokens": 4096 },
        "messages": [
            { "role": "user", "content": "find foo" },
            { "role": "assistant", "content": [{ "type": "tool_use", "id": "c1", "name": "grep", "input": { "q": "foo" } }] },
            { "role": "user", "content": [{ "type": "tool_result", "tool_use_id": "c1", "content": "found" }] }
        ]
    });
    let ir = crate::protocol::anthropic::decode_request(&anthropic).unwrap();
    let body = encode_request(&ir, "gpt-5.5", false);

    assert_eq!(body["model"], "gpt-5.5");
    assert_eq!(body["instructions"], "be terse");
    assert_eq!(body["max_output_tokens"], 500);
    assert_eq!(body["reasoning"]["effort"], "medium"); // 4096 → medium
                                                       // tools flattened (name at item level, not under "function")
    assert_eq!(body["tools"][0]["type"], "function");
    assert_eq!(body["tools"][0]["name"], "grep");
    // input items: user message, function_call, function_call_output
    let input = body["input"].as_array().unwrap();
    assert!(input.iter().any(|i| i["type"] == "message"
        && i["role"] == "user"
        && i["content"][0]["type"] == "input_text"
        && i["content"][0]["text"] == "find foo"));
    let fc = input.iter().find(|i| i["type"] == "function_call").unwrap();
    assert_eq!(fc["name"], "grep");
    assert_eq!(fc["call_id"], "c1");
    let fco = input
        .iter()
        .find(|i| i["type"] == "function_call_output")
        .unwrap();
    assert_eq!(fco["call_id"], "c1");
    assert_eq!(fco["output"], "found");
}

#[test]
fn decodes_responses_reply_to_ir_then_anthropic() {
    // A Responses reply with an assistant message + a function_call output item.
    let resp = json!({
        "id": "resp_1", "object": "response", "created_at": 1, "model": "gpt-5.5", "status": "completed",
        "output": [
            { "type": "message", "role": "assistant", "content": [{ "type": "output_text", "text": "Working on it." }] },
            { "type": "function_call", "call_id": "call_7", "name": "grep", "arguments": "{\"q\":\"foo\"}" }
        ],
        "usage": { "input_tokens": 15, "output_tokens": 8, "total_tokens": 23 }
    });
    let ir = decode_response(&resp.to_string()).unwrap();
    // reuse the Anthropic response encoder → verify the round-trip surfaces text + tool_use + usage
    let out = crate::protocol::anthropic::encode_response(&ir, "claude-x");
    assert_eq!(out["stop_reason"], "tool_use");
    assert_eq!(out["usage"]["input_tokens"], 15);
    assert_eq!(out["usage"]["output_tokens"], 8);
    let content = out["content"].as_array().unwrap();
    assert!(content
        .iter()
        .any(|b| b["type"] == "text" && b["text"] == "Working on it."));
    let tu = content.iter().find(|b| b["type"] == "tool_use").unwrap();
    assert_eq!(tu["name"], "grep");
    assert_eq!(tu["input"]["q"], "foo");
}

// A representative Codex request (wire_api="responses"): instructions, flattened function
// tools, and an agentic history — user message, assistant prose + function_call, its
// function_call_output, and a reasoning item bridged onto the assistant turn.
fn codex_request() -> Value {
    json!({
        "model": "z-ai/glm-5.2",
        "instructions": "You are Codex.",
        "input": [
            { "type": "message", "role": "user", "content": [{ "type": "input_text", "text": "list files" }] },
            { "type": "reasoning", "id": "rs_x", "summary": [{ "type": "summary_text", "text": "thinking…" }] },
            { "type": "message", "role": "assistant", "content": [{ "type": "output_text", "text": "Running ls." }] },
            { "type": "function_call", "call_id": "call_1", "name": "shell", "arguments": "{\"command\":[\"ls\"]}" },
            { "type": "function_call_output", "call_id": "call_1", "output": "a.txt\nb.txt" },
            { "type": "message", "role": "user", "content": [{ "type": "input_text", "text": "read a.txt" }] }
        ],
        "tools": [
            { "type": "function", "name": "shell", "description": "run a command", "strict": false,
              "parameters": { "type": "object", "properties": { "command": { "type": "array" } } } },
            { "type": "web_search" }
        ],
        "tool_choice": "auto",
        "parallel_tool_calls": false,
        "reasoning": { "effort": "medium", "summary": "auto" },
        "store": false,
        "stream": true
    })
}

#[test]
fn decodes_codex_responses_request_to_ir() {
    let ir = decode_request(&codex_request()).unwrap();
    let roles: Vec<_> = ir
        .messages
        .iter()
        .map(|m| format!("{:?}", m.role))
        .collect();
    // instructions → System; assistant prose + function_call folded into ONE assistant turn;
    // function_call_output → Tool; reasoning item bridged onto the assistant turn.
    assert_eq!(roles, vec!["System", "User", "Assistant", "Tool", "User"]);
    assert_eq!(ir.messages[0].content_as_text(), "You are Codex.");
    assert_eq!(ir.messages[1].content_as_text(), "list files");
    assert_eq!(ir.messages[2].content_as_text(), "Running ls.");
    assert_eq!(
        ir.messages[2].reasoning_content.as_deref(),
        Some("thinking…")
    );
    let calls = ir.messages[2].tool_calls.as_ref().unwrap();
    assert_eq!(calls[0].id, "call_1");
    assert_eq!(calls[0].function.name, "shell");
    assert!(calls[0].function.arguments.contains("ls"));
    assert_eq!(ir.messages[3].tool_call_id.as_deref(), Some("call_1"));
    assert_eq!(ir.messages[3].content_as_text(), "a.txt\nb.txt");
    // flattened function tool recognized, non-function web_search dropped
    let tools = ir.tools.as_ref().unwrap();
    assert_eq!(tools.len(), 1);
    assert_eq!(tools[0].function.name, "shell");
    assert_eq!(ir.stream, Some(true));
    // reasoning.effort medium → thinking budget for an Anthropic upstream
    assert_eq!(ir.enable_thinking, Some(true));
    assert_eq!(ir.thinking_budget, Some(4096));

    // The crate encodes the IR to a real Anthropic Messages body — proves the reused half
    // works end-to-end (responses client → anthropic upstream).
    use llm_connector::core::Protocol;
    use llm_connector::protocols::adapters::anthropic::AnthropicProtocol;
    let body = AnthropicProtocol::new("")
        .build_chat_request_body(&ir)
        .unwrap();
    let msgs = body.get("messages").and_then(|v| v.as_array()).unwrap();
    // assistant turn carries a tool_use block; tool output became a user tool_result turn
    assert!(msgs.iter().any(|m| m["role"] == "assistant"
        && m["content"]
            .as_array()
            .unwrap()
            .iter()
            .any(|b| b["type"] == "tool_use" && b["id"] == "call_1")));
    assert!(msgs.iter().any(|m| m["role"] == "user"
        && m["content"]
            .as_array()
            .unwrap()
            .iter()
            .any(|b| b["type"] == "tool_result" && b["tool_use_id"] == "call_1")));
    assert_eq!(body["system"], "You are Codex.");
}
