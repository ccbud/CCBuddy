use super::*;
use super::types::{HistoryInner, MAX_CACHED_RESPONSES};
use serde_json::json;

#[test]
fn oversized_insert_preserves_unrelated_entries_and_drops_stale_replacement() {
    let keep_request = vec![json!({
        "type":"message","role":"user","content":"keep"
    })];
    let keep_output = vec![json!({
        "type":"function_call","call_id":"call_keep",
        "name":"keep_tool","arguments":"{}"
    })];
    let oversized_request = vec![json!({
        "type":"message","role":"user","content":"x".repeat(2048)
    })];
    let oversized_output = vec![json!({
        "type":"function_call","call_id":"call_huge",
        "name":"huge_tool","arguments":"y".repeat(2048)
    })];

    let scope = "session-1";
    let keep_key = (scope.to_string(), "resp_keep".to_string());
    let mut probe = HistoryInner::default();
    probe.insert_response(
        scope,
        "resp_keep",
        keep_request.clone(),
        keep_output.clone(),
    );
    let budget = probe.responses[&keep_key].serialized_bytes;

    let mut inner = HistoryInner::default();
    assert_eq!(
        inner.insert_response_with_limits(
            scope,
            "resp_keep",
            keep_request,
            keep_output,
            MAX_CACHED_RESPONSES,
            budget,
        ),
        1
    );
    assert_eq!(
        inner.insert_response_with_limits(
            scope,
            "resp_huge",
            oversized_request.clone(),
            oversized_output.clone(),
            MAX_CACHED_RESPONSES,
            budget,
        ),
        0
    );
    assert!(inner.responses.contains_key(&keep_key));
    assert_eq!(inner.cached_bytes, budget);
    assert!(inner.unique_call(scope, "call_huge").is_none());

    assert_eq!(
        inner.insert_response_with_limits(
            scope,
            "resp_keep",
            oversized_request,
            oversized_output,
            MAX_CACHED_RESPONSES,
            budget,
        ),
        0
    );
    assert!(inner.responses.is_empty());
    assert!(inner.response_order.is_empty());
    assert!(inner.call_index.is_empty());
    assert_eq!(inner.cached_bytes, 0);
}

#[tokio::test]
async fn native_history_materializes_across_provider_boundaries_and_strips_previous_id() {
    let history = CodexHistoryStore::default();
    let scope = "session-native";
    history
        .record_response_scoped_with_metadata(
            scope,
            ResponseOrigin::Native("provider-a".to_string()),
            true,
            &json!({
                "input":[{"type":"message","role":"user","content":"first"}]
            }),
            &json!({
                "id":"resp_native_a","status":"completed",
                "output":[{
                    "type":"message","id":"msg_native_a","role":"assistant",
                    "content":[{"type":"output_text","text":"answer"}]
                }]
            }),
        )
        .await;
    let mut next = json!({
        "previous_response_id":"resp_native_a",
        "input":[{"type":"message","role":"user","content":"second"}]
    });

    let resolution = history
        .materialize_request_scoped(scope, true, &mut next)
        .await;
    assert!(resolution.previous_found);
    assert!(resolution.previous_materialized);
    assert_eq!(
        resolution.previous_origin,
        Some(ResponseOrigin::Native("provider-a".to_string()))
    );
    assert!(next.get("previous_response_id").is_none());
    let decoded = crate::protocol::openai_responses::decode_request(&next).unwrap();
    assert_eq!(
        decoded
            .messages
            .iter()
            .map(|message| message.content_as_text())
            .collect::<Vec<_>>(),
        vec!["first", "answer", "second"]
    );
}

#[tokio::test]
async fn owner_only_native_history_is_reported_but_never_materialized() {
    let history = CodexHistoryStore::default();
    let scope = "session-owner-only";
    history
        .record_response_scoped_with_metadata(
            scope,
            ResponseOrigin::Native("provider-a".to_string()),
            false,
            &json!({
                "previous_response_id":"unknown-before-restart",
                "input":[{"type":"message","role":"user","content":"delta"}]
            }),
            &json!({
                "id":"resp_owner_only","status":"completed",
                "output":[{
                    "type":"message","id":"msg_owner_only","role":"assistant",
                    "content":[{"type":"output_text","text":"answer"}]
                }]
            }),
        )
        .await;
    let mut next = json!({
        "previous_response_id":"resp_owner_only",
        "input":[{"type":"message","role":"user","content":"next"}]
    });
    let before = next.clone();

    let resolution = history
        .materialize_request_scoped(scope, true, &mut next)
        .await;
    assert!(resolution.previous_found);
    assert!(!resolution.previous_materialized);
    assert_eq!(
        resolution.previous_origin,
        Some(ResponseOrigin::Native("provider-a".to_string()))
    );
    assert_eq!(next, before);
}

