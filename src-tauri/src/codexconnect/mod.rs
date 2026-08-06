// Codex CLI integration — point Codex at the local gateway by injecting a custom model provider
// into ~/.codex/config.toml (CODEX_HOME-aware). Mirrors claude.rs's connect/disconnect+backup, but
// for Codex's TOML config: we add a `[model_providers.ccbud]` block (base_url → gateway, a static
// dev bearer token, requires_openai_auth=false so Codex doesn't demand an sk- prefix) and switch
// `model_provider`/`model` to it. The user's prior model/model_provider are backed up into
// config.codexBackup once; Disconnect restores them and removes our block. Editing is done with
// toml_edit so the user's other settings, comments, and formatting survive untouched.
//
// wire_api = "responses": Codex speaks the OpenAI Responses API to the gateway (Codex has
// deprecated wire_api = "chat" and only supports "responses"), and the gateway translates to
// whatever protocol the ACTIVE provider uses (responses passthrough, responses→chat, or
// responses→messages for an Anthropic provider). Config-path override for tests:
// CCBUD_CODEX_CONFIG.
#![allow(dead_code)]

mod config;
mod connect;
#[cfg(test)]
mod tests;

pub use config::is_available;
pub use connect::{connect, disconnect, is_connected};
