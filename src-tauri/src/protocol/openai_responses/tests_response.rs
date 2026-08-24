use super::*;
use llm_connector::protocols::adapters::openai::OpenAIProtocol;
use serde_json::{json, Value};

#[test]
fn encodes_ir_to_responses_response_with_tool_calls() {
    // A chat upstream reply with prose + a tool call → the Responses body Codex consumes.
    use llm_connector::core::Protocol;
    let chat = r#"{
            "id":"chatcmpl-9","object":"chat.completion","created":1,"model":"gpt-4o",
            "choices":[{"index":0,"finish_reason":"tool_calls","message":{
                "role":"assistant","content":"Checking.",
                "tool_calls":[{"id":"call_9","type":"function",
                    "function":{"name":"shell","arguments":"{\"command\":[\"ls\"]}"}}]}}],
            "usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}
        }"#;
    let ir = OpenAIProtocol::new("").parse_response(chat).unwrap();
    let out = encode_response(&ir, "z-ai/glm-5.2");
    assert_eq!(out["object"], "response");
    assert_eq!(out["status"], "completed");
    assert_eq!(out["model"], "z-ai/glm-5.2");
    assert_eq!(out["usage"]["input_tokens"], 11);
    assert_eq!(out["usage"]["output_tokens"], 7);
    assert_eq!(out["usage"]["total_tokens"], 18);
    let output = out["output"].as_array().unwrap();
    let m = output.iter().find(|i| i["type"] == "message").unwrap();
    assert_eq!(m["content"][0]["type"], "output_text");
    assert_eq!(m["content"][0]["text"], "Checking.");
    let fc = output
        .iter()
        .find(|i| i["type"] == "function_call")
        .unwrap();
    assert_eq!(
        fc["call_id"],
        response_scoped_call_id(out["id"].as_str().unwrap(), 0)
    );
    assert_eq!(fc["name"], "shell");
    assert_eq!(fc["arguments"], "{\"command\":[\"ls\"]}");
}

#[test]
fn synthesized_responses_sse_carries_items_and_completed() {
    use llm_connector::core::Protocol;
    let chat = r#"{
            "id":"c1","object":"chat.completion","created":1,"model":"up",
            "choices":[{"index":0,"finish_reason":"tool_calls","message":{
                "role":"assistant","content":"On it.",
                "tool_calls":[{"id":"call_2","type":"function",
                    "function":{"name":"apply_patch","arguments":"{\"p\":1}"}}]}}],
            "usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}
        }"#;
    let ir = OpenAIProtocol::new("").parse_response(chat).unwrap();
    let sse = encode_response_sse(&ir, "alias-model");
    // ordered: created → message item events → function_call item events → completed
    let created = sse.find("\"type\":\"response.created\"").unwrap();
    let item_done = sse.find("response.output_item.done").unwrap();
    let completed = sse.find("\"type\":\"response.completed\"").unwrap();
    assert!(created < item_done && item_done < completed);
    // Codex reads items exclusively from output_item.done: both items must appear there.
    assert!(sse.contains(r#""delta":"On it.""#));
    assert!(sse.contains(&format!(
        r#""call_id":"{}""#,
        response_scoped_call_id("resp_c1", 0)
    )));
    assert!(sse.contains(r#""name":"apply_patch""#));
    assert!(sse.contains(r#""arguments":"{\"p\":1}""#));
    // completed carries id + usage (codex errors without them)
    assert!(sse.contains(r#""input_tokens":5"#));
    assert!(sse.contains(r#""output_tokens":3"#));
    assert!(sse.contains(r#""id":"resp_c1""#));
}

#[test]
fn buffered_duplicate_upstream_call_ids_become_unique_and_response_scoped() {
    use llm_connector::core::Protocol;

    let parse = |response_id: &str| {
        OpenAIProtocol::new("")
            .parse_response(
                &json!({
                    "id":response_id,
                    "object":"chat.completion",
                    "created":1,
                    "model":"up",
                    "choices":[{"index":0,"finish_reason":"tool_calls","message":{
                        "role":"assistant","content":"",
                        "tool_calls":[
                            {"id":"same","type":"function","function":{"name":"first","arguments":"{}"}},
                            {"id":"same","type":"function","function":{"name":"second","arguments":"{}"}}
                        ]
                    }}]
                })
                .to_string(),
            )
            .unwrap()
    };
    let first = encode_response(&parse("turn-1"), "alias");
    let second = encode_response(&parse("turn-2"), "alias");
    let call_ids = |response: &Value| {
        response["output"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|item| item.get("call_id").and_then(Value::as_str))
            .map(str::to_string)
            .collect::<Vec<_>>()
    };
    let first_ids = call_ids(&first);
    let second_ids = call_ids(&second);

    assert_eq!(first_ids.len(), 2);
    assert_ne!(first_ids[0], first_ids[1]);
    assert_ne!(first_ids[0], second_ids[0]);
    assert_eq!(
        first_ids[0],
        response_scoped_call_id(first["id"].as_str().unwrap(), 0)
    );
    assert_eq!(
        first_ids[1],
        response_scoped_call_id(first["id"].as_str().unwrap(), 1)
    );
}

#[test]
fn buffered_truncation_stays_incomplete_across_responses_encoding() {
    use llm_connector::core::Protocol;
    let chat = r#"{
            "id":"c-length","object":"chat.completion","created":1,"model":"up",
            "choices":[{"index":0,"finish_reason":"length","message":{
                "role":"assistant","content":"partial"}}],
            "usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}
        }"#;
    let ir = OpenAIProtocol::new("").parse_response(chat).unwrap();
    let response = encode_response(&ir, "alias-model");
    assert_eq!(response["status"], "incomplete");
    assert_eq!(
        response["incomplete_details"]["reason"],
        "max_output_tokens"
    );

    let sse = encode_response_sse(&ir, "alias-model");
    assert!(sse.contains("event: response.incomplete"));
    assert!(!sse.contains("event: response.completed"));

    let decoded = decode_response(&response.to_string()).unwrap();
    assert_eq!(decoded.choices[0].finish_reason.as_deref(), Some("length"));
    let failed = json!({
        "id":"resp_failed","status":"failed",
        "error":{"message":"provider failed"}
    });
    assert_eq!(
        decode_response(&failed.to_string()).unwrap_err(),
        "provider failed"
    );
}
