// Read-size, timeout and cache budgets for the Qoder CLI helper path, plus the two tiny
// JavaScript programs it is handed. Moved verbatim from qoder.rs.

#[cfg(target_os = "macos")]
use std::time::Duration;

/// Keep the privileged helper path bounded even if the on-disk file changes while it is read.
/// This is deliberately much larger than normal transcripts, while still preventing an
/// accidental/untrusted child process from filling the app's memory with stdout.
pub(super) const MAX_READ_BYTES: usize = 256 * 1024 * 1024;

/// Hard deadline for one helper invocation — generous for a MAX_READ_BYTES read, but bounded so
/// a wedged helper can never pin a sync command thread (and with it the renderer's coalesced
/// request slot for that session) until app restart. Batches get longer since they serve many
/// files in one spawn.
#[cfg(target_os = "macos")]
pub(super) const HELPER_TIMEOUT: Duration = Duration::from_secs(15);
#[cfg(target_os = "macos")]
pub(super) const HELPER_BATCH_TIMEOUT: Duration = Duration::from_secs(45);

/// Byte budget for the helper-read cache (see helper_cache) — cleared wholesale when exceeded,
/// mirroring the search cache's crude-but-safe policy.
pub(super) const HELPER_CACHE_BUDGET: usize = 256 * 1024 * 1024;

pub(super) const QODER_READ_SCRIPT: &str =
    "const fs=require(\"fs\");process.stdout.write(fs.readFileSync(process.argv[1]))";

/// Batch counterpart: one line of JSON per argv file — content as base64 (`b64`) or a per-file
/// error (`err`) that must not abort the rest of the batch.
#[cfg(target_os = "macos")]
pub(super) const QODER_BATCH_READ_SCRIPT: &str = "const fs=require(\"fs\");for(const p of process.argv.slice(1)){let line;try{line=JSON.stringify({p,b64:fs.readFileSync(p).toString(\"base64\")})}catch(e){line=JSON.stringify({p,err:String(e&&e.code||e)})}process.stdout.write(line+\"\\n\")}";
