use super::*;
use llm_connector::core::Protocol;
use llm_connector::protocols::adapters::openai::OpenAIProtocol;
use llm_connector::types::ReasoningEffort;
use serde_json::{json, Value};

fn codex_responses_lite_request() -> Value {
    json!({
        "model": "gpt-5.6-sol-pro",
        "input": [
            {
                "type": "additional_tools",
                "role": "developer",
                "tools": [
                    {
                        "type": "custom",
                        "name": "exec",
                        "description": "Run JavaScript that can call nested Codex tools.",
                        "format": {
                            "type": "grammar",
                            "syntax": "lark",
                            "definition": "start: /[\\s\\S]+/"
                        }
                    },
                    {
                        "type": "function",
                        "name": "wait",
                        "description": "Wait for a yielded exec cell.",
                        "parameters": {
                            "type": "object",
                            "properties": { "cell_id": { "type": "string" } },
                            "required": ["cell_id"],
                            "additionalProperties": false
                        }
                    },
                    {
                        "type": "function",
                        "name": "request_user_input",
                        "description": "Ask the user a question.",
                        "parameters": {
                            "type": "object",
                            "properties": { "question": { "type": "string" } },
                            "required": ["question"]
                        }
                    },
                    {
                        "type": "namespace",
                        "name": "collaboration",
                        "tools": [{
                            "type": "function",
                            "name": "spawn_agent",
                            "description": "Spawn a sub-agent.",
                            "parameters": {
                                "type": "object",
                                "properties": { "task_name": { "type": "string" } },
                                "required": ["task_name"]
                            }
                        }]
                    }
                ]
            },
            {
                "type": "message",
                "role": "developer",
                "content": [{ "type": "input_text", "text": "You are Codex." }]
            },
            {
                "type": "message",
                "role": "user",
                "content": [{ "type": "input_text", "text": "Inspect the project." }]
            }
        ],
        "tool_choice": "auto",
        "parallel_tool_calls": false,
        "reasoning": { "effort": "ultra", "summary": "none", "context": "all_turns" },
        "stream": true
    })
}

#[test]
fn decodes_responses_lite_additional_tools_and_restores_custom_calls() {
    let (ir, context) = decode_request_with_context(&codex_responses_lite_request()).unwrap();

    let roles = ir
        .messages
        .iter()
        .map(|message| format!("{:?}", message.role))
        .collect::<Vec<_>>();
    assert_eq!(roles, vec!["System", "User"]);
    assert_eq!(ir.messages[0].content_as_text(), "You are Codex.");

    let tools = ir.tools.as_ref().unwrap();
    let names = tools
        .iter()
        .map(|tool| tool.function.name.as_str())
        .collect::<Vec<_>>();
    assert_eq!(
        names,
        vec![
            "exec",
            "wait",
            "request_user_input",
            "collaboration__spawn_agent"
        ]
    );
    assert_eq!(
        context.lookup_chat_name("exec").map(|spec| spec.kind),
        Some(CodexToolKind::Custom)
    );
    assert_eq!(ir.enable_thinking, Some(true));
    assert_eq!(ir.thinking_budget, Some(32768));
    assert_eq!(ir.reasoning_effort, Some(ReasoningEffort::High));

    let chat_request = OpenAIProtocol::new("")
        .build_chat_request_body(&ir)
        .unwrap();
    assert_eq!(chat_request["tools"].as_array().map(Vec::len), Some(4));
    assert_eq!(chat_request["reasoning_effort"], "high");

    let chat_response = r#"{
            "id":"chatcmpl-lite","object":"chat.completion","created":1,"model":"up",
            "choices":[{"index":0,"finish_reason":"tool_calls","message":{
                "role":"assistant","content":null,
                "tool_calls":[{"id":"call_exec","type":"function","function":{
                    "name":"exec","arguments":"{\"input\":\"const result = await tools.exec_command({cmd: \\\"pwd\\\"});\"}"
                }}]
            }}],
            "usage":{"prompt_tokens":9,"completion_tokens":4,"total_tokens":13}
        }"#;
    let response_ir = OpenAIProtocol::new("")
        .parse_response(chat_response)
        .unwrap();
    let response = encode_response_with_context(&response_ir, "gpt-5.6-sol-pro", &context);
    let exec = response["output"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["type"] == "custom_tool_call")
        .unwrap();
    assert_eq!(exec["name"], "exec");
    assert_eq!(
        exec["input"],
        "const result = await tools.exec_command({cmd: \"pwd\"});"
    );
}
