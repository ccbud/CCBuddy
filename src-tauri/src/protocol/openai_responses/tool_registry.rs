// Registering Responses tool definitions (function / custom / tool_search / namespace) as the
// flat chat functions an OpenAI Chat upstream accepts.

use super::tools::{
    CodexToolContext, CodexToolKind, CodexToolSpec, APPLY_PATCH_CHAT_INSTRUCTION,
    CUSTOM_TOOL_INPUT_FIELD, CUSTOM_TOOL_RAW_INPUT_INSTRUCTION, TOOL_SEARCH_CHAT_NAME,
};
use llm_connector::types::Tool;
use serde_json::{json, Value};

impl CodexToolContext {
    pub(super) fn add_response_tool(&mut self, tool: &Value) {
        match tool {
            Value::String(name) => self.add_custom_tool(&json!({
                "type": "custom",
                "name": name,
            })),
            Value::Object(_) => match tool.get("type").and_then(Value::as_str) {
                Some("function") | None => self.add_function_tool(tool, None),
                Some("custom") => self.add_custom_tool(tool),
                Some("tool_search") => self.add_tool_search_tool(tool),
                Some("namespace") => self.add_namespace_tool(tool),
                _ => {}
            },
            _ => {}
        }
    }

    fn add_function_tool(&mut self, tool: &Value, namespace: Option<&str>) {
        let function = tool
            .get("function")
            .filter(|value| value.is_object())
            .unwrap_or(tool);
        let Some(name) = function.get("name").and_then(Value::as_str) else {
            return;
        };
        if name.trim().is_empty() {
            return;
        }
        let description = function
            .get("description")
            .and_then(Value::as_str)
            .map(ToString::to_string);
        let parameters = normalize_function_parameters(function.get("parameters"));
        let spec = CodexToolSpec {
            kind: if namespace.is_some() {
                CodexToolKind::Namespace
            } else {
                CodexToolKind::Function
            },
            name: name.to_string(),
            namespace: namespace.map(ToString::to_string),
        };
        self.add_chat_tool(spec, description, parameters);
    }

    fn add_custom_tool(&mut self, tool: &Value) {
        let Some(name) = tool.get("name").and_then(Value::as_str) else {
            return;
        };
        if name.trim().is_empty() {
            return;
        }
        let mut description = tool
            .get("description")
            .and_then(Value::as_str)
            .map(|description| format!("{description}\n\n{CUSTOM_TOOL_RAW_INPUT_INSTRUCTION}"))
            .unwrap_or_else(|| CUSTOM_TOOL_RAW_INPUT_INSTRUCTION.to_string());
        if name == "apply_patch" {
            description.push_str("\n\n");
            description.push_str(APPLY_PATCH_CHAT_INSTRUCTION);
        }
        let parameters = json!({
            "type": "object",
            "properties": {
                "input": {
                    "type": "string",
                    "description": "Raw string input for the original custom tool. Preserve formatting exactly."
                }
            },
            "required": [CUSTOM_TOOL_INPUT_FIELD],
            "additionalProperties": false,
        });
        self.add_chat_tool(
            CodexToolSpec {
                kind: CodexToolKind::Custom,
                name: name.to_string(),
                namespace: None,
            },
            Some(description),
            parameters,
        );
    }

    fn add_tool_search_tool(&mut self, tool: &Value) {
        let description = tool
            .get("description")
            .and_then(Value::as_str)
            .map(ToString::to_string)
            .unwrap_or_else(|| {
                "Search and load Codex tools, plugins, connectors, and MCP namespaces for the current task."
                    .to_string()
            });
        let parameters = if tool.get("parameters").is_some_and(Value::is_object) {
            normalize_function_parameters(tool.get("parameters"))
        } else {
            json!({
                "type": "object",
                "properties": {
                    "query": { "type": "string" },
                    "limit": { "type": "integer" }
                },
                "required": ["query"],
                "additionalProperties": false,
            })
        };
        self.add_chat_tool(
            CodexToolSpec {
                kind: CodexToolKind::ToolSearch,
                name: TOOL_SEARCH_CHAT_NAME.to_string(),
                namespace: None,
            },
            Some(description),
            parameters,
        );
    }

    fn add_namespace_tool(&mut self, tool: &Value) {
        let Some(namespace) = tool.get("name").and_then(Value::as_str) else {
            return;
        };
        if namespace.trim().is_empty() {
            return;
        }
        let Some(children) = tool
            .get("tools")
            .or_else(|| tool.get("children"))
            .and_then(Value::as_array)
        else {
            return;
        };
        for child in children {
            if child.get("type").and_then(Value::as_str) == Some("function") {
                self.add_function_tool(child, Some(namespace));
            }
        }
    }

    fn add_chat_tool(
        &mut self,
        spec: CodexToolSpec,
        description: Option<String>,
        parameters: Value,
    ) {
        if self.spec_to_chat_name.contains_key(&spec) {
            return;
        }
        let chat_name = self.reserve_chat_name(&spec);
        self.ir_tools
            .push(Tool::function(chat_name.clone(), description, parameters));
    }

    pub(super) fn register_tool_identity(&mut self, spec: CodexToolSpec) {
        if self.spec_to_chat_name.contains_key(&spec) {
            return;
        }
        self.reserve_chat_name(&spec);
    }
}

fn normalize_function_parameters(parameters: Option<&Value>) -> Value {
    let mut parameters = parameters
        .filter(|value| value.is_object())
        .cloned()
        .unwrap_or_else(|| json!({ "type": "object", "properties": {} }));
    if let Some(object) = parameters.as_object_mut() {
        if object.get("type").and_then(Value::as_str) != Some("object") {
            object.insert("type".to_string(), json!("object"));
        }
        object
            .entry("properties".to_string())
            .or_insert_with(|| json!({}));
    }
    parameters
}
