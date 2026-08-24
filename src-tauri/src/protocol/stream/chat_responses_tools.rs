// Tool-call fragment handling for ChatToResponses::push — lifted verbatim out of that function so
// no single file exceeds the module's size budget; called exactly once, from `push`.

use super::super::openai_responses::response_scoped_call_id;
use super::chat_responses::{ChatToResponses, RespToolAcc};
use serde_json::Value;

impl ChatToResponses {
    pub(super) fn push_tool_call_deltas(&mut self, delta: &Value, mut out: &mut String) {
        // tool_call deltas (streamed in fragments, keyed by their OpenAI index)
        if let Some(tcs) = delta.get("tool_calls").and_then(|v| v.as_array()) {
            if !tcs.is_empty() {
                self.close_reasoning(&mut out);
            }
            // A no-index Gemini chunk can contain multiple parallel calls. Even if a provider
            // repeats the same id, each array item in this delta must claim a distinct slot
            // (mirrors ChatToAnthropic).
            let mut claimed_slots: Vec<usize> = vec![];
            for (fallback_index, tc) in tcs.iter().enumerate() {
                let explicit_index = tc.get("index").and_then(|v| v.as_u64());
                let oa_index = explicit_index.unwrap_or(fallback_index as u64);
                let frag_id = tc.get("id").and_then(|v| v.as_str()).unwrap_or("");
                let frag_name = tc
                    .get("function")
                    .and_then(|f| f.get("name"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
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
                        (!frag_id.is_empty())
                            .then(|| {
                                self.tools
                                    .iter()
                                    .enumerate()
                                    .find(|(index, slot)| {
                                        slot.upstream_call_id == frag_id
                                            && !claimed_slots.contains(index)
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
                let pos = match pos {
                    Some(p) => p,
                    None => {
                        let index = self.next_index;
                        self.next_index += 1;
                        let call_id = response_scoped_call_id(&self.rid(), index);
                        let slot = RespToolAcc {
                            oa_index,
                            index,
                            id: String::new(),
                            upstream_call_id: frag_id.to_string(),
                            call_id,
                            name: frag_name.to_string(),
                            args: String::new(),
                            thought_signature: None,
                            announced: false,
                            emitted_args_len: 0,
                        };
                        self.tools.push(slot);
                        self.tools.len() - 1
                    }
                };
                claimed_slots.push(pos);
                // stray late fragments may carry the id/name the opener lacked; the done item wins
                if !frag_id.is_empty() {
                    self.tools[pos].upstream_call_id = frag_id.to_string();
                }
                if !frag_name.is_empty() && self.tools[pos].name.is_empty() {
                    self.tools[pos].name = frag_name.to_string();
                }
                if thought_signature.is_some() {
                    self.tools[pos].thought_signature = thought_signature;
                }
                if !args.is_empty() {
                    self.tools[pos].args.push_str(args);
                }
                self.announce_tool_if_ready(pos, &mut out);
                self.emit_pending_tool_arguments(pos, &mut out);
            }
        }
    }
}
