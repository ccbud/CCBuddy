// OpenAI Chat stream → OpenAI Responses stream: transcoder state and construction (Codex client,
// chat upstream). The event loop lives in chat_responses_push.rs.

use super::common::CapturedToolCall;
use super::super::openai_responses::CodexToolContext;

/// Stateful OpenAI-Chat-stream → OpenAI-Responses-stream transcoder (Codex client, chat upstream).
/// Text deltas stream through as `response.output_text.delta`; provider reasoning deltas
/// (`reasoning_content` / `reasoning`) as `response.reasoning_summary_text.delta`; tool-call
/// fragments accumulate per OpenAI index (with the same no-index Gemini slot handling as
/// ChatToAnthropic, including thought-signature capture) and surface whole in
/// `response.output_item.done` — the only place Codex materializes items from.
pub struct ChatToResponses {
    pub(super) client_model: String,
    pub(super) tool_context: CodexToolContext,
    // Construction-time fallback. An upstream id may replace it only until response.created is
    // emitted; afterward this id is immutable so every event in the response agrees.
    pub(super) resp_id: String,
    pub(super) created: bool,
    pub(super) next_index: usize,
    pub(super) reasoning: Option<TextItemAcc>,
    pub(super) reasoning_open: bool,
    pub(super) message: Option<TextItemAcc>,
    pub(super) tools: Vec<RespToolAcc>,
    pub(super) input_tokens: i64,
    pub(super) cached_tokens: i64,
    pub(super) output_tokens: i64,
    pub(super) finish_reason: Option<String>,
    pub(super) stopped: bool,
    pub(super) failed: bool,
}

pub(super) struct TextItemAcc {
    pub(super) index: usize,
    pub(super) id: String,
    pub(super) acc: String,
}

pub(super) struct RespToolAcc {
    pub(super) oa_index: u64,
    pub(super) index: usize,
    pub(super) id: String,
    pub(super) upstream_call_id: String,
    pub(super) call_id: String,
    pub(super) name: String,
    pub(super) args: String,
    pub(super) thought_signature: Option<String>,
    pub(super) announced: bool,
    pub(super) emitted_args_len: usize,
}

impl ChatToResponses {
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
            reasoning: None,
            reasoning_open: false,
            message: None,
            tools: vec![],
            input_tokens: 0,
            cached_tokens: 0,
            output_tokens: 0,
            finish_reason: None,
            stopped: false,
            failed: false,
        }
    }

    pub(super) fn rid(&self) -> String {
        self.resp_id.clone()
    }

    /// The turn's tool calls (with any Gemini thought signatures sniffed from the chat stream),
    /// keyed by the call_id the Responses client will echo back — feeds the gateway's
    /// session-scoped signature cache exactly like ChatToAnthropic. Nameless slots are excluded,
    /// matching what finish() emits (and therefore what the client can echo).
    pub fn captured_tool_calls(&self) -> Vec<CapturedToolCall> {
        self.tools
            .iter()
            .filter(|slot| !slot.name.is_empty())
            .map(|slot| CapturedToolCall {
                call_id: slot.call_id.clone(),
                name: slot.name.clone(),
                arguments: slot.args.clone(),
                thought_signature: slot.thought_signature.clone(),
            })
            .collect()
    }
}
