// Incremental SSE transcoders (P2). Consume an upstream provider's streaming events line-by-line
// and emit the client protocol's SSE events as they arrive — true token-by-token streaming, not the
// buffer-then-synthesize first cut. Wired pairs (see `Transcoder`):
//   - OpenAI Chat `chat.completion.chunk` → Anthropic Messages events (Claude Code client)
//   - OpenAI Chat `chat.completion.chunk` → OpenAI Responses events   (Codex client)
//   - Anthropic Messages events           → OpenAI Responses events   (Codex client)

mod ablock;
mod anthropic_responses;
mod anthropic_responses_block;
mod anthropic_responses_finish;
mod anthropic_responses_push;
mod chat_anthropic;
mod chat_anthropic_push;
mod chat_responses;
mod chat_responses_finish;
mod chat_responses_items;
mod chat_responses_push;
mod chat_responses_tools;
mod common;
mod resp_items;
mod transcoder;
#[cfg(test)]
mod tests_anthropic_responses;
#[cfg(test)]
mod tests_chat_anthropic;
#[cfg(test)]
mod tests_chat_responses;
#[cfg(test)]
mod tests_errors;
#[cfg(test)]
mod tests_extended;
#[cfg(test)]
mod tests_ids;

// The three concrete transcoders stay reachable at their original
// crate::protocol::stream::<Name> paths; gateway.rs drives them through `Transcoder`.
#[allow(unused_imports)]
pub use anthropic_responses::AnthropicToResponses;
#[allow(unused_imports)]
pub use chat_anthropic::ChatToAnthropic;
#[allow(unused_imports)]
pub use chat_responses::ChatToResponses;
pub use common::CapturedToolCall;
pub use transcoder::Transcoder;
