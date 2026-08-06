// Protocol translation between the three LLM API wire formats:
//   - Anthropic Messages   (/v1/messages)          — what Claude Code speaks
//   - OpenAI Chat           (/v1/chat/completions)
//   - OpenAI Responses      (/v1/responses)
//
// Engine: the `llm-connector` crate provides a mature unified IR (ChatRequest / ChatResponse),
// OpenAI+Responses request encoders (build_chat_request_body / build_responses_request), and
// per-protocol response decoders (parse_response / …). llm-connector is a CLIENT library, so it
// lacks the two "Anthropic server-side" halves a Claude-Code-facing gateway needs — those live
// here (anthropic.rs): the Anthropic REQUEST → IR decoder and the IR → Anthropic RESPONSE encoder.
//
// Direction for a request = decode(client wire) → IR → encode(provider wire). The identity case
// (client and provider speak the same protocol) never enters this module — gateway.rs keeps its
// verbatim passthrough fast path for it, so existing Anthropic→Anthropic behavior is unchanged.

#![allow(dead_code)]

pub mod anthropic;
mod codec;
pub mod codex_history;
pub mod openai_chat_client;
pub mod openai_responses;
mod signatures;
pub mod stream;
#[cfg(test)]
mod tests;
mod wire;

pub use codec::{
    can_transcode_stream, decode_client_request, decode_upstream_response, encode_client_response,
    encode_client_response_sse, encode_upstream_request,
};
pub use signatures::uid;
pub(crate) use signatures::{json_thought_signature, tool_call_thought_signature};
pub use wire::{should_try_v1_fallback, Wire};
