// OpenAI Chat stream → Anthropic Messages stream: transcoder state and the block/lifecycle
// bookkeeping around the event loop in chat_anthropic_push.rs.

use super::common::{ev, map_stop, CapturedToolCall};
use serde_json::{json, Value};

/// Stateful OpenAI-Chat-stream → Anthropic-stream transcoder. Feed each raw upstream SSE line to
/// `push`; call `finish` at end. Anthropic requires an ordered `message_start`, then content blocks
/// (each `content_block_start`/`_delta`/`_stop`), then `message_delta` + `message_stop`. We open a
/// text block on the first text delta and one tool_use block per OpenAI tool_call index, assigning
/// Anthropic block indices in first-appearance order.
pub struct ChatToAnthropic {
    pub(super) client_model: String,
    pub(super) started: bool,
    // message id sent in message_start — from the upstream chunk id when it has one, else a
    // generated unique id. Clients persist this id; it must never repeat across turns (usage
    // analytics de-dupes assistant messages by id).
    pub(super) msg_id: Option<String>,
    pub(super) next_index: usize,
    // text block
    pub(super) text_index: Option<usize>,
    // openai tool_call index → (anthropic block index, open?)
    pub(super) tools: Vec<ToolSlot>,
    pub(super) input_tokens: i64,
    pub(super) output_tokens: i64,
    pub(super) finish_reason: Option<String>,
    pub(super) stopped: bool,
    pub(super) failed: bool,
}

pub(super) struct ToolSlot {
    pub(super) oa_index: u64,
    pub(super) an_index: usize,
    pub(super) open: bool,
    pub(super) id: String,
    pub(super) name: String,
    pub(super) thought_signature: Option<String>,
    pub(super) arguments: String,
}

impl ChatToAnthropic {
    pub fn new(client_model: &str) -> Self {
        Self {
            client_model: client_model.to_string(),
            started: false,
            msg_id: None,
            next_index: 0,
            text_index: None,
            tools: vec![],
            input_tokens: 0,
            output_tokens: 0,
            finish_reason: None,
            stopped: false,
            failed: false,
        }
    }

    pub(super) fn ensure_started(&mut self, out: &mut String) {
        if self.started {
            return;
        }
        self.started = true;
        let id = self
            .msg_id
            .get_or_insert_with(|| super::super::uid("msg_ccbud"))
            .clone();
        out.push_str(&ev(
            "message_start",
            json!({ "type": "message_start", "message": {
                "id": id, "type": "message", "role": "assistant", "model": self.client_model,
                "content": [], "stop_reason": Value::Null, "stop_sequence": Value::Null,
                "usage": { "input_tokens": self.input_tokens.max(0), "output_tokens": 0 },
            }}),
        ));
    }

    pub(super) fn open_text(&mut self, out: &mut String) -> usize {
        if let Some(i) = self.text_index {
            return i;
        }
        let idx = self.next_index;
        self.next_index += 1;
        self.text_index = Some(idx);
        out.push_str(&ev("content_block_start", json!({ "type": "content_block_start", "index": idx, "content_block": { "type": "text", "text": "" } })));
        idx
    }

    pub(super) fn captured_tool_calls(&self) -> Vec<CapturedToolCall> {
        self.tools
            .iter()
            .map(|slot| CapturedToolCall {
                call_id: slot.id.clone(),
                name: slot.name.clone(),
                arguments: slot.arguments.clone(),
                thought_signature: slot.thought_signature.clone(),
            })
            .collect()
    }

    /// Close any open blocks and emit message_delta + message_stop. Idempotent.
    pub(super) fn complete(&mut self) -> String {
        if self.stopped {
            return String::new();
        }
        self.stopped = true;
        let mut out = String::new();
        self.ensure_started(&mut out);
        // close blocks in ascending Anthropic index order
        let mut closes: Vec<usize> = vec![];
        if let Some(i) = self.text_index {
            closes.push(i);
        }
        for s in &self.tools {
            if s.open {
                closes.push(s.an_index);
            }
        }
        closes.sort_unstable();
        for i in closes {
            out.push_str(&ev(
                "content_block_stop",
                json!({ "type": "content_block_stop", "index": i }),
            ));
        }
        let had_tool = self.tools.iter().any(|s| s.open);
        out.push_str(&ev(
            "message_delta",
            json!({ "type": "message_delta",
                "delta": { "stop_reason": map_stop(self.finish_reason.as_deref(), had_tool), "stop_sequence": Value::Null },
                "usage": { "output_tokens": self.output_tokens.max(0) } }),
        ));
        out.push_str(&ev("message_stop", json!({ "type": "message_stop" })));
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
        self.stopped = true;
        self.failed = true;
        ev(
            "error",
            json!({ "type": "error", "error": { "type": "api_error", "message": message } }),
        )
    }

    pub fn input_tokens(&self) -> i64 {
        self.input_tokens
    }
    pub fn output_tokens(&self) -> i64 {
        self.output_tokens
    }
}
