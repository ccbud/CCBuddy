// The "Anthropic server-side" halves that llm-connector (a client library) doesn't provide:
//   - decode_request:  Anthropic Messages REQUEST json  → llm-connector ChatRequest IR
//   - encode_response: llm-connector ChatResponse IR     → Anthropic Messages RESPONSE json
//
// Mapping follows the same shape LiteLLM / musistudio use: Anthropic content blocks are flattened
// into the OpenAI-style IR — `tool_use` blocks become assistant `Message.tool_calls`, `tool_result`
// blocks become separate `role:tool` messages, `system` becomes a leading system message. The IR is
// then encoded to OpenAI Chat (or Responses) by the crate. The reverse rebuilds Anthropic content
// blocks from the IR's tool_calls + text.
//
// Claude Code footguns handled explicitly (LiteLLM shipped bugs on these): user/system content
// blocks arrive as `{"type":"input_text"}` (not `text`) and MUST be recognized, else content is
// silently dropped → upstream 422.

mod blocks;
mod decode;
mod encode;
#[cfg(test)]
mod tests;

pub use decode::decode_request;
pub use encode::{encode_response, encode_response_sse};
