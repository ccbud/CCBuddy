// Responses item bookkeeping for ChatToResponses: opening the response, closing the reasoning
// item, and announcing / streaming / closing each tool call item.

use super::chat_responses::{ChatToResponses, RespToolAcc};
use super::common::ev;
use super::resp_items::{
    normalized_tool_arguments, resp_in_progress_tool_item, resp_reasoning_item,
};
use super::super::openai_responses::{custom_tool_input_from_chat_arguments, CodexToolKind};
use serde_json::json;

impl ChatToResponses {
    pub(super) fn ensure_created(&mut self, out: &mut String) {
        if self.created {
            return;
        }
        self.created = true;
        let id = self.rid();
        out.push_str(&ev(
            "response.created",
            json!({ "type": "response.created",
                "response": { "id": id, "object": "response", "status": "in_progress", "model": self.client_model } }),
        ));
    }

    pub(super) fn close_reasoning(&mut self, out: &mut String) {
        if !self.reasoning_open {
            return;
        }
        self.reasoning_open = false;
        if let Some(r) = &self.reasoning {
            out.push_str(&ev(
                "response.output_item.done",
                json!({ "type": "response.output_item.done", "output_index": r.index,
                    "item": resp_reasoning_item(&r.id, &r.acc) }),
            ));
        }
    }

    pub(super) fn announce_tool_if_ready(&mut self, pos: usize, out: &mut String) {
        let Some(slot) = self.tools.get(pos) else {
            return;
        };
        if slot.announced || slot.name.is_empty() {
            return;
        }

        let id = self
            .tool_context
            .response_item_id(&slot.name, &self.rid(), slot.index);
        let item = resp_in_progress_tool_item(
            &self.tool_context,
            &id,
            &slot.call_id,
            &slot.name,
            self.reasoning
                .as_ref()
                .map(|reasoning| reasoning.acc.as_str()),
        );
        let index = slot.index;
        out.push_str(&ev(
            "response.output_item.added",
            json!({ "type": "response.output_item.added", "output_index": index, "item": item }),
        ));

        let slot = &mut self.tools[pos];
        slot.id = id;
        slot.announced = true;
        self.emit_pending_tool_arguments(pos, out);
    }

    pub(super) fn emit_pending_tool_arguments(&mut self, pos: usize, out: &mut String) {
        let Some(slot) = self.tools.get_mut(pos) else {
            return;
        };
        if !slot.announced
            || slot.name.is_empty()
            || self.tool_context.kind_for_chat_name(&slot.name) == CodexToolKind::Custom
            || slot.emitted_args_len >= slot.args.len()
        {
            return;
        }
        let delta = slot.args[slot.emitted_args_len..].to_string();
        slot.emitted_args_len = slot.args.len();
        out.push_str(&ev(
            "response.function_call_arguments.delta",
            json!({ "type": "response.function_call_arguments.delta", "item_id": slot.id,
                "output_index": slot.index, "delta": delta }),
        ));
    }

    pub(super) fn close_tool_events(&self, slot: &RespToolAcc) -> String {
        let mut out = String::new();
        let arguments = normalized_tool_arguments(&slot.args);
        let item = self.tool_context.response_tool_item_with_reasoning(
            &slot.id,
            "completed",
            &slot.call_id,
            &slot.name,
            arguments,
            self.reasoning
                .as_ref()
                .map(|reasoning| reasoning.acc.as_str()),
        );
        match self.tool_context.kind_for_chat_name(&slot.name) {
            CodexToolKind::Custom => {
                let input = custom_tool_input_from_chat_arguments(arguments);
                if !input.is_empty() {
                    out.push_str(&ev(
                        "response.custom_tool_call_input.delta",
                        json!({ "type": "response.custom_tool_call_input.delta", "item_id": slot.id,
                            "call_id": slot.call_id, "output_index": slot.index, "delta": input }),
                    ));
                }
                out.push_str(&ev(
                    "response.custom_tool_call_input.done",
                    json!({ "type": "response.custom_tool_call_input.done", "item_id": slot.id,
                        "call_id": slot.call_id, "output_index": slot.index, "input": input }),
                ));
            }
            CodexToolKind::Function | CodexToolKind::Namespace | CodexToolKind::ToolSearch => {
                out.push_str(&ev(
                    "response.function_call_arguments.done",
                    json!({ "type": "response.function_call_arguments.done", "item_id": slot.id,
                        "output_index": slot.index, "arguments": arguments }),
                ));
            }
        }
        out.push_str(&ev(
            "response.output_item.done",
            json!({ "type": "response.output_item.done", "output_index": slot.index, "item": item }),
        ));
        out
    }
}
