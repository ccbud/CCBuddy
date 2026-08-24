// Closing an Anthropic content block into its finished Responses item: argument reconciliation,
// the per-kind `*.done` event sequence, and the item payload itself.

use super::super::openai_responses::{
    custom_tool_input_from_chat_arguments, CodexToolContext, CodexToolKind,
};
use super::anthropic_responses::{ABlock, AKind};
use super::common::ev;
use super::resp_items::{resp_message_item, resp_reasoning_item};
use serde_json::{json, Value};

pub(super) fn ablock_tool_arguments(args: &str, start_args: &str) -> String {
    if !args.trim().is_empty() {
        args.to_string()
    } else if !start_args.trim().is_empty() {
        start_args.to_string()
    } else {
        "{}".to_string()
    }
}

/// The closing event sequence for one finished block (its `*.done` events + `output_item.done`).
pub(super) fn close_ablock_events(
    b: &ABlock,
    tool_context: &CodexToolContext,
    reasoning: Option<&str>,
) -> String {
    let mut out = String::new();
    match &b.kind {
        AKind::Text { acc } => {
            out.push_str(&ev(
                "response.output_text.done",
                json!({ "type": "response.output_text.done", "item_id": b.id, "output_index": b.index,
                    "content_index": 0, "text": acc }),
            ));
            out.push_str(&ev(
                "response.content_part.done",
                json!({ "type": "response.content_part.done", "item_id": b.id, "output_index": b.index,
                    "content_index": 0, "part": { "type": "output_text", "annotations": [], "text": acc } }),
            ));
            out.push_str(&ev(
                "response.output_item.done",
                json!({ "type": "response.output_item.done", "output_index": b.index, "item": resp_message_item(&b.id, acc) }),
            ));
        }
        AKind::Tool {
            call_id,
            name,
            args,
            start_args,
        } => {
            let arguments = ablock_tool_arguments(args, start_args);
            let item = tool_context.response_tool_item_with_reasoning(
                &b.id,
                "completed",
                call_id,
                name,
                &arguments,
                reasoning,
            );
            match tool_context.kind_for_chat_name(name) {
                CodexToolKind::Custom => {
                    let input = custom_tool_input_from_chat_arguments(&arguments);
                    if !input.is_empty() {
                        out.push_str(&ev(
                            "response.custom_tool_call_input.delta",
                            json!({ "type": "response.custom_tool_call_input.delta", "item_id": b.id,
                                "call_id": call_id, "output_index": b.index, "delta": input }),
                        ));
                    }
                    out.push_str(&ev(
                        "response.custom_tool_call_input.done",
                        json!({ "type": "response.custom_tool_call_input.done", "item_id": b.id,
                            "call_id": call_id, "output_index": b.index, "input": input }),
                    ));
                }
                CodexToolKind::Function | CodexToolKind::Namespace | CodexToolKind::ToolSearch => {
                    out.push_str(&ev(
                        "response.function_call_arguments.done",
                        json!({ "type": "response.function_call_arguments.done", "item_id": b.id,
                            "output_index": b.index, "arguments": arguments }),
                    ));
                }
            }
            out.push_str(&ev(
                "response.output_item.done",
                json!({ "type": "response.output_item.done", "output_index": b.index,
                    "item": item }),
            ));
        }
        AKind::Think { acc } => {
            out.push_str(&ev(
                "response.output_item.done",
                json!({ "type": "response.output_item.done", "output_index": b.index, "item": resp_reasoning_item(&b.id, acc) }),
            ));
        }
    }
    out
}

pub(super) fn ablock_item(
    b: &ABlock,
    tool_context: &CodexToolContext,
    reasoning: Option<&str>,
) -> Value {
    match &b.kind {
        AKind::Text { acc } => resp_message_item(&b.id, acc),
        AKind::Tool {
            call_id,
            name,
            args,
            start_args,
        } => tool_context.response_tool_item_with_reasoning(
            &b.id,
            "completed",
            call_id,
            name,
            &ablock_tool_arguments(args, start_args),
            reasoning,
        ),
        AKind::Think { acc } => resp_reasoning_item(&b.id, acc),
    }
}
