// The `content_block_start` arm of AnthropicToResponses::push — lifted verbatim out of that
// function so no single file exceeds the module's size budget; called exactly once, from `push`.

use super::anthropic_responses::{ABlock, AKind, AnthropicToResponses};
use super::common::ev;
use super::resp_items::response_scoped_item_id;
use super::super::openai_responses::response_scoped_call_id;
use serde_json::{json, Value};

impl AnthropicToResponses {
    pub(super) fn push_content_block_start(&mut self, evt: &Value, mut out: &mut String) {
                self.ensure_created(&mut out);
                let a_index = evt.get("index").and_then(|v| v.as_u64()).unwrap_or(0);
                let cb = evt.get("content_block").cloned().unwrap_or(Value::Null);
                let index = self.next_index;
                match cb.get("type").and_then(|v| v.as_str()) {
                    Some("text") => {
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
                        self.blocks.push(ABlock {
                            a_index,
                            index,
                            id,
                            kind: AKind::Text { acc: String::new() },
                            open: true,
                        });
                    }
                    Some("tool_use") => {
                        self.next_index += 1;
                        let call_id = response_scoped_call_id(&self.rid(), index);
                        let name = cb
                            .get("name")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();
                        let id = self
                            .tool_context
                            .response_item_id(&name, &self.rid(), index);
                        let start_args = cb
                            .get("input")
                            .filter(|value| {
                                value.as_object().is_some_and(|object| !object.is_empty())
                            })
                            .map(Value::to_string)
                            .unwrap_or_default();
                        let reasoning = self.reasoning_text();
                        let item = self.tool_context.response_tool_item_with_reasoning(
                            &id,
                            "in_progress",
                            &call_id,
                            &name,
                            "",
                            reasoning.as_deref(),
                        );
                        let mut item = item;
                        if item.get("type").and_then(Value::as_str) == Some("function_call") {
                            item["arguments"] = json!("");
                        }
                        out.push_str(&ev(
                            "response.output_item.added",
                            json!({ "type": "response.output_item.added", "output_index": index,
                                "item": item }),
                        ));
                        self.blocks.push(ABlock {
                            a_index,
                            index,
                            id,
                            kind: AKind::Tool {
                                call_id,
                                name,
                                args: String::new(),
                                start_args,
                            },
                            open: true,
                        });
                    }
                    Some("thinking") => {
                        self.next_index += 1;
                        let id = response_scoped_item_id("rs", &self.rid(), index);
                        out.push_str(&ev(
                            "response.output_item.added",
                            json!({ "type": "response.output_item.added", "output_index": index,
                                "item": { "type": "reasoning", "id": id, "summary": [] } }),
                        ));
                        self.blocks.push(ABlock {
                            a_index,
                            index,
                            id,
                            kind: AKind::Think { acc: String::new() },
                            open: true,
                        });
                    }
                    // redacted_thinking / server_tool_use / … have no Responses equivalent; their
                    // deltas find no block below and drop.
                    _ => {}
                }
    }
}
