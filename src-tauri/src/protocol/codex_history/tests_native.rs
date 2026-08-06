use super::*;
use serde_json::json;

#[tokio::test]
async fn incomplete_response_remains_resumable_history() {
    let history = CodexHistoryStore::default();
    let scope = "session-incomplete";
    history
        .record_response_scoped_with_metadata(
            scope,
            ResponseOrigin::Local,
            true,
            &json!({
                "input":[{"type":"message","role":"user","content":"write a lot"}]
            }),
            &json!({
                "id":"resp_incomplete","status":"incomplete",
                "incomplete_details":{"reason":"max_output_tokens"},
                "output":[{
                    "type":"message","id":"msg_partial","role":"assistant",
                    "content":[{"type":"output_text","text":"partial"}]
                }]
            }),
        )
        .await;
    let mut next = json!({
        "previous_response_id":"resp_incomplete",
        "input":[{"type":"message","role":"user","content":"continue"}]
    });

    let resolution = history
        .materialize_request_scoped(scope, true, &mut next)
        .await;
    assert!(resolution.previous_materialized);
    assert!(next.get("previous_response_id").is_none());
    let decoded = crate::protocol::openai_responses::decode_request(&next).unwrap();
    assert_eq!(
        decoded
            .messages
            .iter()
            .map(|message| message.content_as_text())
            .collect::<Vec<_>>(),
        vec!["write a lot", "partial", "continue"]
    );
}

#[tokio::test]
async fn metadata_recording_rejects_non_resumable_terminals() {
    let history = CodexHistoryStore::default();
    let request = json!({
        "input":[{"type":"message","role":"user","content":"hello"}]
    });
    for response in [
        json!({"id":"resp_failed","status":"failed","output":[]}),
        json!({"id":"resp_partial","output":[]}),
        json!({
            "id":"resp_compaction","object":"response.compaction","status":"completed",
            "output":[{"type":"compaction","encrypted_content":"opaque"}]
        }),
    ] {
        assert_eq!(
            history
                .record_response_scoped_with_metadata(
                    "session-terminal",
                    ResponseOrigin::Native("provider-a".to_string()),
                    true,
                    &request,
                    &response,
                )
                .await,
            0
        );
        assert!(history
            .response_metadata("session-terminal", response["id"].as_str().unwrap())
            .await
            .is_none());
    }
}

#[tokio::test]
async fn unsupported_output_and_owner_only_calls_never_become_portable_fallback() {
    let history = CodexHistoryStore::default();
    let scope = "session-partial";
    history
        .record_response_scoped_with_metadata(
            scope,
            ResponseOrigin::Native("provider-a".to_string()),
            true,
            &json!({"input":[{"type":"message","role":"user","content":"look"}]}),
            &json!({
                "id":"resp_unsupported","object":"response","status":"completed",
                "output":[{"type":"computer_call","id":"computer_1"}]
            }),
        )
        .await;
    assert_eq!(
        history
            .response_metadata(scope, "resp_unsupported")
            .await
            .unwrap(),
        ResponseMetadata {
            origin: ResponseOrigin::Native("provider-a".to_string()),
            materializable: false,
        }
    );

    history
        .record_response_scoped_with_metadata(
            scope,
            ResponseOrigin::Native("provider-a".to_string()),
            false,
            &json!({
                "previous_response_id":"missing-prefix",
                "input":[{"type":"message","role":"user","content":"run"}]
            }),
            &json!({
                "id":"resp_owner_call","status":"completed",
                "output":[{
                    "type":"function_call","call_id":"call_owner_only",
                    "name":"shell","arguments":"{}"
                }]
            }),
        )
        .await;
    let mut fallback = json!({
        "input":[{
            "type":"function_call_output","call_id":"call_owner_only","output":"ok"
        }]
    });
    assert_eq!(
        history
            .enrich_request_scoped(scope, true, &mut fallback)
            .await,
        0
    );
    assert_eq!(fallback["input"].as_array().unwrap().len(), 1);

    history
        .record_response_scoped_with_metadata(
            scope,
            ResponseOrigin::Native("provider-a".to_string()),
            true,
            &json!({
                "input":[{"type":"compaction","encrypted_content":"opaque-prefix"}]
            }),
            &json!({
                "id":"resp_compacted_input","status":"completed",
                "output":[{
                    "type":"message","role":"assistant",
                    "content":[{"type":"output_text","text":"answer"}]
                }]
            }),
        )
        .await;
    assert!(
        !history
            .response_metadata(scope, "resp_compacted_input")
            .await
            .unwrap()
            .materializable
    );
}

