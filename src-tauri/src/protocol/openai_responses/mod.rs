// OpenAI Responses (/v1/responses) codec — BOTH halves:
//
//   provider-side (gateway → a Responses upstream):
//     encode_request:  IR → Responses REQUEST body
//     decode_response: Responses RESPONSE → IR
//
//   client-side (a Responses client, i.e. Codex with wire_api="responses", → gateway):
//     decode_request:  Responses REQUEST → IR
//     encode_response / encode_response_sse: IR → Responses RESPONSE (json / synthesized SSE)
//
// The Responses API uses an item-based `input` array (role messages + function_call /
// function_call_output items), `instructions` for the system prompt, `max_output_tokens`, and a
// `reasoning.effort` knob. Its response is an `output` array of items. Tool definitions are
// FLATTENED at the item level (`{"type":"function","name",...}`), unlike Chat Completions.
//
// The client-side halves are hand-rolled rather than reusing llm-connector's
// responses_request_to_chat_request / chat_response_to_responses_response: the crate's versions
// silently DROP function_call / function_call_output / assistant output_text history items and
// tool_calls in responses, and reject the flattened tool form — all fatal for Codex, whose agent
// loop is tool calls end-to-end.
//
// Codex reads the turn's items ONLY from `response.output_item.done` SSE events (text deltas are
// cosmetic; the stream MUST end with `response.completed` carrying id + usage), so the synthesized
// stream emits the full added → delta → done sequence per item.

mod decode_request;
mod decode_response;
mod encode_request;
mod encode_response;
mod encode_sse;
mod helpers;
mod history;
mod parts;
mod tool_collect;
mod tool_items;
mod tool_names;
mod tool_registry;
mod tools;
mod validate;
#[cfg(test)]
mod tests_aliases;
#[cfg(test)]
mod tests_collisions;
#[cfg(test)]
mod tests_extended;
#[cfg(test)]
mod tests_lite;
#[cfg(test)]
mod tests_request;
#[cfg(test)]
mod tests_response;
#[cfg(test)]
mod tests_validate;

pub use decode_request::{decode_request, decode_request_with_context};
pub use decode_response::decode_response;
pub use encode_request::encode_request;
pub use encode_response::{encode_response, encode_response_with_context};
pub use encode_sse::{encode_response_sse, encode_response_sse_with_context};
pub use tools::{CodexToolContext, CodexToolKind};
// CodexToolSpec is part of this module's public surface (kept resolving at
// crate::protocol::openai_responses::CodexToolSpec) but only referenced internally today.
#[allow(unused_imports)]
pub use tools::CodexToolSpec;
pub(crate) use helpers::{custom_tool_input_from_chat_arguments, response_scoped_call_id};
