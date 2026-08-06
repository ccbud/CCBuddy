// The (provider → client) transcoder dispatcher gateway.rs holds, regardless of the wired pair.

use super::anthropic_responses::AnthropicToResponses;
use super::chat_anthropic::ChatToAnthropic;
use super::chat_responses::ChatToResponses;
use super::common::CapturedToolCall;
use super::super::openai_responses::CodexToolContext;
use super::super::Wire;


/// Dispatcher over the wired (provider → client) incremental transcoders, so gateway.rs holds one
/// value regardless of the pair. `supports` is the single source of truth behind
/// `protocol::can_transcode_stream`.
pub enum Transcoder {
    ChatToAnthropic(ChatToAnthropic),
    ChatToResponses(ChatToResponses),
    AnthropicToResponses(AnthropicToResponses),
}

impl Transcoder {
    pub fn supports(provider: Wire, client: Wire) -> bool {
        matches!(
            (provider, client),
            (Wire::OpenAiChat, Wire::Anthropic)
                | (Wire::OpenAiChat, Wire::OpenAiResponses)
                | (Wire::Anthropic, Wire::OpenAiResponses)
        )
    }

    pub fn new(provider: Wire, client: Wire, client_model: &str) -> Option<Self> {
        Self::new_with_context(provider, client, client_model, CodexToolContext::default())
    }

    pub fn new_with_context(
        provider: Wire,
        client: Wire,
        client_model: &str,
        tool_context: CodexToolContext,
    ) -> Option<Self> {
        match (provider, client) {
            (Wire::OpenAiChat, Wire::Anthropic) => {
                Some(Self::ChatToAnthropic(ChatToAnthropic::new(client_model)))
            }
            (Wire::OpenAiChat, Wire::OpenAiResponses) => Some(Self::ChatToResponses(
                ChatToResponses::new_with_context(client_model, tool_context),
            )),
            (Wire::Anthropic, Wire::OpenAiResponses) => Some(Self::AnthropicToResponses(
                AnthropicToResponses::new_with_context(client_model, tool_context),
            )),
            _ => None,
        }
    }

    pub fn push(&mut self, line: &str) -> String {
        match self {
            Self::ChatToAnthropic(t) => t.push(line),
            Self::ChatToResponses(t) => t.push(line),
            Self::AnthropicToResponses(t) => t.push(line),
        }
    }

    pub fn finish(&mut self) -> String {
        match self {
            Self::ChatToAnthropic(t) => t.finish(),
            Self::ChatToResponses(t) => t.finish(),
            Self::AnthropicToResponses(t) => t.finish(),
        }
    }

    /// Terminate a translated stream without allowing EOF finalization to synthesize success.
    pub fn fail(&mut self, message: &str) -> String {
        match self {
            Self::ChatToAnthropic(t) => t.fail(message),
            Self::ChatToResponses(t) => t.fail(message),
            Self::AnthropicToResponses(t) => t.fail(message),
        }
    }

    pub fn input_tokens(&self) -> i64 {
        match self {
            Self::ChatToAnthropic(t) => t.input_tokens(),
            Self::ChatToResponses(t) => t.input_tokens(),
            Self::AnthropicToResponses(t) => t.input_tokens(),
        }
    }

    pub fn output_tokens(&self) -> i64 {
        match self {
            Self::ChatToAnthropic(t) => t.output_tokens(),
            Self::ChatToResponses(t) => t.output_tokens(),
            Self::AnthropicToResponses(t) => t.output_tokens(),
        }
    }

    pub fn captured_tool_calls(&self) -> Vec<CapturedToolCall> {
        match self {
            Self::ChatToAnthropic(t) => t.captured_tool_calls(),
            Self::ChatToResponses(t) => t.captured_tool_calls(),
            _ => vec![],
        }
    }

    /// True once the terminal client event (`message_stop` / `response.completed` /
    /// `response.incomplete` / `response.failed`) has been emitted: the turn is semantically
    /// complete even though the upstream socket may not have hit EOF yet — Responses clients
    /// (Codex) hang up exactly at this point, so the gateway must not treat that disconnect as an
    /// abort.
    pub fn done(&self) -> bool {
        match self {
            Self::ChatToAnthropic(t) => t.stopped,
            Self::ChatToResponses(t) => t.stopped,
            Self::AnthropicToResponses(t) => t.stopped,
        }
    }

    pub fn succeeded(&self) -> bool {
        match self {
            Self::ChatToAnthropic(t) => t.stopped && !t.failed,
            Self::ChatToResponses(t) => t.stopped && !t.failed,
            Self::AnthropicToResponses(t) => t.stopped && !t.failed,
        }
    }
}
