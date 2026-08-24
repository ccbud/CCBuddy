use super::decode::decode_request;
use super::encode::encode_response;
use llm_connector::core::Protocol;
use llm_connector::protocols::adapters::openai::OpenAIProtocol;
use serde_json::{json, Value};

// A representative Claude Code request: system + a user prose turn (input_text blocks), an
// assistant tool_use, and the user's tool_result — the shape the messages→chat path must map.
fn claude_request() -> Value {
    json!({
        "model": "claude-sonnet-4-6",
        "max_tokens": 1024,
        "system": "You are a helpful coding assistant.",
        "tools": [{ "name": "read_file", "description": "Read a file",
                    "input_schema": { "type": "object", "properties": { "path": { "type": "string" } } } }],
        "messages": [
            { "role": "user", "content": [{ "type": "input_text", "text": "read a.txt" }] },
            { "role": "assistant", "content": [
                { "type": "text", "text": "Reading it." },
                { "type": "tool_use", "id": "toolu_1", "name": "read_file", "input": { "path": "a.txt" } }
            ] },
            { "role": "user", "content": [
                { "type": "tool_result", "tool_use_id": "toolu_1", "content": "hello world" }
            ] }
        ]
    })
}

#[test]
fn decodes_anthropic_request_to_openai_chat_body() {
    let ir = decode_request(&claude_request()).unwrap();
    // system prepended, tool_result split into its own tool message, ordering preserved.
    let roles: Vec<_> = ir
        .messages
        .iter()
        .map(|m| format!("{:?}", m.role))
        .collect();
    assert_eq!(roles, vec!["System", "User", "Assistant", "Tool"]);
    // input_text was recognized (not dropped → this is the Claude Code footgun).
    assert_eq!(ir.messages[1].content_as_text(), "read a.txt");
    // assistant tool_use → tool_calls
    let calls = ir.messages[2].tool_calls.as_ref().unwrap();
    assert_eq!(calls[0].function.name, "read_file");
    assert!(calls[0].function.arguments.contains("a.txt"));
    // tool_result → tool message carrying the id + output
    assert_eq!(ir.messages[3].tool_call_id.as_deref(), Some("toolu_1"));
    assert_eq!(ir.messages[3].content_as_text(), "hello world");
    // tools carried through
    assert_eq!(ir.tools.as_ref().unwrap()[0].function.name, "read_file");

    // The crate encodes the IR to a real OpenAI Chat body — proves the reused half works.
    let body = OpenAIProtocol::new("k")
        .build_chat_request_body(&ir)
        .unwrap();
    let msgs = body.get("messages").and_then(|v| v.as_array()).unwrap();
    assert_eq!(msgs[0]["role"], "system");
    assert!(body.get("tools").is_some());
}

#[test]
fn encodes_openai_chat_response_to_anthropic() {
    // A real OpenAI Chat response with a tool call, decoded by the crate → IR → Anthropic.
    let openai = r#"{
        "id":"chatcmpl-1","object":"chat.completion","created":1,"model":"gpt-4o",
        "choices":[{"index":0,"finish_reason":"tool_calls","message":{
            "role":"assistant","content":"Sure.",
            "tool_calls":[{"id":"call_9","type":"function",
                "function":{"name":"read_file","arguments":"{\"path\":\"a.txt\"}"}}]}}],
        "usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}
    }"#;
    let ir = OpenAIProtocol::new("k").parse_response(openai).unwrap();
    let out = encode_response(&ir, "claude-sonnet-4-6");

    assert_eq!(out["type"], "message");
    assert_eq!(out["role"], "assistant");
    assert_eq!(out["model"], "claude-sonnet-4-6"); // client-facing model, not gpt-4o
    assert_eq!(out["stop_reason"], "tool_use");
    assert_eq!(out["usage"]["input_tokens"], 11);
    assert_eq!(out["usage"]["output_tokens"], 7);
    let content = out["content"].as_array().unwrap();
    assert!(content
        .iter()
        .any(|b| b["type"] == "text" && b["text"] == "Sure."));
    let tu = content.iter().find(|b| b["type"] == "tool_use").unwrap();
    assert_eq!(tu["name"], "read_file");
    assert_eq!(tu["input"]["path"], "a.txt");
    assert_eq!(tu["id"], "call_9");
}

#[test]
fn plain_text_round_trip() {
    let req = json!({
        "model": "claude-x", "max_tokens": 100,
        "messages": [{ "role": "user", "content": "hi there" }]
    });
    let ir = decode_request(&req).unwrap();
    assert_eq!(ir.messages.len(), 1);
    assert_eq!(ir.messages[0].content_as_text(), "hi there");

    let openai = r#"{"id":"c1","object":"chat.completion","created":1,"model":"gpt","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"hello!"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}"#;
    let ir2 = OpenAIProtocol::new("k").parse_response(openai).unwrap();
    let out = encode_response(&ir2, "claude-x");
    assert_eq!(out["stop_reason"], "end_turn");
    assert_eq!(out["content"][0]["text"], "hello!");
}
