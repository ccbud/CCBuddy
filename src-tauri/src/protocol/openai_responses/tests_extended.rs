use super::*;
use llm_connector::protocols::adapters::openai::OpenAIProtocol;
use serde_json::{json, Value};

fn codex_request_with_extended_tools() -> Value {
    json!({
        "model": "gpt-5.4",
        "input": [
            { "type": "reasoning", "summary": [{ "type": "summary_text", "text": "use tools" }] },
            { "type": "custom_tool_call", "id": "ctc_1", "call_id": "call_custom",
              "name": "apply_patch", "input": "*** Begin Patch\n*** End Patch" },
            { "type": "custom_tool_call_output", "call_id": "call_custom", "output": "Done!" },
            { "type": "function_call", "id": "fc_1", "call_id": "call_spawn",
              "namespace": "multi_agent_v1", "name": "spawn_agent",
              "arguments": "{\"task_name\":\"audit\"}" },
            { "type": "function_call_output", "call_id": "call_spawn", "output": "spawned" },
            { "type": "tool_search_call", "call_id": "call_search", "status": "completed",
              "execution": "client", "arguments": { "query": "browser", "limit": 3 } },
            { "type": "tool_search_output", "call_id": "call_search", "status": "completed",
              "execution": "client", "tools": [
                { "type": "custom", "name": "exec", "description": "Run JavaScript" }
              ] }
        ],
        "tools": [
            { "type": "custom", "name": "apply_patch", "description": "Apply a patch",
              "format": { "type": "grammar", "syntax": "lark", "definition": "start: /.+/" } },
            { "type": "namespace", "name": "multi_agent_v1", "tools": [
                { "type": "function", "name": "spawn_agent", "description": "Spawn an agent",
                  "parameters": { "type": "object", "properties": {
                      "task_name": { "type": "string" }
                  }, "required": ["task_name"] } }
            ] },
            { "type": "tool_search", "execution": "client",
              "description": "Search deferred tools from Drive and MCP; always prefer this over MCP listing.",
              "parameters": { "type": "object", "properties": {
                  "query": { "type": "string" }, "limit": { "type": "number" }
              }, "required": ["query"], "additionalProperties": false } }
        ]
    })
}

#[test]
fn preserves_custom_namespace_and_tool_search_request_semantics() {
    let (ir, context) =
        decode_request_with_context(&codex_request_with_extended_tools()).unwrap();
    let tools = ir.tools.as_ref().unwrap();
    let names = tools
        .iter()
        .map(|tool| tool.function.name.as_str())
        .collect::<Vec<_>>();
    assert!(names.contains(&"apply_patch"));
    assert!(names.contains(&"multi_agent_v1__spawn_agent"));
    assert!(names.contains(&"tool_search"));
    assert!(names.contains(&"exec"));
    let search = tools
        .iter()
        .find(|tool| tool.function.name == "tool_search")
        .unwrap();
    assert!(search
        .function
        .description
        .as_deref()
        .unwrap()
        .contains("always prefer this"));

    let calls = ir
        .messages
        .iter()
        .filter_map(|message| message.tool_calls.as_ref())
        .flatten()
        .collect::<Vec<_>>();
    let custom = calls
        .iter()
        .find(|call| call.function.name == "apply_patch")
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&custom.function.arguments).unwrap()["input"],
        "*** Begin Patch\n*** End Patch"
    );
    assert!(calls
        .iter()
        .any(|call| call.function.name == "multi_agent_v1__spawn_agent"));
    assert!(calls.iter().any(|call| call.function.name == "tool_search"));
    assert_eq!(
        context
            .lookup_chat_name("multi_agent_v1__spawn_agent")
            .unwrap()
            .kind,
        CodexToolKind::Namespace
    );
}

#[test]
fn restores_extended_tool_types_in_buffered_response_and_sse() {
    use llm_connector::core::Protocol;

    let (_, context) =
        decode_request_with_context(&codex_request_with_extended_tools()).unwrap();
    let chat = r#"{
            "id":"chatcmpl-tools","object":"chat.completion","created":1,"model":"up",
            "choices":[{"index":0,"finish_reason":"tool_calls","message":{
                "role":"assistant","content":null,"reasoning_content":"pick the right tools",
                "tool_calls":[
                    {"id":"call_custom","type":"function","function":{"name":"apply_patch","arguments":"{\"input\":\"*** Begin Patch\\n*** End Patch\"}"}},
                    {"id":"call_spawn","type":"function","function":{"name":"multi_agent_v1__spawn_agent","arguments":"{\"task_name\":\"audit\"}"}},
                    {"id":"call_search","type":"function","function":{"name":"tool_search","arguments":"{\"query\":\"browser\",\"limit\":3}"}}
                ]}}],
            "usage":{"prompt_tokens":9,"completion_tokens":4,"total_tokens":13}
        }"#;
    let ir = OpenAIProtocol::new("").parse_response(chat).unwrap();
    let response = encode_response_with_context(&ir, "gpt-5.4", &context);
    let output = response["output"].as_array().unwrap();

    let custom = output
        .iter()
        .find(|item| item["type"] == "custom_tool_call")
        .unwrap();
    assert_eq!(custom["name"], "apply_patch");
    assert_eq!(custom["input"], "*** Begin Patch\n*** End Patch");
    assert_eq!(custom["reasoning_content"], "pick the right tools");

    let namespaced = output
        .iter()
        .find(|item| item["namespace"] == "multi_agent_v1")
        .unwrap();
    assert_eq!(namespaced["type"], "function_call");
    assert_eq!(namespaced["name"], "spawn_agent");
    assert_eq!(namespaced["namespace"], "multi_agent_v1");

    let search = output
        .iter()
        .find(|item| item["type"] == "tool_search_call")
        .unwrap();
    assert!(search.get("id").is_none());
    assert_eq!(search["arguments"]["query"], "browser");
    assert_eq!(search["arguments"]["limit"], 3);

    let sse = encode_response_sse_with_context(&ir, "gpt-5.4", &context);
    assert!(sse.contains("event: response.custom_tool_call_input.delta"));
    assert!(sse.contains("event: response.custom_tool_call_input.done"));
    assert!(sse.contains(r#""type":"custom_tool_call""#));
    assert!(sse.contains(r#""type":"tool_search_call""#));
    assert!(sse.contains(r#""namespace":"multi_agent_v1""#));
}

