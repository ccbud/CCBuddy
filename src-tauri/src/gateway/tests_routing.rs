use serde_json::json;

use super::routing::{resolve_routing, Routing};
use super::session::{codex_history_scope_for_session, request_session_id};
use super::signatures::{apply_gemini_signature_fallback, ThoughtSignatureCache, GEMINI_SIGNATURE_FALLBACK};
use super::targets::retry_delay;

#[test]
fn routing_classifies_by_family() {
    let cfg = json!({ "providers": [{ "id": "p", "baseUrl": "http://127.0.0.1:1", "authToken": "k",
        "defaultModel": "big", "smallFastModel": "small", "mapDefaultModels": true, "models": [] }], "activeProviderId": "p" });
    let out = |r: Option<Routing>| r.and_then(|x| x.outgoing_model);
    // Claude: haiku → fast, fable/opus/sonnet → primary.
    assert_eq!(out(resolve_routing(Some("claude-haiku-4-5"), &cfg, None)).as_deref(), Some("small"));
    assert_eq!(out(resolve_routing(Some("claude-fable-5"), &cfg, None)).as_deref(), Some("big"));
    assert_eq!(out(resolve_routing(Some("claude-opus-4-8"), &cfg, None)).as_deref(), Some("big"));
    // Codex: stable/default identities → primary; explicit small tiers → fast. Legacy
    // sol/terra names remain primary for existing configs.
    assert_eq!(
        out(resolve_routing(Some("gpt-5.4"), &cfg, None)).as_deref(),
        Some("big")
    );
    assert_eq!(
        out(resolve_routing(Some("gpt-5.4-mini"), &cfg, None)).as_deref(),
        Some("small")
    );
    assert_eq!(out(resolve_routing(Some("gpt-5.6-sol"), &cfg, None)).as_deref(), Some("big"));
    assert_eq!(out(resolve_routing(Some("gpt-5.6-terra"), &cfg, None)).as_deref(), Some("big"));
    assert_eq!(out(resolve_routing(Some("gpt-5.6-sol-pro"), &cfg, None)).as_deref(), Some("big"));
    assert_eq!(out(resolve_routing(Some("gpt-5.6-luna"), &cfg, None)).as_deref(), Some("small"));
}
#[test]
fn retry_delay_honors_seconds_and_backoff() {
    assert_eq!(retry_delay(Some("2"), 0, 500), 2000);
    assert_eq!(retry_delay(None, 0, 500), 500);
    assert_eq!(retry_delay(None, 1, 500), 1000);
    // HTTP-date in the past → no wait (clamped to 0), NOT a fall-through to backoff.
    assert_eq!(retry_delay(Some("Wed, 21 Oct 2015 07:28:00 GMT"), 3, 500), 0);
    // Unparseable Retry-After → exponential backoff (base * 2^attempt).
    assert_eq!(retry_delay(Some("soon"), 2, 500), 2000);
}
#[test]
fn extracts_claude_session_id_from_metadata() {
    let nested = json!({ "metadata": { "user_id": "{\"session_id\":\"session-123\",\"account_id\":\"a\"}" } });
    assert_eq!(request_session_id(&nested).as_deref(), Some("session-123"));
    assert!(request_session_id(&json!({ "metadata": { "user_id": "user-123" } })).is_none());
    // Codex (Responses client) identifies its conversation via prompt_cache_key.
    assert_eq!(
        request_session_id(&json!({ "prompt_cache_key": "conv-42" })).as_deref(),
        Some("conv-42")
    );
    assert!(request_session_id(&json!({ "prompt_cache_key": "  " })).is_none());
    assert_eq!(codex_history_scope_for_session(Some("conv-42")), "conv-42");
    assert_eq!(codex_history_scope_for_session(None), "");
}

// The full Codex ⇄ Gemini(chat) signature round-trip: what ChatToResponses captured last turn
// is restored onto the function_call history Codex echoes back, and earlier steps get the
// documented fallback sentinel — without it Gemini 3 rejects the request with a 400.
#[test]
fn restores_signatures_for_codex_responses_requests() {
    let mut cache = ThoughtSignatureCache::default();
    cache.remember("google", Some("conv-42"), &[
        crate::protocol::stream::CapturedToolCall {
            call_id: "call_9".to_string(),
            name: "shell".to_string(),
            arguments: "{\"command\":[\"ls\"]}".to_string(),
            thought_signature: Some("sig-codex".to_string()),
        },
    ]);
    let codex = json!({
        "model": "gpt-5.5-ccbud",
        "instructions": "You are Codex.",
        "prompt_cache_key": "conv-42",
        "input": [
            { "type": "message", "role": "user", "content": [{ "type": "input_text", "text": "list, then read" }] },
            { "type": "function_call", "call_id": "call_1", "name": "shell", "arguments": "{\"command\":[\"pwd\"]}" },
            { "type": "function_call_output", "call_id": "call_1", "output": "/tmp" },
            { "type": "function_call", "call_id": "call_9", "name": "shell", "arguments": "{ \"command\": [\"ls\"] }" },
            { "type": "function_call_output", "call_id": "call_9", "output": "a.txt" }
        ],
        "store": false, "stream": true
    });
    let mut ir = crate::protocol::decode_client_request(crate::protocol::Wire::OpenAiResponses, &codex).unwrap();
    assert_eq!(request_session_id(&codex).as_deref(), Some("conv-42"));
    assert_eq!(cache.restore("google", Some("conv-42"), &mut ir), 1);
    assert_eq!(apply_gemini_signature_fallback(&mut ir), 1);
    let steps: Vec<_> = ir.messages.iter().filter_map(|message| message.tool_calls.as_ref()).collect();
    assert_eq!(crate::protocol::tool_call_thought_signature(&steps[0][0]).as_deref(),
        Some(GEMINI_SIGNATURE_FALLBACK));
    assert_eq!(crate::protocol::tool_call_thought_signature(&steps[1][0]).as_deref(),
        Some("sig-codex"));
    // …and the encoded Gemini chat body carries them where Gemini validates them.
    let body = crate::protocol::encode_upstream_request(
        crate::protocol::Wire::OpenAiChat, &ir, "gemini-3-flash-preview", true,
    ).unwrap();
    let signatures: Vec<_> = body["messages"].as_array().unwrap().iter()
        .filter(|message| message["role"] == "assistant")
        .map(|message| message["tool_calls"][0]["extra_content"]["google"]["thought_signature"].clone())
        .collect();
    assert_eq!(signatures, vec![json!(GEMINI_SIGNATURE_FALLBACK), json!("sig-codex")]);
}
