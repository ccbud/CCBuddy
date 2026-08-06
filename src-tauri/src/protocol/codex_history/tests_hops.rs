use super::*;
use serde_json::json;

#[tokio::test]
async fn restores_request_and_response_context_across_multiple_hops() {
    let history = CodexHistoryStore::default();
    let first_request = json!({
        "input":[{"type":"message","role":"user","content":"First question."}]
    });
    let first_response = json!({
        "id":"resp_first",
        "output":[{
            "type":"message","id":"msg_first","role":"assistant",
            "content":[{"type":"output_text","text":"First answer."}]
        }]
    });
    assert_eq!(
        history
            .record_response(&first_request, &first_response)
            .await,
        1
    );

    let mut second_request = json!({
        "previous_response_id":"resp_first",
        "input":[{"type":"message","role":"user","content":"Second question."}]
    });
    assert_eq!(history.enrich_request(&mut second_request).await, 2);
    let second_response = json!({
        "id":"resp_second",
        "output":[{
            "type":"message","id":"msg_second","role":"assistant",
            "content":[{"type":"output_text","text":"Second answer."}]
        }]
    });
    assert_eq!(
        history
            .record_response(&second_request, &second_response)
            .await,
        1
    );

    let mut third_request = json!({
        "previous_response_id":"resp_second",
        "input":[{"type":"message","role":"user","content":"Third question."}]
    });
    assert_eq!(history.enrich_request(&mut third_request).await, 4);
    let decoded = crate::protocol::openai_responses::decode_request(&third_request).unwrap();
    let transcript = decoded
        .messages
        .iter()
        .map(|message| message.content_as_text())
        .collect::<Vec<_>>();
    assert_eq!(
        transcript,
        vec![
            "First question.",
            "First answer.",
            "Second question.",
            "Second answer.",
            "Third question.",
        ]
    );

    // Full explicit history plus previous_response_id must remain idempotent.
    let before = third_request.clone();
    assert_eq!(history.enrich_request(&mut third_request).await, 0);
    assert_eq!(third_request, before);
}

#[tokio::test]
async fn restores_parallel_calls_as_one_ordered_group() {
    let history = CodexHistoryStore::default();
    history
        .record_response(
            &json!({ "input": [] }),
            &json!({
                "id": "resp_parallel",
                "output": [
                    {"type":"function_call","call_id":"call_a","name":"first","arguments":"{}"},
                    {"type":"function_call","call_id":"call_b","name":"second","arguments":"{}"}
                ]
            }),
        )
        .await;

    // Outputs may arrive in a different order. The assistant call group must
    // retain the order in which the response originally emitted the calls.
    let mut request = json!({
        "previous_response_id": "resp_parallel",
        "input": [
            {"type":"function_call_output","call_id":"call_b","output":"two"},
            {"type":"function_call_output","call_id":"call_a","output":"one"}
        ]
    });

    assert_eq!(history.enrich_request(&mut request).await, 2);
    let input = request["input"].as_array().unwrap();
    assert_eq!(input[0]["call_id"], "call_a");
    assert_eq!(input[1]["call_id"], "call_b");
    assert_eq!(input[2]["type"], "function_call_output");
    assert_eq!(input[3]["type"], "function_call_output");
}

#[tokio::test]
async fn same_client_session_recovers_across_provider_switches() {
    let history = CodexHistoryStore::default();
    // The scope deliberately contains no provider identity: switching the active provider
    // must not sever the client's previous_response_id chain.
    let scope = "session-1";
    history
        .record_response_scoped(
            scope,
            &json!({ "input": [] }),
            &json!({
                "id": "resp_1",
                "output": [{
                    "type":"function_call",
                    "call_id":"unique_call",
                    "name":"lookup",
                    "arguments":"{}"
                }]
            }),
        )
        .await;

    for previous in [None, Some("stale_response"), Some("resp_1")] {
        let mut request = json!({
            "input": [{
                "type":"function_call_output",
                "call_id":"unique_call",
                "output":"ok"
            }]
        });
        if let Some(previous) = previous {
            request["previous_response_id"] = json!(previous);
        }

        assert_eq!(
            history
                .enrich_request_scoped(scope, true, &mut request)
                .await,
            1
        );
        assert_eq!(request["input"][0]["type"], "function_call");
        assert_eq!(request["input"][0]["name"], "lookup");
    }
}

#[tokio::test]
async fn missing_previous_response_fallback_requires_a_safe_scope() {
    let history = CodexHistoryStore::default();
    history
        .record_response(
            &json!({ "input": [] }),
            &json!({
                "id":"resp_1",
                "output":[{
                    "type":"function_call","call_id":"call_1",
                    "name":"lookup","arguments":"{}"
                }]
            }),
        )
        .await;
    let mut request = json!({
        "input":[{
            "type":"function_call_output","call_id":"call_1","output":"ok"
        }]
    });

    assert_eq!(history.enrich_request(&mut request).await, 0);
    assert!(crate::protocol::openai_responses::decode_request(&request).is_err());
}

