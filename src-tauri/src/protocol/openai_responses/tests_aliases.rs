use super::tool_names::is_valid_chat_tool_name;
use super::tools::CHAT_TOOL_NAME_MAX_LEN;
use super::*;
use serde_json::json;

pub(super) fn assert_valid_chat_tool_alias(alias: &str) {
    assert!(
        is_valid_chat_tool_name(alias),
        "invalid Chat tool alias: {alias:?}"
    );
    assert!(alias.is_ascii());
    assert!(alias.len() <= CHAT_TOOL_NAME_MAX_LEN);
}

#[test]
fn aliases_illegal_tool_names_and_restores_exact_response_identities() {
    let req = json!({
        "model": "gpt-5.4",
        "input": [
            { "type": "function_call", "call_id": "call_fn", "name": "read file/现在", "arguments": "{}" },
            { "type": "custom_tool_call", "call_id": "call_custom", "name": "apply.patch/β", "input": "raw" },
            { "type": "function_call", "call_id": "call_ns", "namespace": "multi agent/一",
              "name": "spawn.agent?", "arguments": "{}" }
        ],
        "tools": [
            { "type": "function", "name": "read file/现在" },
            { "type": "custom", "name": "apply.patch/β" },
            { "type": "namespace", "name": "multi agent/一", "tools": [
                { "type": "function", "name": "spawn.agent?" }
            ] }
        ]
    });
    let (ir, context) = decode_request_with_context(&req).unwrap();
    let tools = ir.tools.as_ref().unwrap();
    assert_eq!(tools.len(), 3);
    for tool in tools {
        assert_valid_chat_tool_alias(&tool.function.name);
    }
    for call in ir
        .messages
        .iter()
        .filter_map(|message| message.tool_calls.as_ref())
        .flatten()
    {
        assert_valid_chat_tool_alias(&call.function.name);
    }

    let function_alias = context.chat_name_for_response_tool("read file/现在", None);
    let function_item =
        context.response_tool_item("fc_fn", "completed", "call_fn", &function_alias, "{}");
    assert_eq!(function_item["type"], "function_call");
    assert_eq!(function_item["name"], "read file/现在");

    let custom_alias = context.chat_name_for_custom_tool("apply.patch/β");
    let custom_item = context.response_tool_item(
        "ctc_custom",
        "completed",
        "call_custom",
        &custom_alias,
        r#"{"input":"raw"}"#,
    );
    assert_eq!(custom_item["type"], "custom_tool_call");
    assert_eq!(custom_item["name"], "apply.patch/β");
    assert_eq!(custom_item["input"], "raw");

    let namespace_alias =
        context.chat_name_for_response_tool("spawn.agent?", Some("multi agent/一"));
    let namespace_item =
        context.response_tool_item("fc_ns", "completed", "call_ns", &namespace_alias, "{}");
    assert_eq!(namespace_item["type"], "function_call");
    assert_eq!(namespace_item["namespace"], "multi agent/一");
    assert_eq!(namespace_item["name"], "spawn.agent?");
}

#[test]
fn aliases_long_utf8_names_deterministically_within_64_bytes() {
    let first_name = format!("读取工具-{}-甲", "界".repeat(40));
    let second_name = format!("读取工具-{}-乙", "界".repeat(40));
    let req = json!({
        "tools": [
            { "type": "function", "name": first_name },
            { "type": "function", "name": second_name }
        ]
    });
    let first_context = CodexToolContext::from_request(&req);
    let second_context = CodexToolContext::from_request(&req);
    let first_alias = first_context.chat_name_for_response_tool(&first_name, None);
    let second_alias = first_context.chat_name_for_response_tool(&second_name, None);
    assert_valid_chat_tool_alias(&first_alias);
    assert_valid_chat_tool_alias(&second_alias);
    assert_ne!(first_alias, second_alias);
    assert_eq!(
        first_alias,
        second_context.chat_name_for_response_tool(&first_name, None)
    );
    assert_eq!(
        second_alias,
        second_context.chat_name_for_response_tool(&second_name, None)
    );

    let restored =
        first_context.response_tool_item("fc_long", "completed", "call_long", &first_alias, "{}");
    assert_eq!(restored["name"], first_name);
}
