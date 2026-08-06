use super::*;
use serde_json::json;

#[tokio::test]
async fn empty_output_does_not_collapse_an_identical_follow_up_input() {
    let history = CodexHistoryStore::default();
    history
        .record_response_scoped_with_metadata(
            "session-empty-output",
            ResponseOrigin::Local,
            true,
            &json!({"input":"ping"}),
            &json!({"id":"resp_empty","status":"completed","output":[]}),
        )
        .await;
    let mut next = json!({
        "previous_response_id":"resp_empty",
        "input":"ping"
    });

    let resolution = history
        .materialize_request_scoped("session-empty-output", true, &mut next)
        .await;
    assert_eq!(resolution.changed, 1);
    assert!(next.get("previous_response_id").is_none());
    let input = next["input"].as_array().unwrap();
    assert_eq!(input.len(), 2);
    assert_eq!(input[0]["content"], "ping");
    assert_eq!(input[1]["content"], "ping");
}

#[tokio::test]
async fn call_fallback_uses_one_complete_branch_and_never_grafts_onto_previous() {
    let history = CodexHistoryStore::default();
    let scope = "session-fallback-branch";
    for (response_id, call_id, prompt) in [
        ("resp_a", "call_a", "branch a"),
        ("resp_b", "call_b", "branch b"),
    ] {
        history
            .record_response_scoped_with_metadata(
                scope,
                ResponseOrigin::Local,
                true,
                &json!({
                    "input":[{"type":"message","role":"user","content":prompt}]
                }),
                &json!({
                    "id":response_id,"status":"completed",
                    "output":[{
                        "type":"function_call","call_id":call_id,
                        "name":"lookup","arguments":"{}"
                    }]
                }),
            )
            .await;
    }

    let mut one_branch = json!({
        "input":[{
            "type":"function_call_output","call_id":"call_a","output":"a"
        }]
    });
    let resolution = history
        .materialize_request_scoped(scope, true, &mut one_branch)
        .await;
    assert!(!resolution.had_previous_response_id);
    assert_eq!(resolution.changed, 2);
    assert_eq!(one_branch["input"][0]["content"], "branch a");
    assert_eq!(one_branch["input"][1]["call_id"], "call_a");
    assert_eq!(one_branch["input"][2]["call_id"], "call_a");
    history
        .record_response_scoped_with_metadata(
            scope,
            ResponseOrigin::Local,
            true,
            &one_branch,
            &json!({
                "id":"resp_after_fallback","status":"completed",
                "output":[{
                    "type":"message","role":"assistant",
                    "content":[{"type":"output_text","text":"done"}]
                }]
            }),
        )
        .await;
    let mut switched_provider = json!({
        "previous_response_id":"resp_after_fallback",
        "input":"next"
    });
    let switched = history
        .materialize_request_scoped(scope, true, &mut switched_provider)
        .await;
    assert!(switched.previous_materialized);
    assert!(switched_provider.get("previous_response_id").is_none());
    assert_eq!(switched_provider["input"][0]["content"], "branch a");

    let mut mixed_branches = json!({
        "input":[
            {"type":"function_call_output","call_id":"call_a","output":"a"},
            {"type":"function_call_output","call_id":"call_b","output":"b"}
        ]
    });
    assert_eq!(
        history
            .enrich_request_scoped(scope, true, &mut mixed_branches)
            .await,
        0
    );
    assert_eq!(mixed_branches["input"].as_array().unwrap().len(), 2);

    let mut unrelated_to_previous = json!({
        "previous_response_id":"resp_a",
        "input":[{
            "type":"function_call_output","call_id":"call_b","output":"b"
        }]
    });
    history
        .materialize_request_scoped(scope, true, &mut unrelated_to_previous)
        .await;
    let input = unrelated_to_previous["input"].as_array().unwrap();
    assert!(input.iter().any(|item| item["call_id"] == "call_a"));
    assert!(!input
        .iter()
        .any(|item| { item["type"] == "function_call" && item["call_id"] == "call_b" }));
    assert!(crate::protocol::openai_responses::decode_request(&unrelated_to_previous).is_err());
}

#[tokio::test]
async fn previous_response_is_resolved_and_materialized_without_new_input() {
    let history = CodexHistoryStore::default();
    let scope = "session-no-input";
    history
        .record_response_scoped_with_metadata(
            scope,
            ResponseOrigin::Native("provider-a".to_string()),
            true,
            &json!({
                "input":[{"type":"message","role":"user","content":"first"}]
            }),
            &json!({
                "id":"resp_no_input","status":"completed",
                "output":[{
                    "type":"message","id":"msg_no_input","role":"assistant",
                    "content":[{"type":"output_text","text":"answer"}]
                }]
            }),
        )
        .await;
    let mut next = json!({"previous_response_id":"resp_no_input"});

    let resolution = history
        .materialize_request_scoped(scope, true, &mut next)
        .await;
    assert!(resolution.had_previous_response_id);
    assert!(resolution.previous_found);
    assert!(resolution.previous_materialized);
    assert_eq!(
        resolution.previous_origin,
        Some(ResponseOrigin::Native("provider-a".to_string()))
    );
    assert!(next.get("previous_response_id").is_none());
    let input = next["input"].as_array().unwrap();
    assert_eq!(input.len(), 2);
    assert_eq!(input[0]["content"], "first");
    assert_eq!(input[1]["content"][0]["text"], "answer");
}
