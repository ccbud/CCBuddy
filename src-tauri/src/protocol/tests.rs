use super::*;
use llm_connector::types::ChatRequest;
use serde_json::{json, Value};

#[test]
fn upstream_urls_respect_the_configured_base() {
    let cases = [
        (Wire::Anthropic, "/messages"),
        (Wire::OpenAiChat, "/chat/completions"),
        (Wire::OpenAiResponses, "/responses"),
    ];
    for (wire, endpoint) in cases {
        for base in [
            "https://example.com",
            "https://example.com/v1",
            "https://example.com/v4",
            "https://generativelanguage.googleapis.com/v1beta/openai",
        ] {
            assert_eq!(wire.upstream_url(base), format!("{}{}", base, endpoint));
        }
    }
}

#[test]
fn v1_fallback_is_only_offered_for_unversioned_bases() {
    assert_eq!(
        Wire::OpenAiChat.v1_fallback_url("https://example.com/api"),
        Some("https://example.com/api/v1/chat/completions".to_string())
    );
    for base in [
        "https://example.com/v1",
        "https://example.com/v4/",
        "https://example.com/v1beta",
        "https://example.com/V2alpha",
        "https://generativelanguage.googleapis.com/v1beta/openai",
    ] {
        assert_eq!(Wire::OpenAiChat.v1_fallback_url(base), None, "{base}");
    }
}

#[test]
fn canonical_request_endpoints_exclude_auxiliary_routes() {
    assert_eq!(Wire::from_request_endpoint("/v1/messages"), Some(Wire::Anthropic));
    assert_eq!(Wire::from_request_endpoint("/v1/chat/completions"), Some(Wire::OpenAiChat));
    assert_eq!(Wire::from_request_endpoint("/v1/responses"), Some(Wire::OpenAiResponses));
    assert_eq!(
        Wire::from_request_endpoint("/v1/responses/compact"),
        Some(Wire::OpenAiResponses)
    );
    assert_eq!(
        Wire::OpenAiResponses.upstream_url_for_request(
            "https://example.com/v1",
            "/v1/responses/compact",
        ),
        "https://example.com/v1/responses/compact"
    );
    assert_eq!(Wire::from_request_endpoint("/v1/messages/count_tokens"), None);
    assert_eq!(Wire::from_request_endpoint("/v1/models"), None);
}

#[test]
fn v1_fallback_statuses_exclude_non_path_errors() {
    for status in [400, 404, 405] {
        assert!(should_try_v1_fallback(status));
    }
    for status in [401, 403, 413, 415, 422, 429, 500] {
        assert!(!should_try_v1_fallback(status));
    }
}

// Kimi/Moonshot and DeepSeek thinking models 400 on assistant tool-call history missing
// `reasoning_content`: real reasoning must survive the Responses→chat bridge, and turns whose
// reasoning didn't survive get the placeholder.
#[test]
fn chat_bodies_backfill_tool_call_reasoning() {
    let codex = json!({
        "model": "m",
        "input": [
            { "type": "message", "role": "user", "content": [{ "type": "input_text", "text": "go" }] },
            { "type": "function_call", "call_id": "c1", "name": "shell", "arguments": "{}" },
            { "type": "function_call_output", "call_id": "c1", "output": "ok" },
            { "type": "reasoning", "summary": [{ "type": "summary_text", "text": "real thoughts" }] },
            { "type": "function_call", "call_id": "c2", "name": "shell", "arguments": "{}" },
            { "type": "function_call_output", "call_id": "c2", "output": "ok" }
        ]
    });
    let ir = decode_client_request(Wire::OpenAiResponses, &codex).unwrap();
    let body = encode_upstream_request(Wire::OpenAiChat, &ir, "kimi-k2-thinking", true).unwrap();
    let assistants: Vec<_> = body["messages"].as_array().unwrap().iter()
        .filter(|m| m["role"] == "assistant").collect();
    assert_eq!(assistants.len(), 2);
    // step 1 lost its reasoning → placeholder; step 2's bridged reasoning is preserved
    assert_eq!(assistants[0]["reasoning_content"], "tool call");
    assert_eq!(assistants[1]["reasoning_content"], "real thoughts");
}

#[test]
fn glm_chat_uses_native_thinking_switch() {
    let codex = json!({
        "model": "gpt-5.4",
        "input": [{
            "type": "message",
            "role": "user",
            "content": [{ "type": "input_text", "text": "inspect" }]
        }],
        "reasoning": { "effort": "ultra" }
    });
    let ir = decode_client_request(Wire::OpenAiResponses, &codex).unwrap();
    let body = encode_upstream_request(Wire::OpenAiChat, &ir, "glm-5.2", true).unwrap();
    assert_eq!(body["thinking"]["type"], "enabled");
    assert!(body.get("reasoning_effort").is_none());
}

#[test]
fn gemini_thought_signature_maps_between_openai_wire_and_ir() {
    let signature = "sig-regression-abc";
    let upstream_response = json!({
        "id": "chatcmpl-gemini", "object": "chat.completion", "created": 1,
        "model": "google/gemini-3-flash-preview",
        "choices": [{ "index": 0, "finish_reason": "tool_calls", "message": {
            "role": "assistant", "content": Value::Null,
            "tool_calls": [{
                "id": "default_api:Bash", "type": "function",
                "function": { "name": "default_api:Bash", "arguments": "{\"command\":\"pwd\"}" },
                "extra_content": { "google": { "thought_signature": signature } }
            }]
        }}],
        "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
    });

    let ir = decode_upstream_response(Wire::OpenAiChat, &upstream_response.to_string()).unwrap();
    let call = &ir.choices[0].message.tool_calls.as_ref().unwrap()[0];
    assert_eq!(tool_call_thought_signature(call).as_deref(), Some(signature));
    assert_eq!(json_thought_signature(&json!({
        "thought_signature": "", "function": { "thought_signature": signature }
    })).as_deref(), Some(signature));

    let mut message = llm_connector::types::Message::new(
        llm_connector::types::Role::Assistant,
        vec![],
    );
    message.tool_calls = Some(vec![call.clone()]);
    let next_ir = ChatRequest::new("gemini").with_messages(vec![message]);
    let outgoing = encode_upstream_request(
        Wire::OpenAiChat, &next_ir, "google/gemini-3-flash-preview", false,
    ).unwrap();
    let assistant = outgoing["messages"].as_array().unwrap().iter()
        .find(|message| message["role"] == "assistant").unwrap();
    let outgoing_call = &assistant["tool_calls"][0];
    assert_eq!(outgoing_call["extra_content"]["google"]["thought_signature"], signature);
    assert!(outgoing_call.get("thought_signature").is_none());
    assert!(outgoing_call["function"].get("thought_signature").is_none());
}
