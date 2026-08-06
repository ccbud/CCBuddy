// The OpenAI-Chat-chunk event loop of ChatToAnthropic: one upstream SSE line in, Anthropic
// content-block events out.

use super::chat_anthropic::{ChatToAnthropic, ToolSlot};
use super::common::{ev, upstream_error_message};
use serde_json::{json, Value};

impl ChatToAnthropic {
    /// Feed one raw upstream SSE line (e.g. "data: {...}\n" or "data: [DONE]\n"). Returns the
    /// Anthropic SSE text to forward (possibly empty).
    pub fn push(&mut self, line: &str) -> String {
        let mut out = String::new();
        if self.stopped {
            return out;
        }
        let t = line.trim();
        let payload = match t.strip_prefix("data:") {
            Some(p) => p.trim(),
            None => return out, // ignore "event:" lines / blanks; chat SSE carries data-only
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
        if self.msg_id.is_none() {
            if let Some(id) = chunk
                .get("id")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
            {
                self.msg_id = Some(format!("msg_{}", id));
            }
        }
        // usage may ride the final chunk (stream_options.include_usage)
        if let Some(u) = chunk.get("usage").filter(|u| !u.is_null()) {
            self.input_tokens = u
                .get("prompt_tokens")
                .and_then(|v| v.as_i64())
                .unwrap_or(self.input_tokens);
            self.output_tokens = u
                .get("completion_tokens")
                .and_then(|v| v.as_i64())
                .unwrap_or(self.output_tokens);
        }
        let choice = chunk
            .get("choices")
            .and_then(|c| c.as_array())
            .and_then(|a| a.first());
        let choice = match choice {
            Some(c) => c,
            None => return out,
        };
        self.ensure_started(&mut out);
        let delta = choice.get("delta").cloned().unwrap_or(Value::Null);

        // text delta
        if let Some(txt) = delta.get("content").and_then(|v| v.as_str()) {
            if !txt.is_empty() {
                let idx = self.open_text(&mut out);
                out.push_str(&ev("content_block_delta", json!({ "type": "content_block_delta", "index": idx, "delta": { "type": "text_delta", "text": txt } })));
            }
        }

        // tool_call deltas (streamed in fragments, keyed by their OpenAI index)
        if let Some(tcs) = delta.get("tool_calls").and_then(|v| v.as_array()) {
            // A no-index Gemini chunk can contain multiple parallel calls. Even if a provider
            // repeats the same id, each array item in this delta must claim a distinct slot.
            let mut claimed_slots: Vec<usize> = vec![];
            for (fallback_index, tc) in tcs.iter().enumerate() {
                let explicit_index = tc.get("index").and_then(|v| v.as_u64());
                let oa_index = explicit_index.unwrap_or(fallback_index as u64);
                let name = tc
                    .get("function")
                    .and_then(|f| f.get("name"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let id = tc.get("id").and_then(|v| v.as_str()).unwrap_or("");
                let args = tc
                    .get("function")
                    .and_then(|f| f.get("arguments"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let thought_signature = super::super::json_thought_signature(tc);

                // Standard OpenAI chunks carry `index`; Gemini-compatible streams may omit it.
                // In that case prefer the stable call id, then the call's position in this delta.
                let pos = explicit_index
                    .and_then(|_| {
                        self.tools
                            .iter()
                            .enumerate()
                            .find(|(index, slot)| {
                                slot.oa_index == oa_index && !claimed_slots.contains(index)
                            })
                            .map(|(index, _)| index)
                    })
                    .or_else(|| {
                        (!id.is_empty())
                            .then(|| {
                                self.tools
                                    .iter()
                                    .enumerate()
                                    .find(|(index, slot)| {
                                        slot.id == id && !claimed_slots.contains(index)
                                    })
                                    .map(|(index, _)| index)
                            })
                            .flatten()
                    })
                    .or_else(|| {
                        self.tools
                            .iter()
                            .enumerate()
                            .find(|(index, slot)| {
                                slot.oa_index == oa_index && !claimed_slots.contains(index)
                            })
                            .map(|(index, _)| index)
                    });
                let slot_idx = match pos {
                    Some(i) => i,
                    None => {
                        let an_index = self.next_index;
                        self.next_index += 1;
                        self.tools.push(ToolSlot {
                            oa_index,
                            an_index,
                            open: false,
                            id: String::new(),
                            name: String::new(),
                            thought_signature: None,
                            arguments: String::new(),
                        });
                        self.tools.len() - 1
                    }
                };
                claimed_slots.push(slot_idx);
                let (an_index, should_open, open_id, open_name) = {
                    let slot = &mut self.tools[slot_idx];
                    if !id.is_empty() {
                        slot.id = id.to_string();
                    }
                    if !name.is_empty() {
                        slot.name = name.to_string();
                    }
                    if thought_signature.is_some() {
                        slot.thought_signature = thought_signature;
                    }
                    if !args.is_empty() {
                        slot.arguments.push_str(args);
                    }
                    let should_open = !slot.open;
                    if should_open {
                        slot.open = true;
                    }
                    (
                        slot.an_index,
                        should_open,
                        slot.id.clone(),
                        slot.name.clone(),
                    )
                };
                if should_open {
                    out.push_str(&ev(
                        "content_block_start",
                        json!({ "type": "content_block_start",
                        "index": an_index, "content_block": { "type": "tool_use",
                            "id": open_id, "name": open_name, "input": {} } }),
                    ));
                }
                if !args.is_empty() {
                    out.push_str(&ev("content_block_delta", json!({ "type": "content_block_delta",
                        "index": an_index, "delta": { "type": "input_json_delta", "partial_json": args } })));
                }
            }
        }

        if let Some(fr) = choice.get("finish_reason").and_then(|v| v.as_str()) {
            self.finish_reason = Some(fr.to_string());
        }
        out
    }
}
