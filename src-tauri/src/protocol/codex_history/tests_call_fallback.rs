use super::*;
use serde_json::json;

#[tokio::test]
async fn call_id_fallback_never_crosses_client_session_scope() {
    let history = CodexHistoryStore::default();
    history
        .record_response_scoped(
            "session-a",
            &json!({"input":[]}),
            &json!({
                "id":"resp_a",
                "output":[{
                    "type":"function_call","call_id":"call_a",
                    "name":"lookup","arguments":"{}"
                }]
            }),
        )
        .await;
    let mut request = json!({
        "previous_response_id":"stale",
        "input":[{
            "type":"function_call_output","call_id":"call_a","output":"ok"
        }]
    });

    assert_eq!(
        history
            .enrich_request_scoped("session-b", true, &mut request)
            .await,
        0
    );
    assert!(crate::protocol::openai_responses::decode_request(&request).is_err());
}

#[tokio::test]
async fn ambiguous_call_id_does_not_use_fallback() {
    let history = CodexHistoryStore::default();
    let scope = "session-1";
    for response_id in ["resp_1", "resp_2"] {
        history
            .record_response_scoped(
                scope,
                &json!({ "input": [] }),
                &json!({
                    "id": response_id,
                    "output": [{
                        "type":"function_call",
                        "call_id":"shared_call",
                        "name":"lookup",
                        "arguments":"{}"
                    }]
                }),
            )
            .await;
    }

    let mut request = json!({
        "input": [{
            "type":"function_call_output",
            "call_id":"shared_call",
            "output":"ok"
        }]
    });

    assert_eq!(
        history
            .enrich_request_scoped(scope, true, &mut request)
            .await,
        0
    );
    assert_eq!(request["input"].as_array().unwrap().len(), 1);
    assert_eq!(request["input"][0]["type"], "function_call_output");
    let error = crate::protocol::openai_responses::decode_request(&request).unwrap_err();
    assert!(error.contains("shared_call"));
}

#[tokio::test]
async fn enriches_existing_call_without_duplicating_it() {
    let history = CodexHistoryStore::default();
    history
        .record_response(
            &json!({ "input": [] }),
            &json!({
                "id": "resp_1",
                "output": [{
                    "type":"function_call",
                    "call_id":"call_1",
                    "name":"read_file",
                    "arguments":"{\"path\":\"README.md\"}",
                    "reasoning_content":"Need the file."
                }]
            }),
        )
        .await;

    let mut request = json!({
        "previous_response_id":"resp_1",
        "input":[
            {"type":"function_call","call_id":"call_1"},
            {"type":"function_call_output","call_id":"call_1","output":"ok"}
        ]
    });

    assert_eq!(history.enrich_request(&mut request).await, 1);
    let input = request["input"].as_array().unwrap();
    assert_eq!(input.len(), 2);
    assert_eq!(input[0]["name"], "read_file");
    assert_eq!(input[0]["arguments"], "{\"path\":\"README.md\"}");
    assert_eq!(input[0]["reasoning_content"], "Need the file.");
}

#[tokio::test]
async fn restores_custom_and_tool_search_calls() {
    let history = CodexHistoryStore::default();
    assert_eq!(
        history
            .record_response(
                &json!({ "input": [] }),
                &json!({
                    "id":"resp_tools",
                    "output":[
                        {
                            "type":"custom_tool_call",
                            "call_id":"call_patch",
                            "name":"apply_patch",
                            "input":"*** Begin Patch\n*** End Patch"
                        },
                        {
                            "type":"tool_search_call",
                            "call_id":"call_search",
                            "status":"completed",
                            "execution":"client",
                            "arguments":{"query":"mail tools"}
                        }
                    ]
                })
            )
            .await,
        2
    );

    let mut request = json!({
        "previous_response_id":"resp_tools",
        "input":[
            {"type":"custom_tool_call_output","call_id":"call_patch","output":"patched"},
            {"type":"tool_search_output","call_id":"call_search","tools":[]}
        ]
    });

    assert_eq!(history.enrich_request(&mut request).await, 2);
    let input = request["input"].as_array().unwrap();
    assert_eq!(input[0]["type"], "custom_tool_call");
    assert_eq!(input[0]["input"], "*** Begin Patch\n*** End Patch");
    assert_eq!(input[1]["type"], "tool_search_call");
    assert_eq!(input[2]["type"], "custom_tool_call_output");
    assert_eq!(input[3]["type"], "tool_search_output");
}

#[tokio::test]
async fn preserves_scalar_and_single_object_input_when_no_change_is_needed() {
    let history = CodexHistoryStore::default();
    let mut scalar_request = json!({"input":"hello"});
    assert_eq!(history.enrich_request(&mut scalar_request).await, 0);
    assert_eq!(scalar_request["input"], "hello");

    let mut request = json!({
        "input": {"type":"message","role":"user","content":"hello"}
    });

    assert_eq!(history.enrich_request(&mut request).await, 0);
    assert!(request["input"].is_object());
    assert_eq!(request["input"]["content"], "hello");
}
