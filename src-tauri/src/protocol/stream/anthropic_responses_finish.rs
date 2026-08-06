// Terminal handling for AnthropicToResponses: closing still-open blocks and emitting the
// completed / incomplete / failed Responses event.

use super::ablock::{ablock_item, close_ablock_events};
use super::anthropic_responses::AnthropicToResponses;
use super::resp_items::{incomplete_reason, resp_completed, resp_failed, resp_incomplete};
use serde_json::Value;

impl AnthropicToResponses {
    /// Close any still-open blocks and emit the appropriate terminal Responses event.
    pub(super) fn complete(&mut self) -> String {
        if self.stopped {
            return String::new();
        }
        self.stopped = true;
        let mut out = String::new();
        self.ensure_created(&mut out);
        let reasoning = self.reasoning_text();
        self.blocks.sort_by_key(|b| b.index);
        for b in &mut self.blocks {
            if b.open {
                b.open = false;
                out.push_str(&close_ablock_events(
                    b,
                    &self.tool_context,
                    reasoning.as_deref(),
                ));
            }
        }
        let output: Vec<Value> = self
            .blocks
            .iter()
            .map(|block| ablock_item(block, &self.tool_context, reasoning.as_deref()))
            .collect();
        if let Some(reason) = incomplete_reason(self.stop_reason.as_deref()) {
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

    /// Finalize a clean upstream EOF only after Anthropic reported a stop reason. A normal
    /// `message_stop` calls `complete` directly; an EOF before both signals is truncated.
    pub fn finish(&mut self) -> String {
        if self.stopped {
            return String::new();
        }
        if self.stop_reason.is_some() {
            self.complete()
        } else {
            self.fail("upstream stream ended before message_stop or a stop reason")
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
