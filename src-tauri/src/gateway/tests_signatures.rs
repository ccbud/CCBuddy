use serde_json::{json, Value};

use super::history_args::{
    provider_safe_history_tool_arguments, sanitize_provider_history_tool_arguments,
};
use super::redact::now_ms;
use super::signatures::{
    apply_gemini_signature_fallback, ThoughtSignatureBatch, ThoughtSignatureCache,
    GEMINI_SIGNATURE_FALLBACK, THOUGHT_SIGNATURE_TTL_MS,
};

#[test]
fn repairs_malformed_history_arguments_before_strict_chat_forwarding() {
    let body = json!({
        "model": "gpt-5.4",
        "input": [
            { "type": "message", "role": "user", "content": [{
                "type": "input_text", "text": "Use the helper and continue"
            }] },
            { "type": "function_call", "call_id": "call_bad", "name": "helper",
                "arguments": "{\"value\":1} trailing-garbage" },
            { "type": "function_call_output", "call_id": "call_bad",
                "output": "failed to parse function arguments" }
        ],
        "tools": [{ "type": "function", "name": "helper", "description": "test",
            "parameters": { "type": "object", "properties": { "value": { "type": "number" } } } }]
    });
    let mut ir = crate::protocol::decode_client_request(
        crate::protocol::Wire::OpenAiResponses,
        &body,
    )
    .unwrap();
    let call = ir.messages[1].tool_calls.as_mut().unwrap().first_mut().unwrap();
    call.thought_signature = Some("stale-signature".to_string());

    assert_eq!(sanitize_provider_history_tool_arguments(&mut ir), 1);
    let call = &ir.messages[1].tool_calls.as_ref().unwrap()[0];
    assert_eq!(serde_json::from_str::<Value>(&call.function.arguments).unwrap()["value"], 1);
    assert!(crate::protocol::tool_call_thought_signature(call).is_none());
    assert_eq!(apply_gemini_signature_fallback(&mut ir), 1);

    let encoded = crate::protocol::encode_upstream_request(
        crate::protocol::Wire::OpenAiChat,
        &ir,
        "gemini-3.5-flash",
        false,
    )
    .unwrap();
    let outgoing = &encoded["messages"][1]["tool_calls"][0];
    assert_eq!(
        serde_json::from_str::<Value>(outgoing["function"]["arguments"].as_str().unwrap())
            .unwrap()["value"],
        1
    );
    assert_eq!(
        outgoing["extra_content"]["google"]["thought_signature"],
        GEMINI_SIGNATURE_FALLBACK
    );
}

#[test]
fn history_argument_repair_preserves_valid_objects_and_wraps_unrecoverable_text() {
    assert_eq!(provider_safe_history_tool_arguments(" { \"value\": 1 } "), None);
    let scalar = provider_safe_history_tool_arguments("42").unwrap();
    assert_eq!(serde_json::from_str::<Value>(&scalar).unwrap()["_ccbuddy_value"], 42);
    let raw = provider_safe_history_tool_arguments("not json at all").unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&raw).unwrap()["_ccbuddy_raw_arguments"],
        "not json at all"
    );

    for arguments in ["{\"value\":1}\u{00a0}", "\u{000b}{\"value\":1}"] {
        let repaired = provider_safe_history_tool_arguments(arguments).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&repaired).unwrap(),
            json!({ "value": 1 })
        );
    }
}

#[test]
fn history_argument_repair_clears_a_signature_restored_for_different_bytes() {
    let captured = crate::protocol::stream::CapturedToolCall {
        call_id: "call_empty".to_string(),
        name: "helper".to_string(),
        arguments: String::new(),
        thought_signature: Some("real-signature".to_string()),
    };
    let mut cache = ThoughtSignatureCache::default();
    cache.remember("google", Some("session-empty"), &[captured]);
    let body = json!({
        "model": "gpt-5.4",
        "input": [
            { "role": "user", "content": "Call helper" },
            { "type": "function_call", "call_id": "call_empty", "name": "helper",
                "arguments": "" },
            { "type": "function_call_output", "call_id": "call_empty", "output": "invalid" }
        ]
    });
    let mut ir = crate::protocol::decode_client_request(
        crate::protocol::Wire::OpenAiResponses,
        &body,
    )
    .unwrap();

    assert_eq!(cache.restore("google", Some("session-empty"), &mut ir), 1);
    assert_eq!(sanitize_provider_history_tool_arguments(&mut ir), 1);
    let call = &ir.messages[1].tool_calls.as_ref().unwrap()[0];
    assert_eq!(call.function.arguments, "{}");
    assert!(crate::protocol::tool_call_thought_signature(call).is_none());
    assert_eq!(apply_gemini_signature_fallback(&mut ir), 1);
    assert_eq!(
        crate::protocol::tool_call_thought_signature(
            &ir.messages[1].tool_calls.as_ref().unwrap()[0]
        )
        .as_deref(),
        Some(GEMINI_SIGNATURE_FALLBACK)
    );
}

