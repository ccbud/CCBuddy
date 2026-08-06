use super::tests_aliases::assert_valid_chat_tool_alias;
use super::*;
use serde_json::json;
use std::collections::HashSet;

#[test]
fn keeps_colliding_function_custom_search_and_namespace_identities_distinct() {
    let definitions = vec![
        json!({ "type": "function", "name": "same" }),
        json!({ "type": "custom", "name": "same" }),
        json!({ "type": "function", "name": "tool_search" }),
        json!({ "type": "tool_search" }),
        json!({ "type": "function", "name": "a__b" }),
        json!({ "type": "namespace", "name": "a", "tools": [
            { "type": "function", "name": "b" }
        ] }),
    ];
    let req = json!({ "tools": definitions });
    let mut reversed_definitions = req["tools"].as_array().unwrap().clone();
    reversed_definitions.reverse();
    let reversed_req = json!({ "tools": reversed_definitions });
    let context = CodexToolContext::from_request(&req);
    let reversed_context = CodexToolContext::from_request(&reversed_req);
    let specs = vec![
        CodexToolSpec {
            kind: CodexToolKind::Function,
            name: "same".into(),
            namespace: None,
        },
        CodexToolSpec {
            kind: CodexToolKind::Custom,
            name: "same".into(),
            namespace: None,
        },
        CodexToolSpec {
            kind: CodexToolKind::Function,
            name: "tool_search".into(),
            namespace: None,
        },
        CodexToolSpec {
            kind: CodexToolKind::ToolSearch,
            name: "tool_search".into(),
            namespace: None,
        },
        CodexToolSpec {
            kind: CodexToolKind::Function,
            name: "a__b".into(),
            namespace: None,
        },
        CodexToolSpec {
            kind: CodexToolKind::Namespace,
            name: "b".into(),
            namespace: Some("a".into()),
        },
    ];

    assert_eq!(context.ir_tools().len(), specs.len());
    let aliases = specs
        .iter()
        .map(|spec| {
            let alias = context.chat_name_for_spec(spec);
            assert_valid_chat_tool_alias(&alias);
            assert_eq!(context.lookup_chat_name(&alias), Some(spec));
            assert_eq!(alias, reversed_context.chat_name_for_spec(spec));
            alias
        })
        .collect::<HashSet<_>>();
    assert_eq!(aliases.len(), specs.len());

    let function_search_alias = context.chat_name_for_spec(&specs[2]);
    let function_search = context.response_tool_item(
        "fc_search",
        "completed",
        "call_fn_search",
        &function_search_alias,
        "{}",
    );
    assert_eq!(function_search["type"], "function_call");
    assert_eq!(function_search["name"], "tool_search");

    let actual_search_alias = context.chat_name_for_spec(&specs[3]);
    let actual_search = context.response_tool_item(
        "tsc_search",
        "completed",
        "call_search",
        &actual_search_alias,
        r#"{"query":"x"}"#,
    );
    assert_eq!(actual_search["type"], "tool_search_call");
}

#[test]
fn custom_tool_description_omits_full_definition_and_lark_grammar() {
    let req = json!({
        "tools": [{
            "type": "custom",
            "name": "apply_patch",
            "description": "Apply a patch to the workspace.",
            "format": {
                "type": "grammar",
                "syntax": "lark",
                "definition": "start: patch+\npatch: /.+/"
            }
        }]
    });
    let context = CodexToolContext::from_request(&req);
    let tool = &context.ir_tools()[0];
    let description = tool.function.description.as_deref().unwrap();
    assert!(description.starts_with(
        "Apply a patch to the workspace.\n\nPass the custom tool's raw input unchanged in the `input` string field."
    ));
    assert!(description.contains("*** Add File: path"));
    assert!(
        description.contains("*** Begin Patch\n*** Add File: path\n+content\n*** End Patch")
    );
    assert!(description.contains("never prefix either boundary marker"));
    assert!(!description.contains("Original Responses custom-tool definition"));
    assert!(!description.contains("definition"));
    assert!(!description.contains("start: patch"));
    assert!(!description.contains("lark"));
}
