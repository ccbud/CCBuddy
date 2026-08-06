// Structural validation of a Responses request's call/output pairing, before any translation.

use super::parts::response_item_call_id;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ResponseCallKind {
    Function,
    Custom,
    ToolSearch,
}

impl ResponseCallKind {
    fn call_item(item_type: &str) -> Option<Self> {
        match item_type {
            "function_call" => Some(Self::Function),
            "custom_tool_call" => Some(Self::Custom),
            "tool_search_call" => Some(Self::ToolSearch),
            _ => None,
        }
    }

    fn output_item(item_type: &str) -> Option<Self> {
        match item_type {
            "function_call_output" => Some(Self::Function),
            "custom_tool_call_output" => Some(Self::Custom),
            "tool_search_output" => Some(Self::ToolSearch),
            _ => None,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Function => "function",
            Self::Custom => "custom tool",
            Self::ToolSearch => "tool search",
        }
    }
}

pub(super) fn validate_call_output_pairs(req: &Value) -> Result<(), String> {
    let items = match req.get("input") {
        Some(Value::Array(items)) => items.iter().collect::<Vec<_>>(),
        Some(Value::Object(_)) => req.get("input").into_iter().collect::<Vec<_>>(),
        _ => return Ok(()),
    };
    let mut calls = HashMap::<String, ResponseCallKind>::new();
    let mut seen_call_ids = HashSet::new();
    let mut unresolved = Vec::new();
    let mut consumed_in_group = false;
    for item in items {
        let item_type = item.get("type").and_then(Value::as_str).unwrap_or("");
        if item
            .get("role")
            .and_then(Value::as_str)
            .is_some_and(|role| matches!(role, "user" | "system" | "developer"))
        {
            // A new client-authored turn closes the window in which an older call can be
            // satisfied. Outputs after this point are stale/out of order.
            calls.clear();
            consumed_in_group = false;
            continue;
        }

        if let Some(kind) = ResponseCallKind::call_item(item_type) {
            let Some(call_id) = response_item_call_id(item) else {
                return Err("Responses call item is missing call_id".to_string());
            };
            if consumed_in_group && !calls.is_empty() {
                return Err(format!(
                    "Responses call order is ambiguous: new call {call_id} appeared before every preceding call produced an output"
                ));
            }
            if calls.is_empty() {
                consumed_in_group = false;
            }
            if !seen_call_ids.insert(call_id.to_string())
                || calls.insert(call_id.to_string(), kind).is_some()
            {
                return Err(format!(
                    "Responses call id is ambiguous because it appears more than once before output: {call_id}"
                ));
            }
            continue;
        }

        if let Some(output_kind) = ResponseCallKind::output_item(item_type) {
            match response_item_call_id(item) {
                Some(call_id) => match calls.remove(call_id) {
                    Some(call_kind) if call_kind == output_kind => {
                        consumed_in_group = true;
                    }
                    Some(call_kind) => unresolved.push(format!(
                        "{call_id} ({} output cannot satisfy {} call)",
                        output_kind.label(),
                        call_kind.label()
                    )),
                    None => {
                        if !unresolved.iter().any(|value| value == call_id) {
                            unresolved.push(call_id.to_string());
                        }
                    }
                },
                None => unresolved.push("<missing call_id>".to_string()),
            }
            if !unresolved.is_empty() {
                // Keep collecting only adjacent invalid outputs so the client gets useful ids,
                // but never let a later call retroactively legitimize an earlier output.
                consumed_in_group = true;
            }
            continue;
        }

        match item_type {
            // Reasoning and assistant output items can neighbor the same model turn and do not
            // make otherwise ordered call/output pairs stale.
            "reasoning" | "message" | "" => {}
            _ => {
                if item.get("role").is_some() {
                    calls.clear();
                    consumed_in_group = false;
                }
            }
        }
    }
    if unresolved.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "Responses call output has no preceding matching call: {}",
            unresolved.join(", ")
        ))
    }
}
