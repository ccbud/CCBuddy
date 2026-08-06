// Codex tool metadata shared by the Responses request decoder and the Responses response
// encoders: the tool identity types and the request-scoped registry built from a Codex request.

use super::tool_collect::{
    collect_additional_tools, collect_response_tool_call_identities, collect_tool_choice_identity,
    collect_tool_search_output_tools,
};
use llm_connector::types::Tool;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

pub(super) const CUSTOM_TOOL_INPUT_FIELD: &str = "input";
pub(super) const CUSTOM_TOOL_RAW_INPUT_INSTRUCTION: &str =
    "Pass the custom tool's raw input unchanged in the `input` string field.";
pub(super) const APPLY_PATCH_CHAT_INSTRUCTION: &str = "For apply_patch, the first line must be `*** Begin Patch` and the final line must be an unprefixed `*** End Patch`. Exact Add File skeleton:\n*** Begin Patch\n*** Add File: path\n+content\n*** End Patch\nPrefix every added file-content line with `+`, but never prefix either boundary marker. For updates, use `*** Update File: path` with an `@@` context hunk and ` `, `-`, or `+` line prefixes; for deletion, use `*** Delete File: path`.";
pub(super) const TOOL_SEARCH_CHAT_NAME: &str = "tool_search";
pub(super) const CHAT_TOOL_NAME_MAX_LEN: usize = 64;
pub(super) const CHAT_TOOL_NAME_HASH_LEN: usize = 12;

/// The Responses tool shape that a chat-compatible upstream is standing in for.
///
/// OpenAI Chat only has flat JSON-schema functions, while current Codex requests also carry
/// freeform custom tools, tool search, and namespace tools. The translation layer flattens all of
/// them to chat functions, then uses this metadata to restore the exact Responses item type on the
/// way back to Codex.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CodexToolKind {
    Function,
    Namespace,
    Custom,
    ToolSearch,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct CodexToolSpec {
    pub kind: CodexToolKind,
    pub name: String,
    pub namespace: Option<String>,
}

/// Request-scoped tool metadata used by both buffered and streaming Responses encoders.
///
/// Build this from the original Codex request before decoding it to the connector IR. Loaded tools
/// embedded in `tool_search_output` history are included, so subsequent calls can be translated
/// even when their definitions are not repeated in the top-level `tools` array.
#[derive(Clone, Debug, Default)]
pub struct CodexToolContext {
    pub(super) ir_tools: Vec<Tool>,
    pub(super) seen_chat_names: HashSet<String>,
    pub(super) colliding_preferred_names: HashSet<String>,
    pub(super) chat_name_to_spec: HashMap<String, CodexToolSpec>,
    pub(super) spec_to_chat_name: HashMap<CodexToolSpec, String>,
}

impl CodexToolContext {
    pub fn from_request(req: &Value) -> Self {
        let mut context = Self::default();
        if let Some(tools) = req.get("tools").and_then(Value::as_array) {
            for tool in tools {
                context.add_response_tool(tool);
            }
        }
        if let Some(input) = req.get("input") {
            // Codex Responses Lite (used by gpt-5.6-sol*) moves the complete tool registry out
            // of the top-level `tools` field and into an `additional_tools` developer item. Treat
            // those definitions exactly like top-level tools; the item itself is request metadata,
            // not a chat message.
            collect_additional_tools(input, &mut context);
            collect_tool_search_output_tools(input, &mut context);
            collect_response_tool_call_identities(input, &mut context);
        }
        collect_tool_choice_identity(req.get("tool_choice"), &mut context);
        context
    }

    pub fn ir_tools(&self) -> Vec<Tool> {
        self.ir_tools.clone()
    }

    pub fn lookup_chat_name(&self, chat_name: &str) -> Option<&CodexToolSpec> {
        self.chat_name_to_spec.get(chat_name)
    }

    pub fn kind_for_chat_name(&self, chat_name: &str) -> CodexToolKind {
        self.lookup_chat_name(chat_name)
            .map(|spec| spec.kind)
            .unwrap_or(CodexToolKind::Function)
    }

    pub fn chat_name_for_response_tool(&self, name: &str, namespace: Option<&str>) -> String {
        let namespace = namespace.filter(|value| !value.is_empty());
        self.chat_name_for_spec(&CodexToolSpec {
            kind: if namespace.is_some() {
                CodexToolKind::Namespace
            } else {
                CodexToolKind::Function
            },
            name: name.to_string(),
            namespace: namespace.map(ToString::to_string),
        })
    }

    pub(super) fn chat_name_for_custom_tool(&self, name: &str) -> String {
        self.chat_name_for_spec(&CodexToolSpec {
            kind: CodexToolKind::Custom,
            name: name.to_string(),
            namespace: None,
        })
    }

    pub(super) fn chat_name_for_tool_search(&self) -> String {
        self.chat_name_for_spec(&CodexToolSpec {
            kind: CodexToolKind::ToolSearch,
            name: TOOL_SEARCH_CHAT_NAME.to_string(),
            namespace: None,
        })
    }

    pub(super) fn chat_name_for_spec(&self, spec: &CodexToolSpec) -> String {
        self.spec_to_chat_name
            .get(spec)
            .cloned()
            .unwrap_or_else(|| self.allocate_chat_name(spec))
    }
}
