use super::decode::decode_request;
use super::encode::encode_response;
use serde_json::json;
use llm_connector::core::Protocol;
use llm_connector::protocols::adapters::anthropic::AnthropicProtocol;

#[test]
fn chat_request_to_ir_to_anthropic_upstream() {
    let chat = json!({
        "model": "gpt-x", "max_tokens": 200,
        "messages": [
            { "role": "system", "content": "be nice" },
            { "role": "user", "content": "hello" }
        ],
        "tools": [{ "type": "function", "function": { "name": "f", "description": "d", "parameters": { "type": "object" } } }]
    });
    let ir = decode_request(&chat).unwrap();
    assert_eq!(ir.messages[0].content_as_text(), "be nice");
    assert_eq!(ir.messages[1].content_as_text(), "hello");
    assert_eq!(ir.tools.as_ref().unwrap()[0].function.name, "f");
    // crate encodes IR → Anthropic upstream request (the reverse direction's upstream half)
    let body = AnthropicProtocol::new("").build_chat_request_body(&ir).unwrap();
    assert!(body.get("messages").is_some());
}

#[test]
fn anthropic_reply_to_ir_to_chat_response() {
    // crate decodes an Anthropic response → IR; we encode IR → Chat Completions for the client.
    let anthropic = r#"{"id":"msg_1","type":"message","role":"assistant","model":"claude",
        "content":[{"type":"text","text":"done"}],"stop_reason":"end_turn",
        "usage":{"input_tokens":9,"output_tokens":4}}"#;
    let ir = AnthropicProtocol::new("").parse_response(anthropic).unwrap();
    let out = encode_response(&ir, "gpt-x");
    assert_eq!(out["object"], "chat.completion");
    assert_eq!(out["model"], "gpt-x");
    assert_eq!(out["choices"][0]["message"]["content"], "done");
    assert_eq!(out["choices"][0]["finish_reason"], "stop");
    assert_eq!(out["usage"]["prompt_tokens"], 9);
    assert_eq!(out["usage"]["completion_tokens"], 4);
}
