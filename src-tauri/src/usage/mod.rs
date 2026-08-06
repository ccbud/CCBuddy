// Usage analytics — aggregation semantics ported from ccusage (github.com/ccusage/ccusage),
// scoped to the two agents ccbud fronts: Claude Code and Codex.
//
// Per active work dir, two session trees contribute:
//
//   Claude Code `projects/**/*.jsonl` (recursive, any depth — sessions, nested session dirs,
//   subagent transcripts all included by construction):
//     - every line whose `message.usage` carries numeric input/output tokens counts — no
//       `type=="assistant"` gate (ccusage parity);
//     - a line without a parseable RFC3339 `timestamp` is DROPPED (never guessed);
//     - cache-creation prefers the nested `cache_creation.ephemeral_{5m,1h}_input_tokens`
//       breakdown over the flat `cache_creation_input_tokens`;
//     - `<synthetic>` models keep their tokens but get no model attribution; `usage.speed=="fast"`
//       appends a `-fast` suffix to the model;
//     - global de-dup by (message.id, requestId) — entries without a message.id are never
//       de-duped; a sidechain replay that reuses the parent's message.id under a NEW requestId
//       collapses onto the parent (non-sidechain wins, then higher token total).
//
//   Codex `sessions/**/*.jsonl` + `archived_sessions/**/*.jsonl` (an archived copy of the same
//   relative path is skipped — the active sessions/ copy wins):
//     - `token_count` events: prefer `info.last_token_usage` (the turn delta); fall back to
//       diffing consecutive `info.total_token_usage` snapshots; the cumulative baseline always
//       advances so either form stays correct;
//     - `thread_spawn` subagent files replay the parent's history as a leading burst of
//       token_count lines sharing one timestamp-second — those are skipped (baseline still
//       advances) so parent turns aren't counted twice;
//     - identical (timestamp, model, tokens) events across files (resumed/forked sessions)
//       de-dup globally;
//     - model comes from the event payload/info, else the last `turn_context`, else "gpt-5";
//       `input_tokens` is INCLUSIVE of `cached_input_tokens` — the cached part is split out into
//       cacheRead and the remainder becomes input.
//
// Day bucketing is local-timezone (chrono::Local), matching ccusage's system-timezone default.

#![allow(dead_code)]
mod build;
mod claude;
mod codex;
mod diag;
mod model;
mod query;
mod roots;
#[cfg(test)]
mod diag_probe;
#[cfg(test)]
mod real_data_probe;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_codex;

pub use build::{invalidate_cache, warm_cache};
pub use diag::{diag, usage_get};
