use axum::body::to_bytes;
use axum::http::{StatusCode, Uri};
use serde_json::{json, Value};

use super::models::synthesize_models;
use super::responses_history::apply_responses_chat_request_controls;
use super::selftest_routing::routing_selftest;
use super::targets::{build_target, cross_wire_compact_error, endpoint_targets};

#[test]
fn routing_parity_with_proxy_js() {
    let r = routing_selftest();
    assert_eq!(r.get("failed").and_then(|v| v.as_i64()), Some(0), "routing mismatch: {:?}", r);
    assert_eq!(r.get("passed").and_then(|v| v.as_i64()), Some(9));
}
#[test]
fn synthesize_models_includes_claude_tiers() {
    let cfg = json!({ "providers": [{ "id": "p", "defaultModel": "m", "smallFastModel": "m" }], "activeProviderId": "p" });
    let s = synthesize_models(&cfg, false);
    let ids: Vec<&str> = s["data"].as_array().unwrap().iter().filter_map(|m| m["id"].as_str()).collect();
    assert!(ids.contains(&"claude-sonnet-5"));
    assert!(ids.contains(&"claude-fable-5"));
    assert!(!ids.iter().any(|id| id.starts_with("gpt-")));
}
#[test]
fn synthesize_models_codex_returns_gpt_tiers() {
    let cfg = json!({ "providers": [{ "id": "p", "defaultModel": "m", "smallFastModel": "m" }], "activeProviderId": "p" });
    let s = synthesize_models(&cfg, true);
    let ids: Vec<&str> = s["data"].as_array().unwrap().iter().filter_map(|m| m["id"].as_str()).collect();
    assert!(ids.contains(&"gpt-5.4"));
    assert!(ids.contains(&"gpt-5.4-mini"));
    assert!(!ids.iter().any(|id| id.starts_with("claude-")));
}
#[test]
fn responses_chat_translation_preserves_parallel_tool_calls() {
    let mut body = json!({ "model": "upstream", "messages": [] });
    apply_responses_chat_request_controls(
        &mut body,
        &json!({ "parallel_tool_calls": false }),
    );
    assert_eq!(body["parallel_tool_calls"], false);

    let mut absent = json!({ "model": "upstream", "messages": [] });
    apply_responses_chat_request_controls(&mut absent, &json!({}));
    assert!(absent.get("parallel_tool_calls").is_none());
}
#[test]
fn build_target_collapses_path_overlap() {
    let u = |s: &str| s.parse::<Uri>().unwrap();
    // openai-* provider / sidecar plugin: base ends in /v1 and the client path
    // repeats /v1 → collapse (was ".../v1/v1/responses" → 404).
    assert_eq!(build_target("http://127.0.0.1:57085/v1", &u("/v1/responses")).unwrap(), "http://127.0.0.1:57085/v1/responses");
    assert_eq!(build_target("http://127.0.0.1:57085/v1", &u("/v1/models?x=1")).unwrap(), "http://127.0.0.1:57085/v1/models?x=1");
    // non-overlapping prefix (anthropic providers) → plain concat, unchanged.
    assert_eq!(build_target("https://api.deepseek.com/anthropic", &u("/v1/messages")).unwrap(), "https://api.deepseek.com/anthropic/v1/messages");
    // base without a path → unchanged.
    assert_eq!(build_target("http://127.0.0.1:9", &u("/v1/responses")).unwrap(), "http://127.0.0.1:9/v1/responses");
    // segment-aware: a /v1 base must NOT eat a /v1beta path.
    assert_eq!(build_target("http://h/v1", &u("/v1beta/x")).unwrap(), "http://h/v1/v1beta/x");
}
#[test]
fn primary_endpoints_use_the_configured_base_and_offer_one_v1_fallback() {
    let u = |s: &str| s.parse::<Uri>().unwrap();
    assert_eq!(
        endpoint_targets("https://example.com/api", &u("/v1/messages?x=1")),
        Some((
            "https://example.com/api/messages?x=1".to_string(),
            Some("https://example.com/api/v1/messages?x=1".to_string()),
        ))
    );
    assert_eq!(
        endpoint_targets("https://example.com/v4", &u("/v1/chat/completions")),
        Some(("https://example.com/v4/chat/completions".to_string(), None))
    );
    assert_eq!(
        endpoint_targets("https://example.com/v1", &u("/v1/responses")),
        Some(("https://example.com/v1/responses".to_string(), None))
    );
    assert_eq!(
        endpoint_targets("https://example.com/v1", &u("/v1/responses/compact")),
        Some(("https://example.com/v1/responses/compact".to_string(), None))
    );
    assert_eq!(
        endpoint_targets(
            "https://generativelanguage.googleapis.com/v1beta/openai",
            &u("/v1/chat/completions"),
        ),
        Some((
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions".to_string(),
            None,
        ))
    );
    assert_eq!(endpoint_targets("https://example.com/api", &u("/v1/models")), None);
    assert_eq!(endpoint_targets("https://example.com/api", &u("/v1/messages/count_tokens")), None);
}
#[tokio::test]
async fn compact_rejects_cross_wire_and_allows_responses_passthrough() {
    for provider_wire in [
        crate::protocol::Wire::OpenAiChat,
        crate::protocol::Wire::Anthropic,
    ] {
        let response = cross_wire_compact_error("/v1/responses/compact/", provider_wire)
            .expect("cross-wire compact must be rejected locally");
        assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
        let body = to_bytes(response.into_body(), 4096).await.unwrap();
        let error: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(error["error"]["type"], "invalid_request_error");
        assert!(error["error"]["message"]
            .as_str()
            .unwrap()
            .contains("cross-protocol compaction is not supported"));
    }

    assert!(cross_wire_compact_error(
        "/v1/responses/compact",
        crate::protocol::Wire::OpenAiResponses,
    )
    .is_none());
    assert!(cross_wire_compact_error(
        "/v1/responses",
        crate::protocol::Wire::OpenAiChat,
    )
    .is_none());
}
