// Terminal handling for ChatToResponses: closing open items and emitting the completed /
// incomplete / failed Responses event.

use super::chat_responses::ChatToResponses;
use super::common::ev;
use super::resp_items::{
    incomplete_reason, normalized_tool_arguments, resp_completed, resp_failed, resp_incomplete,
    resp_message_item, resp_reasoning_item,
};
use serde_json::{json, Value};

impl ChatToResponses {
    /// Close open items in index order and emit the appropriate terminal Responses event.
    pub(super) fn complete(&mut self) -> String {
        if self.stopped {
            return String::new();
        }
        self.stopped = true;
        let mut out = String::new();
        self.ensure_created(&mut out);
        self.close_reasoning(&mut out);
        if let Some(m) = &self.message {
            out.push_str(&ev(
                "response.output_text.done",
                json!({ "type": "response.output_text.done", "item_id": m.id, "output_index": m.index,
                    "content_index": 0, "text": m.acc }),
            ));
            out.push_str(&ev(
                "response.content_part.done",
                json!({ "type": "response.content_part.done", "item_id": m.id, "output_index": m.index,
                    "content_index": 0, "part": { "type": "output_text", "annotations": [], "text": m.acc } }),
            ));
            out.push_str(&ev(
                "response.output_item.done",
                json!({ "type": "response.output_item.done", "output_index": m.index,
                    "item": resp_message_item(&m.id, &m.acc) }),
            ));
        }
        for pos in 0..self.tools.len() {
            self.announce_tool_if_ready(pos, &mut out);
        }
        // A slot whose name never arrived is model garbage the client cannot execute — and a
        // nameless function_call echoed into the next request is rejected upstream. Skip it.
        for slot in self
            .tools
            .iter()
            .filter(|slot| slot.announced && !slot.name.is_empty())
        {
            out.push_str(&self.close_tool_events(slot));
        }
        let mut items: Vec<(usize, Value)> = vec![];
        if let Some(r) = &self.reasoning {
            items.push((r.index, resp_reasoning_item(&r.id, &r.acc)));
        }
        if let Some(m) = &self.message {
            items.push((m.index, resp_message_item(&m.id, &m.acc)));
        }
        for slot in self
            .tools
            .iter()
            .filter(|slot| slot.announced && !slot.name.is_empty())
        {
            items.push((
                slot.index,
                self.tool_context.response_tool_item_with_reasoning(
                    &slot.id,
                    "completed",
                    &slot.call_id,
                    &slot.name,
                    normalized_tool_arguments(&slot.args),
                    self.reasoning
                        .as_ref()
                        .map(|reasoning| reasoning.acc.as_str()),
                ),
            ));
        }
        items.sort_by_key(|(i, _)| *i);
        let output: Vec<Value> = items.into_iter().map(|(_, v)| v).collect();
        if let Some(reason) = incomplete_reason(self.finish_reason.as_deref()) {
            self.failed = true;
            out.push_str(&resp_incomplete(
                &self.rid(),
                &self.client_model,
                output,
                self.input_tokens,
                self.cached_tokens,
                self.output_tokens,
                reason,
            ));
        } else {
            out.push_str(&resp_completed(
                &self.rid(),
                &self.client_model,
                output,
                self.input_tokens,
                self.cached_tokens,
                self.output_tokens,
            ));
        }
        out
    }

    /// Finalize a clean upstream EOF only when a Chat finish reason was observed. `[DONE]` calls
    /// `complete` directly; an EOF without either signal is a truncated stream.
    pub fn finish(&mut self) -> String {
        if self.stopped {
            return String::new();
        }
        if self.finish_reason.is_some() {
            self.complete()
        } else {
            self.fail("upstream stream ended before [DONE] or a finish reason")
        }
    }

    pub(super) fn fail(&mut self, message: &str) -> String {
        if self.stopped {
            return String::new();
        }
        let mut out = String::new();
        self.ensure_created(&mut out);
        let id = self.rid();
        out.push_str(&resp_failed(&id, message));
        self.stopped = true;
        self.failed = true;
        out
    }

    pub fn input_tokens(&self) -> i64 {
        self.input_tokens
    }
    pub fn output_tokens(&self) -> i64 {
        self.output_tokens
    }
}
