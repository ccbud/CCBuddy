//! Cross-request history for bridging Codex Responses requests to chat-style upstreams.
//!
//! Responses clients may continue a tool turn with only
//! `previous_response_id + new input`. Chat-style protocols do not implement that
//! server-side continuation, so they need the previous request input and assistant
//! output restored recursively into the next request. Tool outputs additionally need
//! the original assistant call, including its name, arguments, and reasoning metadata.
//! This store records that model-visible context and restores it before conversion.

mod cache_items;
mod inner_index;
mod inner_insert;
mod materialize;
mod merge;
mod resolve;
mod sizing;
mod store;
mod types;
#[cfg(test)]
mod tests_call_fallback;
#[cfg(test)]
mod tests_continuation;
#[cfg(test)]
mod tests_eviction;
#[cfg(test)]
mod tests_hops;
#[cfg(test)]
mod tests_limits;
#[cfg(test)]
mod tests_materialize;
#[cfg(test)]
mod tests_native;

pub use types::{CodexHistoryStore, HistoryResolution, ResponseOrigin};
// ResponseMetadata is this module's public return type for `response_metadata`; keep it resolving
// at crate::protocol::codex_history::ResponseMetadata even though callers destructure it today.
#[allow(unused_imports)]
pub use types::ResponseMetadata;
