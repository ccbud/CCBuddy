// Minimal ZIP reader/writer for conversation bundles. Rust port of src/main/zipStore.js — the byte
// layout is proven there by test/zip.test.js (round-trip + system `unzip`), so this mirror stays in
// lockstep with it.
//
// A conversation with subagents exports as a .zip whose FIRST level is the main session .jsonl and
// whose `subagents/` directory holds the per-subagent files; re-importing restores that layout.
// Only the round-trip slice of the spec is implemented:
//   - write: STORE or raw-DEFLATE per entry (whichever is smaller), no zip64, no data descriptors.
//   - read : parse via the central directory (so OS-repacked zips with data descriptors still read),
//            handling STORE (0) and DEFLATE (8); unreadable members are skipped, never panic.

#![allow(dead_code)]


mod bundle;
mod read;
mod write;
#[cfg(test)]
mod tests;

pub use bundle::split_bundle;
pub use read::read;
pub use write::{build, Entry};
