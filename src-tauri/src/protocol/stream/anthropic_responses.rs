// Anthropic Messages stream → OpenAI Responses stream: transcoder state and construction (Codex
// client, Anthropic upstream). The event loop lives in anthropic_responses_push.rs.

use super::super::openai_responses::CodexToolContext;
use super::common::ev;
use serde_json::json;

/// Stateful Anthropic-Messages-stream → OpenAI-Responses-stream transcoder (Codex client,
/// Anthropic upstream). Anthropic blocks map 1:1 onto Responses output items: text →
/// message/output_text, tool_use → function_call (input_json_delta fragments accumulate into the
/// arguments string), thinking → reasoning summary. Upstream `error` events surface as
/// `response.failed` so Codex aborts cleanly instead of timing out.
pub struct AnthropicToResponses {
    pub(super) client_model: String,
    pub(super) tool_context: CodexToolContext,
    // Construction-time fallback. An upstream id may replace it only until response.created is
    // emitted; afterward this id is immutable so every event in the response agrees.
    pub(super) resp_id: String,
    pub(super) created: bool,
    pub(super) next_index: usize,
    pub(super) blocks: Vec<ABlock>,
    pub(super) input_tokens: i64,
    pub(super) cached_tokens: i64,
    pub(super) output_tokens: i64,
    pub(super) stop_reason: Option<String>,
    pub(super) stopped: bool,
    pub(super) failed: bool,
}

pub(super) struct ABlock {
    pub(super) a_index: u64,
    pub(super) index: usize,
    pub(super) id: String,
    pub(super) kind: AKind,
    pub(super) open: bool,
}

pub(super) enum AKind {
    Text {
        acc: String,
    },
    Tool {
        call_id: String,
        name: String,
        args: String,
        start_args: String,
    },
    Think {
        acc: String,
    },
}

impl AnthropicToResponses {
    pub fn new(client_model: &str) -> Self {
        Self::new_with_context(client_model, CodexToolContext::default())
    }

    pub fn new_with_context(client_model: &str, tool_context: CodexToolContext) -> Self {
        Self {
            client_model: client_model.to_string(),
            tool_context,
            resp_id: super::super::uid("resp_ccbud"),
            created: false,
            next_index: 0,
            blocks: vec![],
            input_tokens: 0,
            cached_tokens: 0,
            output_tokens: 0,
            stop_reason: None,
            stopped: false,
            failed: false,
        }
    }

    pub(super) fn rid(&self) -> String {
        self.resp_id.clone()
    }

    pub(super) fn reasoning_text(&self) -> Option<String> {
        let text = self
            .blocks
            .iter()
            .filter_map(|block| match &block.kind {
                AKind::Think { acc } if !acc.trim().is_empty() => Some(acc.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n\n");
        (!text.is_empty()).then_some(text)
    }

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
}
