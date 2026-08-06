// The Anthropic-event loop of AnthropicToResponses. The `content_block_start` arm lives in
// anthropic_responses_block.rs.

use super::ablock::close_ablock_events;
use super::anthropic_responses::{AKind, AnthropicToResponses};
use super::common::ev;
use super::super::openai_responses::CodexToolKind;
use serde_json::{json, Value};

impl AnthropicToResponses {
    /// Feed one raw upstream SSE line. Anthropic streams interleave `event:` and `data:` lines;
    /// the data JSON's `type` mirrors the event name, so data lines alone drive the state machine.
    pub fn push(&mut self, line: &str) -> String {
        let mut out = String::new();
        if self.stopped {
            return out;
        }
        let t = line.trim();
        let payload = match t.strip_prefix("data:") {
            Some(p) => p.trim(),
            None => return out,
        };
        if payload.is_empty() {
            return out;
        }
        let evt: Value = match serde_json::from_str(payload) {
            Ok(v) => v,
            Err(_) => return out,
        };
        match evt.get("type").and_then(|v| v.as_str()) {
            Some("message_start") => {
                if let Some(m) = evt.get("message") {
                    if !self.created {
                        if let Some(id) = m
                            .get("id")
                            .and_then(|v| v.as_str())
                            .filter(|s| !s.is_empty())
                        {
                            self.resp_id = format!("resp_{}", id);
                        }
                    }
                    if let Some(u) = m.get("usage") {
                        // Responses-style input_tokens includes cached reads; Anthropic reports
                        // them separately.
                        let base = u.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                        let cr = u
                            .get("cache_read_input_tokens")
                            .and_then(|v| v.as_i64())
                            .unwrap_or(0);
                        let cc = u
                            .get("cache_creation_input_tokens")
                            .and_then(|v| v.as_i64())
                            .unwrap_or(0);
                        self.input_tokens = base + cr + cc;
                        self.cached_tokens = cr;
                    }
                }
                self.ensure_created(&mut out);
            }
            Some("content_block_start") => self.push_content_block_start(&evt, &mut out),
            Some("content_block_delta") => {
                let a_index = evt.get("index").and_then(|v| v.as_u64()).unwrap_or(0);
                let delta = evt.get("delta").cloned().unwrap_or(Value::Null);
                if let Some(b) = self
                    .blocks
                    .iter_mut()
                    .find(|b| b.a_index == a_index && b.open)
                {
                    match (&mut b.kind, delta.get("type").and_then(|v| v.as_str())) {
                        (AKind::Text { acc }, Some("text_delta")) => {
                            if let Some(txt) = delta
                                .get("text")
                                .and_then(|v| v.as_str())
                                .filter(|s| !s.is_empty())
                            {
                                acc.push_str(txt);
                                out.push_str(&ev(
                                    "response.output_text.delta",
                                    json!({ "type": "response.output_text.delta", "item_id": b.id,
                                        "output_index": b.index, "content_index": 0, "delta": txt }),
                                ));
                            }
                        }
                        (AKind::Tool { name, args, .. }, Some("input_json_delta")) => {
                            if let Some(pj) = delta
                                .get("partial_json")
                                .and_then(|v| v.as_str())
                                .filter(|s| !s.is_empty())
                            {
                                args.push_str(pj);
                                if self.tool_context.kind_for_chat_name(name)
                                    != CodexToolKind::Custom
                                {
                                    out.push_str(&ev(
                                        "response.function_call_arguments.delta",
                                        json!({ "type": "response.function_call_arguments.delta", "item_id": b.id,
                                            "output_index": b.index, "delta": pj }),
                                    ));
                                }
                            }
                        }
                        (AKind::Think { acc }, Some("thinking_delta")) => {
                            if let Some(th) = delta
                                .get("thinking")
                                .and_then(|v| v.as_str())
                                .filter(|s| !s.is_empty())
                            {
                                acc.push_str(th);
                                out.push_str(&ev(
                                    "response.reasoning_summary_text.delta",
                                    json!({ "type": "response.reasoning_summary_text.delta", "item_id": b.id,
                                        "output_index": b.index, "summary_index": 0, "delta": th }),
                                ));
                            }
                        }
                        _ => {} // signature_delta etc.
                    }
                }
            }
            Some("content_block_stop") => {
                let a_index = evt.get("index").and_then(|v| v.as_u64()).unwrap_or(0);
                let reasoning = self.reasoning_text();
                if let Some(b) = self
                    .blocks
                    .iter_mut()
                    .find(|b| b.a_index == a_index && b.open)
                {
                    b.open = false;
                    out.push_str(&close_ablock_events(
                        b,
                        &self.tool_context,
                        reasoning.as_deref(),
                    ));
                }
            }
            Some("message_delta") => {
                if let Some(reason) = evt
                    .get("delta")
                    .and_then(|delta| delta.get("stop_reason"))
                    .and_then(Value::as_str)
                {
                    self.stop_reason = Some(reason.to_string());
                }
                if let Some(o) = evt
                    .get("usage")
                    .and_then(|u| u.get("output_tokens"))
                    .and_then(|v| v.as_i64())
                {
                    self.output_tokens = o;
                }
            }
            Some("message_stop") => {
                out.push_str(&self.complete());
            }
            Some("error") => {
                let msg = evt
                    .get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("upstream error");
                out.push_str(&self.fail(msg));
            }
            _ => {} // ping etc.
        }
        out
    }
}
