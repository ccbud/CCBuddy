// Walking a Codex Responses request for tool definitions and tool identities that are not in the
// top-level `tools` array (Responses Lite `additional_tools`, `tool_search_output`, history calls).

use super::tools::{CodexToolContext, CodexToolKind, CodexToolSpec, TOOL_SEARCH_CHAT_NAME};
use serde_json::Value;

pub(super) fn collect_additional_tools(value: &Value, context: &mut CodexToolContext) {
    match value {
        Value::Array(items) => {
            for item in items {
                collect_additional_tools(item, context);
            }
        }
        Value::Object(object) => {
            if object.get("type").and_then(Value::as_str) == Some("additional_tools") {
                if let Some(tools) = object.get("tools").and_then(Value::as_array) {
                    for tool in tools {
                        context.add_response_tool(tool);
                    }
                }
            }
            for child in object.values() {
                collect_additional_tools(child, context);
            }
        }
        _ => {}
    }
}

pub(super) fn collect_tool_search_output_tools(value: &Value, context: &mut CodexToolContext) {
    match value {
        Value::Array(items) => {
            for item in items {
                collect_tool_search_output_tools(item, context);
            }
        }
        Value::Object(object) => {
            if object.get("type").and_then(Value::as_str) == Some("tool_search_output") {
                if let Some(tools) = object.get("tools").and_then(Value::as_array) {
                    for tool in tools {
                        context.add_response_tool(tool);
                    }
                }
            }
            for child in object.values() {
                collect_tool_search_output_tools(child, context);
            }
        }
        _ => {}
    }
}

pub(super) fn collect_response_tool_call_identities(value: &Value, context: &mut CodexToolContext) {
    match value {
        Value::Array(items) => {
            for item in items {
                collect_response_tool_call_identities(item, context);
            }
        }
        Value::Object(object) => {
            let spec = match object.get("type").and_then(Value::as_str) {
                Some("function_call") => object
                    .get("name")
                    .and_then(Value::as_str)
                    .filter(|name| !name.trim().is_empty())
                    .map(|name| {
                        let namespace = object
                            .get("namespace")
                            .and_then(Value::as_str)
                            .filter(|namespace| !namespace.is_empty());
                        CodexToolSpec {
                            kind: if namespace.is_some() {
                                CodexToolKind::Namespace
                            } else {
                                CodexToolKind::Function
                            },
                            name: name.to_string(),
                            namespace: namespace.map(ToString::to_string),
                        }
                    }),
                Some("custom_tool_call") => object
                    .get("name")
                    .and_then(Value::as_str)
                    .filter(|name| !name.trim().is_empty())
                    .map(|name| CodexToolSpec {
                        kind: CodexToolKind::Custom,
                        name: name.to_string(),
                        namespace: None,
                    }),
                Some("tool_search_call") => Some(CodexToolSpec {
                    kind: CodexToolKind::ToolSearch,
                    name: TOOL_SEARCH_CHAT_NAME.to_string(),
                    namespace: None,
                }),
                _ => None,
            };
            if let Some(spec) = spec {
                context.register_tool_identity(spec);
            }
            for child in object.values() {
                collect_response_tool_call_identities(child, context);
            }
        }
        _ => {}
    }
}

pub(super) fn collect_tool_choice_identity(tool_choice: Option<&Value>, context: &mut CodexToolContext) {
    let Some(tool_choice) = tool_choice.filter(|value| value.is_object()) else {
        return;
    };
    let spec = match tool_choice.get("type").and_then(Value::as_str) {
        Some("function") => tool_choice
            .get("name")
            .and_then(Value::as_str)
            .or_else(|| {
                tool_choice
                    .get("function")
                    .and_then(|function| function.get("name"))
                    .and_then(Value::as_str)
            })
            .filter(|name| !name.trim().is_empty())
            .map(|name| {
                let namespace = tool_choice
                    .get("namespace")
                    .and_then(Value::as_str)
                    .filter(|namespace| !namespace.is_empty());
                CodexToolSpec {
                    kind: if namespace.is_some() {
                        CodexToolKind::Namespace
                    } else {
                        CodexToolKind::Function
                    },
                    name: name.to_string(),
                    namespace: namespace.map(ToString::to_string),
                }
            }),
        Some("custom") => tool_choice
            .get("name")
            .and_then(Value::as_str)
            .filter(|name| !name.trim().is_empty())
            .map(|name| CodexToolSpec {
                kind: CodexToolKind::Custom,
                name: name.to_string(),
                namespace: None,
            }),
        Some("tool_search") => Some(CodexToolSpec {
            kind: CodexToolKind::ToolSearch,
            name: TOOL_SEARCH_CHAT_NAME.to_string(),
            namespace: None,
        }),
        _ => None,
    };
    if let Some(spec) = spec {
        context.register_tool_identity(spec);
    }
}
