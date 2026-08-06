// Batch helper warm-up: one helper invocation per data root instead of one per file, plus the
// small base64 decoder its output needs. Moved verbatim from qoder.rs.

use std::path::PathBuf;

#[cfg(target_os = "macos")]
use serde_json::Value;
#[cfg(target_os = "macos")]
use std::collections::HashMap;
#[cfg(target_os = "macos")]
use std::fs;
#[cfg(target_os = "macos")]
use std::io;
#[cfg(target_os = "macos")]
use std::path::Path;
#[cfg(target_os = "macos")]
use std::process::Command;
#[cfg(target_os = "macos")]
use std::sync::Arc;
#[cfg(target_os = "macos")]
use super::exec::run_helper_bounded;
#[cfg(target_os = "macos")]
use super::guard::validated_qoder_data_path;
#[cfg(target_os = "macos")]
use super::helper::{installed_qoder_helper, verify_helper_trust};
#[cfg(target_os = "macos")]
use super::limits::{HELPER_BATCH_TIMEOUT, MAX_READ_BYTES, QODER_BATCH_READ_SCRIPT};
#[cfg(target_os = "macos")]
use super::read::{file_stamp, helper_cache_get, helper_cache_put};

/// Minimal standard-alphabet base64 decoder for the batch helper's output (node/bun emit padded
/// base64 without line breaks; stray CR/LF are tolerated anyway).
pub(super) fn b64_decode(s: &str) -> Option<Vec<u8>> {
    fn val(b: u8) -> Option<u32> {
        match b {
            b'A'..=b'Z' => Some((b - b'A') as u32),
            b'a'..=b'z' => Some((b - b'a' + 26) as u32),
            b'0'..=b'9' => Some((b - b'0' + 52) as u32),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let mut chunk = [0u32; 4];
    let mut n = 0usize;
    let mut pad = 0usize;
    for &b in bytes {
        if b == b'\r' || b == b'\n' {
            continue;
        }
        if b == b'=' {
            pad += 1;
            chunk[n] = 0;
        } else {
            if pad > 0 {
                return None; // data after padding
            }
            chunk[n] = val(b)?;
        }
        n += 1;
        if n == 4 {
            let v = (chunk[0] << 18) | (chunk[1] << 12) | (chunk[2] << 6) | chunk[3];
            out.push((v >> 16) as u8);
            if pad < 2 {
                out.push((v >> 8) as u8);
            }
            if pad < 1 {
                out.push(v as u8);
            }
            n = 0;
            if pad > 0 {
                break;
            }
        }
    }
    (n == 0).then_some(out)
}

/// Warm the helper cache for many qoder files with ONE helper invocation per data root — the
/// list, search, usage, and subagent scans otherwise pay one bun startup per file on a protected
/// macOS install (the measured stall is seconds for a first refresh). Directly-readable and
/// fresh-cached files are skipped; per-file failures fall back to the on-demand single read.
/// No-op off macOS.
pub(crate) fn prefetch(paths: &[PathBuf]) {
    #[cfg(target_os = "macos")]
    prefetch_macos(paths);
    #[cfg(not(target_os = "macos"))]
    let _ = paths;
}

#[cfg(target_os = "macos")]
fn prefetch_macos(paths: &[PathBuf]) {
    // (canonical helper target, original cache key, stamp)
    let mut by_root: HashMap<PathBuf, Vec<(PathBuf, PathBuf, f64, u64)>> = HashMap::new();
    for path in paths {
        let Ok((mt, size)) = file_stamp(path) else { continue };
        if size > MAX_READ_BYTES as u64 || helper_cache_get(path, mt, size).is_some() {
            continue;
        }
        match fs::File::open(path) {
            Ok(_) => continue, // direct reads work — the ordinary path is cheap
            Err(error) if error.kind() == io::ErrorKind::PermissionDenied => {}
            Err(_) => continue,
        }
        let Ok((canonical, root)) = validated_qoder_data_path(path) else { continue };
        by_root.entry(root).or_default().push((canonical, path.clone(), mt, size));
    }
    for (root, files) in by_root {
        let Ok(helper) = installed_qoder_helper(&root) else { continue };
        if verify_helper_trust(&helper).is_err() {
            continue;
        }
        // Small argv chunks keep each spawn's total output within the shared byte cap and far
        // below ARG_MAX; a lost chunk (timeout/oversize) degrades to per-file reads, not failure.
        for chunk in files.chunks(32) {
            let mut cmd = Command::new(&helper);
            cmd.env("BUN_BE_BUN", "1").arg("-e").arg(QODER_BATCH_READ_SCRIPT);
            for (canonical, _, _, _) in chunk {
                cmd.arg(canonical);
            }
            let Ok(out) = run_helper_bounded(cmd, MAX_READ_BYTES, HELPER_BATCH_TIMEOUT, 0) else {
                continue;
            };
            let by_canonical: HashMap<&Path, (&PathBuf, f64, u64)> = chunk
                .iter()
                .map(|(canonical, original, mt, size)| (canonical.as_path(), (original, *mt, *size)))
                .collect();
            for line in out.split(|b| *b == b'\n') {
                let Ok(row) = serde_json::from_slice::<Value>(line) else { continue };
                let Some(p) = row.get("p").and_then(Value::as_str) else { continue };
                let Some(&(original, mt, size)) = by_canonical.get(Path::new(p)) else { continue };
                let Some(bytes) = row.get("b64").and_then(Value::as_str).and_then(b64_decode) else {
                    continue; // per-file err rows fall back to the single-read path on demand
                };
                helper_cache_put(original, mt, size, Arc::new(bytes));
            }
        }
    }
}
