// The OpenAI-Chat-chunk event loop of ChatToResponses: usage, reasoning deltas and text deltas.
// Tool-call fragment handling lives in chat_responses_tools.rs.

use super::chat_responses::{ChatToResponses, TextItemAcc};
use super::common::{ev, upstream_error_message};
use super::resp_items::response_scoped_item_id;
use serde_json::{json, Value};

impl ChatToResponses {
    /// Feed one raw upstream SSE line ("data: {...}" or "data: [DONE]"). Returns Responses SSE
    /// text to forward (possibly empty).
    pub fn push(&mut self, line: &str) -> String {
        let mut out = String::new();
        if self.stopped {
            return out;
        }
        let t = line.trim();
        let payload = match t.strip_prefix("data:") {
            Some(p) => p.trim(),
            None => return out, // chat SSE is data-only; ignore blanks/event: lines
        };
        if payload.is_empty() {
            return out;
        }
        if payload == "[DONE]" {
            out.push_str(&self.complete());
            return out;
        }
        let chunk: Value = match serde_json::from_str(payload) {
            Ok(v) => v,
            Err(_) => return out,
        };
        if let Some(message) = upstream_error_message(&chunk) {
            return self.fail(message);
        }
        if !self.created {
            if let Some(id) = chunk
                .get("id")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
            {
                self.resp_id = format!("resp_{}", id);
            }
        }
        // usage rides the final chunk (stream_options.include_usage)
        if let Some(u) = chunk.get("usage").filter(|u| !u.is_null()) {
            self.input_tokens = u
                .get("prompt_tokens")
                .and_then(|v| v.as_i64())
                .unwrap_or(self.input_tokens);
            self.output_tokens = u
                .get("completion_tokens")
                .and_then(|v| v.as_i64())
                .unwrap_or(self.output_tokens);
            if let Some(c) = u
                .pointer("/prompt_tokens_details/cached_tokens")
                .and_then(|v| v.as_i64())
            {
                self.cached_tokens = c;
            }
        }
        let choice = match chunk
            .get("choices")
            .and_then(|c| c.as_array())
            .and_then(|a| a.first())
        {
            Some(c) => c,
            None => return out,
        };
        self.ensure_created(&mut out);
        let delta = choice.get("delta").cloned().unwrap_or(Value::Null);

        // provider reasoning stream (DeepSeek/GLM-style `reasoning_content`, or `reasoning`)
        let think = delta
            .get("reasoning_content")
            .and_then(|v| v.as_str())
            .or_else(|| delta.get("reasoning").and_then(|v| v.as_str()))
            .unwrap_or("");
        if !think.is_empty() {
            if self.reasoning.is_none() {
                let index = self.next_index;
                self.next_index += 1;
                let id = response_scoped_item_id("rs", &self.rid(), index);
                out.push_str(&ev(
                    "response.output_item.added",
                    json!({ "type": "response.output_item.added", "output_index": index,
                        "item": { "type": "reasoning", "id": id, "summary": [] } }),
                ));
                self.reasoning = Some(TextItemAcc {
                    index,
                    id,
                    acc: String::new(),
                });
                self.reasoning_open = true;
            }
            let r = self.reasoning.as_mut().unwrap();
            r.acc.push_str(think);
            out.push_str(&ev(
                "response.reasoning_summary_text.delta",
                json!({ "type": "response.reasoning_summary_text.delta", "item_id": r.id,
                    "output_index": r.index, "summary_index": 0, "delta": think }),
            ));
        }

        // text delta
        if let Some(txt) = delta.get("content").and_then(|v| v.as_str()) {
            if !txt.is_empty() {
                self.close_reasoning(&mut out);
                if self.message.is_none() {
                    let index = self.next_index;
                    self.next_index += 1;
                    let id = response_scoped_item_id("msg", &self.rid(), index);
                    out.push_str(&ev(
                        "response.output_item.added",
                        json!({ "type": "response.output_item.added", "output_index": index,
                            "item": { "type": "message", "id": id, "status": "in_progress", "role": "assistant", "content": [] } }),
                    ));
                    out.push_str(&ev(
                        "response.content_part.added",
                        json!({ "type": "response.content_part.added", "item_id": id, "output_index": index,
                            "content_index": 0, "part": { "type": "output_text", "annotations": [], "text": "" } }),
                    ));
                    self.message = Some(TextItemAcc {
                        index,
                        id,
                        acc: String::new(),
                    });
                }
                let m = self.message.as_mut().unwrap();
                m.acc.push_str(txt);
                out.push_str(&ev(
                    "response.output_text.delta",
                    json!({ "type": "response.output_text.delta", "item_id": m.id, "output_index": m.index,
                        "content_index": 0, "delta": txt }),
                ));
            }
        }

        self.push_tool_call_deltas(&delta, &mut out);
        if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
            self.finish_reason = Some(reason.to_string());
        }
        out
    }
}
