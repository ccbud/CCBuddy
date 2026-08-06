// Sidecar plugin manager.
//
// A ccbud plugin is a standalone local program that reuses some coding agent's
// subscription login (e.g. Grok) and exposes a standard inference endpoint on
// localhost. The host does not do protocol/vendor work for it — see
// docs/plugin-system.md. This module owns the piece the gateway can't: process
// lifecycle, port assignment, and health gating.
//
// Key design choice: a running plugin is surfaced as an ordinary provider whose
// baseUrl points at the plugin's localhost port. Enabling a plugin upserts a
// `backend:"plugin"` provider (id = `plugin:<id>`); disabling only stops the process
// (the service stays, removed on uninstall). The
// gateway then routes to it with zero plugin-specific code.
mod git;
mod install;
mod lifecycle;
mod manager;
mod manifest;
mod manifest_meta;
mod providers;
mod status;
mod util;

pub use manager::PluginManager;
pub use util::plugins_root;
