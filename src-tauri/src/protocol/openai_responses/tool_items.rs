// Rebuilding Responses output items from a chat-shaped tool call: the item id prefix and the
// exact `function_call` / `custom_tool_call` / `tool_search_call` shape Codex expects back.

use super::helpers::{custom_tool_input_from_chat_arguments, parse_tool_arguments_object};
use super::tools::{CodexToolContext, CodexToolKind};
use serde_json::{json, Value};

impl CodexToolContext {
    pub(crate) fn response_item_id(
        &self,
        chat_name: &str,
        response_id: &str,
        index: usize,
    ) -> String {
        let prefix = match self.kind_for_chat_name(chat_name) {
            CodexToolKind::Custom => "ctc",
            CodexToolKind::ToolSearch => "tsc",
            CodexToolKind::Function | CodexToolKind::Namespace => "fc",
        };
        format!(
            "{}_{}_{}",
            prefix,
            response_id.trim_start_matches("resp_"),
            index
        )
    }

    pub(crate) fn response_tool_item(
        &self,
        item_id: &str,
        status: &str,
        call_id: &str,
        chat_name: &str,
        arguments: &str,
    ) -> Value {
        self.response_tool_item_with_reasoning(item_id, status, call_id, chat_name, arguments, None)
    }

    pub(crate) fn response_tool_item_with_reasoning(
        &self,
        item_id: &str,
        status: &str,
        call_id: &str,
        chat_name: &str,
        arguments: &str,
        reasoning: Option<&str>,
    ) -> Value {
        let mut item = match self.lookup_chat_name(chat_name) {
            Some(spec) if spec.kind == CodexToolKind::Custom => json!({
                "type": "custom_tool_call",
                "id": item_id,
                "status": status,
                "call_id": call_id,
                "name": spec.name,
                "input": custom_tool_input_from_chat_arguments(arguments),
            }),
            Some(spec) if spec.kind == CodexToolKind::ToolSearch => json!({
                "type": "tool_search_call",
                "status": status,
                "call_id": call_id,
                "execution": "client",
                "arguments": parse_tool_arguments_object(arguments),
            }),
            Some(spec) => {
                let mut item = json!({
                    "type": "function_call",
                    "id": item_id,
                    "status": status,
                    "call_id": call_id,
                    "name": spec.name,
                    "arguments": if arguments.is_empty() { "{}" } else { arguments },
                });
                if let Some(namespace) = spec.namespace.as_deref().filter(|value| !value.is_empty())
                {
                    item["namespace"] = json!(namespace);
                }
                item
            }
            None => json!({
                "type": "function_call",
                "id": item_id,
                "status": status,
                "call_id": call_id,
                "name": chat_name,
                "arguments": if arguments.is_empty() { "{}" } else { arguments },
            }),
        };
        if let Some(reasoning) = reasoning.map(str::trim).filter(|value| !value.is_empty()) {
            item["reasoning_content"] = json!(reasoning);
        }
        item
    }
}
