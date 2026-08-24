use super::types::{HistoryInner, MAX_CACHED_RESPONSES};
use super::*;
use serde_json::{json, Value};
use std::sync::Arc;

#[tokio::test]
async fn concurrent_recording_is_safe_and_searchable() {
    let history = Arc::new(CodexHistoryStore::default());
    let scope = "session-1";
    let mut tasks = Vec::new();
    for index in 0..16 {
        let history = history.clone();
        tasks.push(tokio::spawn(async move {
            history
                .record_response_scoped(
                    scope,
                    &json!({ "input": [] }),
                    &json!({
                        "id": format!("resp_{index}"),
                        "output": [{
                            "type":"function_call",
                            "call_id":format!("call_{index}"),
                            "name":"work",
                            "arguments":"{}"
                        }]
                    }),
                )
                .await
        }));
    }
    for task in tasks {
        assert_eq!(task.await.unwrap(), 1);
    }

    let mut request = json!({
        "input":[{
            "type":"function_call_output",
            "call_id":"call_9",
            "output":"done"
        }]
    });
    assert_eq!(
        history
            .enrich_request_scoped(scope, true, &mut request)
            .await,
        1
    );
    assert_eq!(request["input"][0]["call_id"], "call_9");
    assert_eq!(request["input"][0]["name"], "work");
}

#[test]
fn byte_budget_evicts_oldest_responses_and_cleans_call_index() {
    let old_request = vec![json!({
        "type":"message","role":"user","content":"old request"
    })];
    let old_output = vec![json!({
        "type":"function_call",
        "call_id":"shared_call",
        "name":"old_tool",
        "arguments":"{\"value\":\"old\"}"
    })];
    let new_request = vec![json!({
        "type":"message","role":"user","content":"new request"
    })];
    let new_output = vec![json!({
        "type":"function_call",
        "call_id":"shared_call",
        "name":"new_tool",
        "arguments":"{\"value\":\"new\"}"
    })];
    let mut probe = HistoryInner::default();
    let scope = "session-1";
    let new_key = (scope.to_string(), "resp_new".to_string());
    let old_key = (scope.to_string(), "resp_old".to_string());
    probe.insert_response(scope, "resp_new", new_request.clone(), new_output.clone());
    let newest_size = probe.responses[&new_key].serialized_bytes;

    let mut inner = HistoryInner::default();
    assert_eq!(
        inner.insert_response_with_limits(
            scope,
            "resp_old",
            old_request,
            old_output,
            MAX_CACHED_RESPONSES,
            usize::MAX,
        ),
        1
    );
    assert_eq!(
        inner.insert_response_with_limits(
            scope,
            "resp_new",
            new_request,
            new_output,
            MAX_CACHED_RESPONSES,
            newest_size,
        ),
        1
    );

    assert_eq!(inner.cached_bytes, newest_size);
    assert!(!inner.responses.contains_key(&old_key));
    assert!(inner.responses.contains_key(&new_key));
    assert_eq!(
        inner
            .unique_call(scope, "shared_call")
            .and_then(|item| item.get("name"))
            .and_then(Value::as_str),
        Some("new_tool")
    );
}

#[test]
fn same_id_replacement_keeps_exact_accounting_and_no_stale_call_index() {
    let mut inner = HistoryInner::default();
    let scope = "session-1";
    let response_key = (scope.to_string(), "resp_same".to_string());
    let call_key = (scope.to_string(), "call_new".to_string());
    assert_eq!(
        inner.insert_response(
            scope,
            "resp_same",
            vec![json!({"type":"message","role":"user","content":"short"})],
            vec![json!({
                "type":"function_call","call_id":"call_old",
                "name":"old_tool","arguments":"{}"
            })],
        ),
        1
    );
    assert_eq!(
        inner.insert_response(
            scope,
            "resp_same",
            vec![json!({
                "type":"message","role":"user",
                "content":"a longer authoritative replacement"
            })],
            vec![json!({
                "type":"function_call","call_id":"call_new",
                "name":"new_tool","arguments":"{\"ok\":true}"
            })],
        ),
        1
    );

    let replacement_bytes = inner.responses[&response_key].serialized_bytes;
    assert_eq!(inner.response_order.len(), 1);
    assert_eq!(inner.cached_bytes, replacement_bytes);
    assert!(inner.unique_call(scope, "call_old").is_none());
    assert_eq!(
        inner
            .unique_call(scope, "call_new")
            .and_then(|item| item.get("name"))
            .and_then(Value::as_str),
        Some("new_tool")
    );

    // Replaying the same completed response must not duplicate order/index entries or bytes.
    let request = inner.responses[&response_key].request_input.clone();
    let output = inner.responses[&response_key].output.clone();
    assert_eq!(
        inner.insert_response(scope, "resp_same", request, output),
        1
    );
    assert_eq!(inner.response_order.len(), 1);
    assert_eq!(inner.cached_bytes, replacement_bytes);
    assert_eq!(inner.call_index[&call_key].len(), 1);
}
