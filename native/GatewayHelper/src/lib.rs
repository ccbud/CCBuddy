//! Headless CC Buddy gateway.
//!
//! The listener and provider failover architecture follows cc-switch's Axum/Hyper proxy while the
//! protocol module is compiled directly from CC Buddy's existing codec source. Keeping that codec
//! as the single source of truth preserves Anthropic, OpenAI Chat, and OpenAI Responses behavior
//! (including tool history) across the Tauri and native applications.

pub mod anthropic_reasoning;
pub mod auth;
mod citation_renderer;
pub mod config;
pub mod content_encoding;
pub mod error;
pub mod forwarder;
pub mod header_case;
pub mod hosted_web_search;
pub mod models;
pub mod monitor;
pub mod server;
pub mod state;
pub mod upstream;

pub mod circuit_breaker;
pub mod retry;
pub mod routing;

#[path = "../../../src-tauri/src/counttokens.rs"]
pub mod counttokens;

#[allow(
    unused_imports,
    clippy::manual_saturating_arithmetic,
    clippy::needless_borrow,
    clippy::unnecessary_map_or,
    clippy::useless_vec
)]
#[path = "../../../src-tauri/src/protocol/mod.rs"]
pub mod protocol;

pub use config::GatewayConfig;
pub use error::GatewayError;
pub use server::{run, BoundListeners};