#[test]
fn restores_latest_batch_and_falls_back_for_prior_steps() {
    let call = |id: &str, name: &str, arguments: &str, signature: Option<&str>| {
        crate::protocol::stream::CapturedToolCall {
            call_id: id.to_string(),
            name: name.to_string(),
            arguments: arguments.to_string(),
            thought_signature: signature.map(str::to_string),
        }
    };
    let mut cache = ThoughtSignatureCache::default();
    cache.remember("google", Some("session-1"), &[
        call("default_api:Bash", "default_api:Bash", "{\"command\":\"pwd\"}", Some("sig-old")),
    ]);
    cache.remember("google", Some("session-1"), &[
        call("call_paris", "weather", "{ \"city\": \"Paris\" }", Some("sig-latest")),
        call("call_london", "weather", "{\"city\":\"London\"}", None),
    ]);
    let claude = json!({
        "model": "claude-sonnet-5", "max_tokens": 1024,
        "messages": [
            { "role": "user", "content": "Run pwd, then check Paris and London" },
            { "role": "assistant", "content": [{
                "type": "tool_use", "id": "default_api:Bash", "name": "default_api:Bash",
                "input": { "command": "pwd" }
            }] },
            { "role": "user", "content": [{
                "type": "tool_result", "tool_use_id": "default_api:Bash", "content": "/tmp"
            }] },
            { "role": "assistant", "content": [
                { "type": "tool_use", "id": "call_paris", "name": "weather",
                    "input": { "city": "Paris" } },
                { "type": "tool_use", "id": "call_london", "name": "weather",
                    "input": { "city": "London" } }
            ] },
            { "role": "user", "content": [
                { "type": "tool_result", "tool_use_id": "call_paris", "content": "15C" },
                { "type": "tool_result", "tool_use_id": "call_london", "content": "12C" }
            ] }
        ]
    });
    let mut ir = crate::protocol::decode_client_request(crate::protocol::Wire::Anthropic, &claude).unwrap();
    assert_eq!(cache.restore("google", Some("session-1"), &mut ir), 1);
    assert_eq!(apply_gemini_signature_fallback(&mut ir), 1);
    let steps: Vec<_> = ir.messages.iter().filter_map(|message| message.tool_calls.as_ref()).collect();
    assert_eq!(crate::protocol::tool_call_thought_signature(&steps[0][0]).as_deref(),
        Some(GEMINI_SIGNATURE_FALLBACK));
    assert_eq!(crate::protocol::tool_call_thought_signature(&steps[1][0]).as_deref(),
        Some("sig-latest"));
    assert!(crate::protocol::tool_call_thought_signature(&steps[1][1]).is_none());
}

#[test]
fn sessionless_cache_access_prunes_expired_batches() {
    let stale = ThoughtSignatureBatch {
        calls: vec![],
        touched_at: now_ms().saturating_sub(THOUGHT_SIGNATURE_TTL_MS + 1),
    };
    let mut cache = ThoughtSignatureCache::default();
    cache.batches.insert(("google".into(), "stale".into()), stale.clone());
    cache.remember("google", None, &[]);
    assert!(cache.batches.is_empty());

    cache.batches.insert(("google".into(), "stale".into()), stale);
    let body = json!({
        "model": "claude-sonnet-5",
        "max_tokens": 1,
        "messages": [{ "role": "user", "content": "ping" }]
    });
    let mut request = crate::protocol::decode_client_request(
        crate::protocol::Wire::Anthropic,
        &body,
    ).unwrap();
    assert_eq!(cache.restore("google", None, &mut request), 0);
    assert!(cache.batches.is_empty());
}
