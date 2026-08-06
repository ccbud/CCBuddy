// Gateway core.
//
// Implements deterministic model routing and the localhost reverse proxy: header sanitizing,
// upstream forwarding, 429 retry, SSE streaming with model rewrite + usage sniffing, buffered-JSON
// model rewrite, /v1/models merge/synthesize, count_tokens fallback, HEAD / fallback, and bounded
// monitor exchange capture.
#![allow(dead_code)]

mod capture;
mod finish;
mod finish_buffered;
mod finish_translated;
mod forward;
mod handler;
mod history_args;
mod history_prep;
mod mock;
mod models;
mod monitor;
mod prepare;
mod redact;
mod responses_history;
mod retry;
mod routing;
mod selftest;
mod selftest_routing;
mod selftest_xlate;
mod session;
mod signatures;
mod sse;
mod state;
mod stream_passthrough;
mod stream_transcode;
mod targets;

#[allow(unused_imports)]
pub use mock::start_mock_upstream;
#[allow(unused_imports)]
pub use routing::{resolve_routing, Routing, CLAUDE_TIER_MODELS, CODEX_TIER_MODELS};
pub use selftest::gateway_selftest;
pub use selftest_routing::routing_selftest;
pub use state::GatewayState;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_history;
#[cfg(test)]
mod tests_routing;
#[cfg(test)]
mod tests_signatures;
