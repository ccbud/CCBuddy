// Reading Qoder data files: the ordinary filesystem path, the macOS helper fallback, and the
// (mtime, size) memo that keeps repeat reads of the same file version off the helper. Moved
// verbatim from qoder.rs.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use super::limits::{HELPER_CACHE_BUDGET, MAX_READ_BYTES};
use super::guard::too_large;

#[cfg(target_os = "macos")]
use std::process::Command;
#[cfg(target_os = "macos")]
use super::exec::run_helper_bounded;
#[cfg(target_os = "macos")]
use super::guard::validated_qoder_data_path;
#[cfg(target_os = "macos")]
use super::helper::{installed_qoder_helper, verify_helper_trust};
#[cfg(target_os = "macos")]
use super::limits::{HELPER_TIMEOUT, QODER_READ_SCRIPT};

#[cfg(target_os = "macos")]
fn read_with_qoder_helper(path: &Path) -> io::Result<Vec<u8>> {
    let (path, root) = validated_qoder_data_path(path)?;
    let helper = installed_qoder_helper(&root)?;
    verify_helper_trust(&helper)?;
    let expected_len = fs::metadata(&path)?.len().min(MAX_READ_BYTES as u64) as usize;

    // Qoder CLI is a Bun executable. Passing the fixed program and target as distinct argv
    // entries is important: never interpolate a path into JavaScript or a shell command.
    let mut cmd = Command::new(helper);
    cmd.env("BUN_BE_BUN", "1").arg("-e").arg(QODER_READ_SCRIPT).arg(&path);
    run_helper_bounded(cmd, MAX_READ_BYTES, HELPER_TIMEOUT, expected_len)
}

/// Read a local history file. The normal filesystem path is always attempted first; macOS may
/// fall back to Qoder's already-installed CLI only for a permission denial, and only after the
/// helper target passes the strict projects-tree validation above.
pub(crate) fn read_bytes(path: &Path) -> io::Result<Vec<u8>> {
    match fs::read(path) {
        Ok(bytes) if bytes.len() <= MAX_READ_BYTES => Ok(bytes),
        Ok(_) => Err(too_large()),
        Err(error) if error.kind() == io::ErrorKind::PermissionDenied => {
            #[cfg(target_os = "macos")]
            {
                // Serve repeat reads of the same file version from the helper cache — stat still
                // works on content-protected files, so (mtime, size) is a valid freshness key.
                let stamp = file_stamp(path).ok();
                if let Some((mt, size)) = stamp {
                    if let Some(hit) = helper_cache_get(path, mt, size) {
                        return Ok(hit);
                    }
                }
                read_with_qoder_helper(path)
                    .map(|bytes| {
                        if let Some((mt, size)) = stamp {
                            helper_cache_put(path, mt, size, Arc::new(bytes.clone()));
                        }
                        bytes
                    })
                    .map_err(|helper_error| {
                        if matches!(
                            helper_error.kind(),
                            io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied
                        ) {
                            // The original file read was a permission failure. A missing helper
                            // must not turn that into NotFound, which callers interpret as a
                            // moved file.
                            io::Error::new(
                                io::ErrorKind::PermissionDenied,
                                format!(
                                    "Qoder data is not directly readable and its CLI helper is unavailable: {helper_error}"
                                ),
                            )
                        } else {
                            // Size/encoding failures, timeouts, and abnormal helper exits retain
                            // their distinct classification so the UI reports a read failure,
                            // not an auth hint.
                            helper_error
                        }
                    })
            }
            #[cfg(not(target_os = "macos"))]
            {
                Err(error)
            }
        }
        Err(error) => Err(error),
    }
}

/// UTF-8 text counterpart to [`read_bytes`]. Qoder's JSON/JSONL data is defined as UTF-8, so
/// malformed data is reported rather than silently replacing bytes and corrupting records.
pub(crate) fn read_text(path: &Path) -> io::Result<String> {
    String::from_utf8(read_bytes(path)?)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

pub(super) fn mtime_ms_of(meta: &fs::Metadata) -> f64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0)
}

pub(super) fn file_stamp(path: &Path) -> io::Result<(f64, u64)> {
    let meta = fs::metadata(path)?;
    Ok((mtime_ms_of(&meta), meta.len()))
}

/// Bytes fetched through the macOS helper, memoized by (mtime, size) — the list/search/detail
/// paths and the 4s live-follow tick otherwise each pay a bun startup for the SAME file version.
/// Stat keeps working on content-protected files (discovery depends on it), so the stamp is the
/// same freshness signal the list-meta memo uses.
struct HelperCache {
    map: HashMap<PathBuf, (f64, u64, Arc<Vec<u8>>)>,
    bytes: usize,
}

fn helper_cache() -> &'static Mutex<HelperCache> {
    static CACHE: OnceLock<Mutex<HelperCache>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HelperCache { map: HashMap::new(), bytes: 0 }))
}

pub(super) fn helper_cache_get(path: &Path, mt: f64, size: u64) -> Option<Vec<u8>> {
    let cache = helper_cache().lock().ok()?;
    let (cmt, csz, bytes) = cache.map.get(path)?;
    (*cmt == mt && *csz == size).then(|| bytes.as_ref().clone())
}

pub(super) fn helper_cache_put(path: &Path, mt: f64, size: u64, bytes: Arc<Vec<u8>>) {
    if let Ok(mut cache) = helper_cache().lock() {
        if cache.bytes + bytes.len() > HELPER_CACHE_BUDGET {
            cache.map.clear();
            cache.bytes = 0;
        }
        let len = bytes.len();
        if let Some((_, _, old)) = cache.map.insert(path.to_path_buf(), (mt, size, bytes)) {
            cache.bytes = cache.bytes.saturating_sub(old.len());
        }
        cache.bytes += len;
    }
}
