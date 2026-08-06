use super::*;
use super::super::openai_responses::CodexToolContext;
use serde_json::json;

fn extended_tool_context() -> CodexToolContext {
    CodexToolContext::from_request(&json!({
        "tools": [
            { "type": "custom", "name": "apply_patch", "description": "Apply a patch" },
            { "type": "namespace", "name": "multi_agent_v1", "tools": [
                { "type": "function", "name": "spawn_agent", "description": "Spawn",
                  "parameters": { "type": "object", "properties": {
                      "task_name": { "type": "string" }
                  }, "required": ["task_name"] } }
            ] },
            { "type": "tool_search", "execution": "client",
              "description": "Search deferred tools.",
              "parameters": { "type": "object", "properties": {
                  "query": { "type": "string" }
              }, "required": ["query"] } }
        ]
    }))
}

#[test]
fn chat_stream_restores_custom_and_tool_search_calls() {
    let mut tc = ChatToResponses::new_with_context("alias-x", extended_tool_context());
    let mut out = String::new();
    out.push_str(&tc.push(
        r#"data: {"id":"chatcmpl-tools","choices":[{"index":0,"delta":{"reasoning_content":"choose tools"}}]}"#,
    ));
    out.push_str(&tc.push(
        r#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_patch","type":"function","function":{"name":"apply_patch","arguments":"{\"input\":\"*** Begin"}},{"index":1,"id":"call_search","type":"function","function":{"name":"tool_search","arguments":"{\"query\":\"browser\"}"}}]}}]}"#,
    ));
    out.push_str(&tc.push(
        r#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" Patch\"}"}}]},"finish_reason":"tool_calls"}]}"#,
    ));
    out.push_str(&tc.push("data: [DONE]"));

    assert!(out.contains("event: response.custom_tool_call_input.delta"));
    assert!(out.contains("event: response.custom_tool_call_input.done"));
    assert!(out.contains(r#""type":"custom_tool_call""#));
    assert!(out.contains(r#""input":"*** Begin Patch""#));
    assert!(out.contains(r#""type":"tool_search_call""#));
    assert!(out.contains(r#""arguments":{"query":"browser"}"#));
    assert!(out.contains(r#""reasoning_content":"choose tools""#));
    assert!(out.contains(r#""type":"response.completed""#));
}

#[test]
fn anthropic_stream_restores_namespace_and_custom_calls() {
    let mut tc = AnthropicToResponses::new_with_context("alias-x", extended_tool_context());
    let mut out = String::new();
    out.push_str(&tc.push(
        r#"data: {"type":"message_start","message":{"id":"msg_tools","usage":{"input_tokens":3}}}"#,
    ));
    out.push_str(&tc.push(
        r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
    ));
    out.push_str(&tc.push(
        r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"delegate"}}"#,
    ));
    out.push_str(&tc.push(r#"data: {"type":"content_block_stop","index":0}"#));
    out.push_str(&tc.push(
        r#"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_spawn","name":"multi_agent_v1__spawn_agent","input":{}}}"#,
    ));
    out.push_str(&tc.push(
        r#"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"task_name\":\"audit\"}"}}"#,
    ));
    out.push_str(&tc.push(r#"data: {"type":"content_block_stop","index":1}"#));
    out.push_str(&tc.push(
        r#"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_patch","name":"apply_patch","input":{"input":"*** Begin Patch"}}}"#,
    ));
    out.push_str(&tc.push(r#"data: {"type":"content_block_stop","index":2}"#));
    out.push_str(&tc.push(
        r#"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}"#,
    ));
    out.push_str(&tc.push(r#"data: {"type":"message_stop"}"#));

    assert!(out.contains(r#""type":"function_call""#));
    assert!(out.contains(r#""name":"spawn_agent""#));
    assert!(out.contains(r#""namespace":"multi_agent_v1""#));
    assert!(out.contains(r#""reasoning_content":"delegate""#));
    assert!(out.contains("event: response.custom_tool_call_input.delta"));
    assert!(out.contains("event: response.custom_tool_call_input.done"));
    assert!(out.contains(r#""type":"custom_tool_call""#));
    assert!(out.contains(r#""input":"*** Begin Patch""#));
    assert!(out.contains(r#""type":"response.completed""#));
}
