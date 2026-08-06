// OpenAI Chat CLIENT-side codec (P4 reverse direction): when an OpenAI/Codex-style client hits the
// gateway at /v1/chat/completions and the provider is Anthropic, we decode the client's Chat request
// into the IR and re-encode the IR response back to Chat Completions shape. The Anthropic upstream
// side is handled by the crate's AnthropicProtocol.

mod decode;
mod encode;
#[cfg(test)]
mod tests;

pub use decode::decode_request;
pub use encode::{encode_response, encode_response_sse};
