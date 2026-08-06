use super::*;
use super::materialize::request_input_is_materializable;
use serde_json::json;

#[test]
fn responses_lite_additional_tools_are_materializable() {
    let request = json!({
        "input": [{
            "type": "additional_tools",
            "role": "developer",
            "tools": [
                { "type": "custom", "name": "exec" },
                {
                    "type": "namespace",
                    "name": "collaboration",
                    "tools": [{ "type": "function", "name": "spawn_agent" }]
                }
            ]
        }]
    });
    assert!(request_input_is_materializable(&request));
}

#[tokio::test]
async fn restores_call_before_output_from_previous_response() {
    let history = CodexHistoryStore::default();
    assert_eq!(
        history
            .record_response(
                &json!({ "input": [] }),
                &json!({
                    "id": "resp_1",
                    "output": [{
                        "type": "function_call",
                        "call_id": "call_1",
                        "name": "read_file",
                        "arguments": "{\"path\":\"README.md\"}",
                        "reasoning_content": "Need to inspect the file."
                    }]
                })
            )
            .await,
        1
    );

    let mut request = json!({
        "previous_response_id": "resp_1",
        "input": [{
            "type": "function_call_output",
            "call_id": "call_1",
            "output": "ok"
        }]
    });

    assert_eq!(history.enrich_request(&mut request).await, 1);
    let input = request["input"].as_array().unwrap();
    assert_eq!(input[0]["type"], "function_call");
    assert_eq!(input[0]["name"], "read_file");
    assert_eq!(input[0]["reasoning_content"], "Need to inspect the file.");
    assert_eq!(input[1]["type"], "function_call_output");

    // The restored item-level reasoning must survive the JSON → chat IR half,
    // not merely remain present in the enriched request body.
    let decoded = crate::protocol::openai_responses::decode_request(&request).unwrap();
    assert_eq!(
        decoded.messages[0].reasoning_content.as_deref(),
        Some("Need to inspect the file.")
    );
    assert_eq!(
        decoded.messages[0].tool_calls.as_ref().unwrap()[0].id,
        "call_1"
    );
}

#[tokio::test]
async fn restores_text_continuation_and_deduplicates_explicit_prior_output() {
    let history = CodexHistoryStore::default();
    let reasoning = json!({
        "type":"reasoning",
        "id":"rs_text",
        "summary":[{"type":"summary_text","text":"continue the thought"}]
    });
    let assistant = json!({
        "type":"message",
        "id":"msg_text",
        "role":"assistant",
        "content":[{"type":"output_text","text":"First answer."}]
    });
    assert_eq!(
        history
            .record_response(
                &json!({ "input": [] }),
                &json!({
                    "id":"resp_text",
                    "output":[reasoning.clone(), assistant.clone()]
                })
            )
            .await,
        2
    );

    let mut continuation = json!({
        "previous_response_id":"resp_text",
        "input":"Continue."
    });
    assert_eq!(history.enrich_request(&mut continuation).await, 2);
    let input = continuation["input"].as_array().unwrap();
    assert_eq!(input.len(), 3);
    assert_eq!(input[0]["id"], "rs_text");
    assert_eq!(input[1]["id"], "msg_text");
    assert_eq!(input[2]["role"], "user");

    let decoded = crate::protocol::openai_responses::decode_request(&continuation).unwrap();
    assert_eq!(decoded.messages.len(), 2);
    assert_eq!(decoded.messages[0].content_as_text(), "First answer.");
    assert_eq!(
        decoded.messages[0].reasoning_content.as_deref(),
        Some("continue the thought")
    );
    assert_eq!(decoded.messages[1].content_as_text(), "Continue.");

    // A client may send explicit history even while retaining previous_response_id.
    // Stable item ids anchor that history, so the cache must not duplicate it.
    let mut explicit = json!({
        "previous_response_id":"resp_text",
        "input":[
            reasoning,
            assistant,
            {"type":"message","role":"user","content":"Continue."}
        ]
    });
    assert_eq!(history.enrich_request(&mut explicit).await, 0);
    assert_eq!(explicit["input"].as_array().unwrap().len(), 3);
}

