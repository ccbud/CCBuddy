// Qoder CLI session support — Qoder writes Claude-like transcripts into its own trees
// (`~/.qoder/projects/<encoded-cwd>/<uuid>.jsonl` and the same layout under `~/.qoderwork`,
// subagents in `<uuid>/subagents/agent-*.jsonl`). Qoder streams assistant content as atomic
// wrappers and stores title/workspace/runtime metadata inline, so this module provides the small
// normalization layer needed by the normal Claude pipeline, plus root discovery, safe reads,
// path routing, and the shared foreign-CLI sidecar. The source files belong to another tool and
// are never rewritten, which also means hard-delete refuses them (history.rs).

#![allow(dead_code)]

use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io;
#[cfg(target_os = "macos")]
use std::io::Read;
use std::path::{Path, PathBuf};
#[cfg(target_os = "macos")]
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
#[cfg(target_os = "macos")]
use std::time::{Duration, Instant};

/// Keep the privileged helper path bounded even if the on-disk file changes while it is read.
/// This is deliberately much larger than normal transcripts, while still preventing an
/// accidental/untrusted child process from filling the app's memory with stdout.
const MAX_READ_BYTES: usize = 256 * 1024 * 1024;

/// Hard deadline for one helper invocation — generous for a MAX_READ_BYTES read, but bounded so
/// a wedged helper can never pin a sync command thread (and with it the renderer's coalesced
/// request slot for that session) until app restart. Batches get longer since they serve many
/// files in one spawn.
#[cfg(target_os = "macos")]
const HELPER_TIMEOUT: Duration = Duration::from_secs(15);
#[cfg(target_os = "macos")]
const HELPER_BATCH_TIMEOUT: Duration = Duration::from_secs(45);

/// Byte budget for the helper-read cache (see helper_cache) — cleared wholesale when exceeded,
/// mirroring the search cache's crude-but-safe policy.
const HELPER_CACHE_BUDGET: usize = 256 * 1024 * 1024;

const QODER_READ_SCRIPT: &str =
    "const fs=require(\"fs\");process.stdout.write(fs.readFileSync(process.argv[1]))";

/// Batch counterpart: one line of JSON per argv file — content as base64 (`b64`) or a per-file
/// error (`err`) that must not abort the rest of the batch.
#[cfg(target_os = "macos")]
const QODER_BATCH_READ_SCRIPT: &str = "const fs=require(\"fs\");for(const p of process.argv.slice(1)){let line;try{line=JSON.stringify({p,b64:fs.readFileSync(p).toString(\"base64\")})}catch(e){line=JSON.stringify({p,err:String(e&&e.code||e)})}process.stdout.write(line+\"\\n\")}";

fn home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}

/// Qoder's two known data roots (both observed in the wild): each is a history-dir entry
/// candidate for the auto-add migration; browsing itself walks every configured dir's
/// `projects/` tree, so these only seed historyDirs.
pub fn default_root() -> PathBuf {
    home().join(".qoder")
}

pub fn work_root() -> PathBuf {
    home().join(".qoderwork")
}

/// A qoder install exists at `root` when its projects tree is on disk.
pub fn root_exists(root: &Path) -> bool {
    root.join("projects").is_dir()
}

fn denied(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message.into())
}

fn too_large() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!(
            "Qoder data file exceeds the {} MiB read limit",
            MAX_READ_BYTES / 1024 / 1024
        ),
    )
}

/// Canonicalize a prospective helper target and prove that it is a JSON/JSONL data file in a
/// `projects` directory directly below a `.qoder` or `.qoderwork` root. Canonicalizing the root,
/// projects directory, and target separately prevents a symlink below `projects` from escaping
/// into an arbitrary part of the filesystem.
fn validated_qoder_data_path(path: &Path) -> io::Result<(PathBuf, PathBuf)> {
    let projects = path
        .ancestors()
        .find(|ancestor| {
            ancestor
                .file_name()
                .map(|name| name == "projects")
                .unwrap_or(false)
                && ancestor
                    .parent()
                    .and_then(Path::file_name)
                    .map(|name| name == ".qoder" || name == ".qoderwork")
                    .unwrap_or(false)
        })
        .ok_or_else(|| denied("helper reads are limited to .qoder/.qoderwork projects trees"))?;
    let root = projects
        .parent()
        .ok_or_else(|| denied("Qoder projects directory has no data root"))?;

    let canonical_root = fs::canonicalize(root)?;
    let canonical_projects = fs::canonicalize(projects)?;
    if canonical_projects.parent() != Some(canonical_root.as_path()) {
        return Err(denied("Qoder projects directory escapes its data root"));
    }

    let canonical_path = fs::canonicalize(path)?;
    let relative = canonical_path
        .strip_prefix(&canonical_projects)
        .map_err(|_| denied("Qoder data path escapes its projects directory"))?;
    if relative.as_os_str().is_empty() {
        return Err(denied("Qoder data path must name a file below projects"));
    }

    let is_data_file = matches!(
        canonical_path
            .extension()
            .and_then(|extension| extension.to_str()),
        Some("json") | Some("jsonl")
    );
    if !is_data_file {
        return Err(denied("Qoder helper only reads JSON and JSONL data files"));
    }

    let metadata = fs::metadata(&canonical_path)?;
    if !metadata.is_file() {
        return Err(denied("Qoder data path is not a regular file"));
    }
    if metadata.len() > MAX_READ_BYTES as u64 {
        return Err(too_large());
    }

    Ok((canonical_path, canonical_root))
}

#[cfg(target_os = "macos")]
fn helper_from_install_dir(install_dir: &Path) -> io::Result<PathBuf> {
    let canonical_dir = fs::canonicalize(install_dir)?;
    if !fs::metadata(&canonical_dir)?.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "Qoder CLI helper install directory is not a directory",
        ));
    }

    let version_path = fs::canonicalize(canonical_dir.join("version.txt"))?;
    if version_path.parent() != Some(canonical_dir.as_path()) {
        return Err(denied(
            "Qoder CLI version file escapes its install directory",
        ));
    }
    let version = fs::read_to_string(version_path)?;
    let version = version.trim();
    if version.is_empty()
        || version.len() > 64
        || !version
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Qoder CLI version.txt contains an invalid version",
        ));
    }

    let helper = fs::canonicalize(canonical_dir.join(format!("qodercli-{version}")))?;
    if helper.parent() != Some(canonical_dir.as_path()) || !fs::metadata(&helper)?.is_file() {
        return Err(denied("Qoder CLI helper escapes its install directory"));
    }
    Ok(helper)
}

#[cfg(target_os = "macos")]
fn installed_qoder_helper(current_root: &Path) -> io::Result<PathBuf> {
    let current_install = current_root.join("bin").join("qodercli");
    let home_install = default_root().join("bin").join("qodercli");

    let mut last_error = None;
    for install_dir in [&current_install, &home_install] {
        match helper_from_install_dir(install_dir) {
            Ok(helper) => return Ok(helper),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "installed Qoder CLI helper was not found",
        )
    }))
}

/// The helper lives in a user-writable tree, so before executing it must prove it wasn't planted:
/// owned by the same uid as $HOME, neither it nor its directory group/world-writable, a valid
/// strict codesign signature, and a real TeamIdentifier (rejects ad-hoc-signed payloads). Same-uid
/// malware can defeat any same-uid check by definition — the goal is to stop weaker writers and
/// unsigned binaries, and to guarantee a signing-identity trail for anything that does run.
/// codesign hashes the whole (large) binary, so the verdict is memoized per (path, mtime, size).
#[cfg(target_os = "macos")]
fn verify_helper_trust(helper: &Path) -> io::Result<()> {
    static VERDICTS: OnceLock<Mutex<HashMap<PathBuf, (f64, u64, bool)>>> = OnceLock::new();
    let meta = fs::metadata(helper)?;
    let (mt, size) = (mtime_ms_of(&meta), meta.len());
    let cache = VERDICTS.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(guard) = cache.lock() {
        if let Some((cmt, csz, ok)) = guard.get(helper) {
            if *cmt == mt && *csz == size {
                return if *ok {
                    Ok(())
                } else {
                    Err(denied("Qoder CLI helper previously failed trust verification"))
                };
            }
        }
    }
    let verdict = helper_trust_checks(helper, &meta);
    if let Ok(mut guard) = cache.lock() {
        guard.insert(helper.to_path_buf(), (mt, size, verdict.is_ok()));
    }
    verdict
}

#[cfg(target_os = "macos")]
fn helper_trust_checks(helper: &Path, meta: &fs::Metadata) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let home_uid = fs::metadata(home())?.uid();
    let dir_meta = match helper.parent() {
        Some(dir) => fs::metadata(dir)?,
        None => return Err(denied("Qoder CLI helper has no install directory")),
    };
    for (what, m) in [("helper", meta), ("helper directory", &dir_meta)] {
        if m.uid() != home_uid {
            return Err(denied(format!("Qoder CLI {what} is not owned by the current user")));
        }
        if m.mode() & 0o022 != 0 {
            return Err(denied(format!("Qoder CLI {what} is group/world writable")));
        }
    }
    // codesign is Apple's own bounded tool — a plain blocking call is fine here.
    let valid = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "--"])
        .arg(helper)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    if !valid.success() {
        return Err(denied("Qoder CLI helper has no valid code signature"));
    }
    let display = Command::new("/usr/bin/codesign")
        .args(["-d", "--verbose=2", "--"])
        .arg(helper)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()?; // codesign -d prints its details on stderr
    let info = String::from_utf8_lossy(&display.stderr);
    let has_team = info.lines().any(|line| {
        let line = line.trim_start();
        line.starts_with("TeamIdentifier=") && line != "TeamIdentifier=not set"
    });
    if !has_team {
        return Err(denied("Qoder CLI helper is not signed with a developer Team ID"));
    }
    Ok(())
}

/// Poll the child for exit until `deadline`; None = still running when time ran out.
#[cfg(target_os = "macos")]
fn wait_deadline(
    child: &mut std::process::Child,
    deadline: Instant,
) -> io::Result<Option<std::process::ExitStatus>> {
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(Some(status));
        }
        if Instant::now() >= deadline {
            return Ok(None);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Run a prepared helper command with a hard deadline. stdout drains on its own thread (bounded
/// at `stdout_cap`), stderr on another (an 8 KiB diagnostic tail, then discarded so a chatty
/// child can't deadlock on a full pipe), the child is killed at the deadline or on an oversized
/// stream, and exit is polled — a helper that closes stdout but never exits still can't pin the
/// calling thread.
#[cfg(target_os = "macos")]
fn run_helper_bounded(
    mut cmd: Command,
    stdout_cap: usize,
    timeout: Duration,
    expected_len: usize,
) -> io::Result<Vec<u8>> {
    use std::sync::mpsc;
    let timed_out = || io::Error::new(io::ErrorKind::TimedOut, "Qoder CLI helper timed out");
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let deadline = Instant::now() + timeout;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "Qoder CLI stdout was not captured"))?;
    let (tx, rx) = mpsc::channel();
    // Pre-allocate for the expected payload, capped — metadata could claim MAX_READ_BYTES and an
    // upfront 256 MiB allocation per read is needless; Vec growth covers honest large files.
    let prealloc = expected_len.min(8 * 1024 * 1024);
    let cap = stdout_cap as u64;
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::with_capacity(prealloc);
        let result = stdout.by_ref().take(cap + 1).read_to_end(&mut bytes);
        let _ = tx.send((result, bytes));
    });
    let (etx, erx) = mpsc::channel();
    let stderr_reader = child.stderr.take().map(|mut pipe| {
        std::thread::spawn(move || {
            let mut tail = Vec::with_capacity(1024);
            let _ = pipe.by_ref().take(8192).read_to_end(&mut tail);
            let _ = io::copy(&mut pipe, &mut io::sink());
            let _ = etx.send(tail);
        })
    });
    let kill = |child: &mut std::process::Child| {
        let _ = child.kill();
        let _ = child.wait();
    };
    let remaining = deadline.saturating_duration_since(Instant::now());
    let (read_result, bytes) = match rx.recv_timeout(remaining) {
        Ok(outcome) => outcome,
        Err(_) => {
            kill(&mut child); // pipe closes → reader threads unblock and exit
            let _ = reader.join();
            return Err(timed_out());
        }
    };
    let _ = reader.join();
    if let Err(error) = read_result {
        kill(&mut child);
        return Err(error);
    }
    if bytes.len() > stdout_cap {
        kill(&mut child);
        return Err(too_large());
    }
    let status = match wait_deadline(&mut child, deadline)? {
        Some(status) => status,
        None => {
            kill(&mut child);
            return Err(timed_out());
        }
    };
    let stderr_tail = stderr_reader
        .and_then(|_| erx.recv_timeout(Duration::from_millis(200)).ok())
        .unwrap_or_default();
    if !status.success() {
        let detail = String::from_utf8_lossy(&stderr_tail);
        let detail = detail.trim();
        return Err(io::Error::new(
            io::ErrorKind::Other,
            if detail.is_empty() {
                format!("Qoder CLI helper exited with status {status}")
            } else {
                format!("Qoder CLI helper exited with status {status}: {detail}")
            },
        ));
    }
    Ok(bytes)
}

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

fn mtime_ms_of(meta: &fs::Metadata) -> f64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0)
}

fn file_stamp(path: &Path) -> io::Result<(f64, u64)> {
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

fn helper_cache_get(path: &Path, mt: f64, size: u64) -> Option<Vec<u8>> {
    let cache = helper_cache().lock().ok()?;
    let (cmt, csz, bytes) = cache.map.get(path)?;
    (*cmt == mt && *csz == size).then(|| bytes.as_ref().clone())
}

fn helper_cache_put(path: &Path, mt: f64, size: u64, bytes: Arc<Vec<u8>>) {
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

/// Minimal standard-alphabet base64 decoder for the batch helper's output (node/bun emit padded
/// base64 without line breaks; stray CR/LF are tolerated anyway).
fn b64_decode(s: &str) -> Option<Vec<u8>> {
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

/// Container-shape test for routing: a .jsonl anywhere under a `.qoder/projects/` or
/// `.qoderwork/projects/` tree (main sessions AND `<uuid>/subagents/agent-*.jsonl`).
pub fn looks_qoder_path(file: &Path) -> bool {
    if file.extension().and_then(|e| e.to_str()) != Some("jsonl") {
        return false;
    }
    let mut child: Option<&std::ffi::OsStr> = None;
    for anc in file.ancestors().skip(1) {
        let name = match anc.file_name() {
            Some(n) => n,
            None => break,
        };
        if (name == ".qoder" || name == ".qoderwork")
            && child.map(|c| c == "projects").unwrap_or(false)
        {
            return true;
        }
        child = Some(name);
    }
    false
}

/// The session uuid (its file stem) — sidecar key and renderer id both build on it.
fn session_stem(file: &Path) -> String {
    file.file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string()
}

fn sidecar_key(file: &Path) -> String {
    format!("qoder:{}", session_stem(file))
}

fn trimmed_string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn latest_inline_string(records: &[Value], record_type: &str, field: &str) -> Option<String> {
    records.iter().rev().find_map(|record| {
        (record.get("type").and_then(Value::as_str) == Some(record_type))
            .then(|| trimmed_string(record.get(field)))
            .flatten()
    })
}

fn text_content(value: &Value) -> Option<String> {
    if let Some(text) = value.as_str() {
        let text = text.trim();
        return (!text.is_empty()).then(|| text.to_owned());
    }
    if let Some(blocks) = value.as_array() {
        let parts: Vec<&str> = blocks
            .iter()
            .filter_map(|block| {
                if let Some(text) = block.as_str() {
                    return Some(text);
                }
                let kind = block.get("type").and_then(Value::as_str).unwrap_or("");
                matches!(kind, "text" | "input_text")
                    .then(|| block.get("text").and_then(Value::as_str))
                    .flatten()
            })
            .map(str::trim)
            .filter(|part| !part.is_empty())
            .collect();
        if !parts.is_empty() {
            return Some(parts.join("\n"));
        }
    }
    value
        .get("text")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

fn summary_from(records: &[Value]) -> Option<String> {
    records.iter().rev().find_map(|record| {
        if record.get("type").and_then(Value::as_str) != Some("summary") {
            return None;
        }
        trimmed_string(record.get("summary"))
            .or_else(|| record.get("content").and_then(text_content))
            .or_else(|| {
                record
                    .get("message")
                    .and_then(|message| message.get("content"))
                    .and_then(text_content)
            })
    })
}

fn first_user_text_from(records: &[Value]) -> Option<String> {
    records
        .iter()
        .find_map(|record| match record.get("type").and_then(Value::as_str) {
            Some("user")
                if record.get("isMeta").and_then(Value::as_bool) != Some(true)
                    && record.get("isCompactSummary").and_then(Value::as_bool) != Some(true) =>
            {
                record
                    .get("message")
                    .and_then(|message| message.get("content"))
                    .and_then(text_content)
            }
            Some("attachment")
                if record
                    .get("attachment")
                    .and_then(|attachment| attachment.get("type"))
                    .and_then(Value::as_str)
                    == Some("queued_command") =>
            {
                trimmed_string(
                    record
                        .get("attachment")
                        .and_then(|attachment| attachment.get("prompt")),
                )
            }
            _ => None,
        })
}

/// Qoder's inline title, in the same precedence used by its own conversation list. Repeated
/// metadata records are append-only updates, so the last non-empty value wins within each tier.
pub(crate) fn session_title_from(records: &[Value]) -> Option<String> {
    latest_inline_string(records, "custom-title", "customTitle")
        .or_else(|| latest_inline_string(records, "ai-title", "aiTitle"))
        .or_else(|| latest_inline_string(records, "last-prompt", "lastPrompt"))
        .or_else(|| summary_from(records))
        .or_else(|| first_user_text_from(records))
}

/// Primary workspace from Qoder's latest inline `workspace-directories` record.
pub(crate) fn working_dir_from(records: &[Value]) -> Option<String> {
    records.iter().rev().find_map(|record| {
        if record.get("type").and_then(Value::as_str) != Some("workspace-directories") {
            return None;
        }
        record
            .get("directories")
            .and_then(Value::as_array)
            .and_then(|directories| {
                directories
                    .iter()
                    .find_map(|value| trimmed_string(Some(value)))
            })
    })
}

/// Effective model from Qoder's latest inline `runtime-config` update.
pub(crate) fn model_from(records: &[Value]) -> Option<String> {
    latest_inline_string(records, "runtime-config", "model")
}

fn has_value(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::String(value) => !value.trim().is_empty(),
        Value::Array(value) => !value.is_empty(),
        Value::Object(value) => !value.is_empty(),
        Value::Bool(_) | Value::Number(_) => true,
    }
}

fn without_redacted_thinking(record: &Value) -> Value {
    let mut record = record.clone();
    if let Some(content) = record
        .get_mut("message")
        .and_then(|message| message.get_mut("content"))
        .and_then(Value::as_array_mut)
    {
        content
            .retain(|block| block.get("type").and_then(Value::as_str) != Some("redacted_thinking"));
    }
    record
}

fn merge_assistant_wrapper(target: &mut Value, wrapper: &Value) {
    let Some(source_message) = wrapper.get("message").and_then(Value::as_object) else {
        return;
    };
    let Some(target_message) = target.get_mut("message").and_then(Value::as_object_mut) else {
        return;
    };

    if let Some(source_content) = source_message.get("content").and_then(Value::as_array) {
        match target_message.get_mut("content") {
            Some(Value::Array(target_content)) => {
                target_content.extend(source_content.iter().cloned())
            }
            Some(Value::Null) | None => {
                target_message.insert("content".to_string(), Value::Array(source_content.clone()));
            }
            Some(_) => {}
        }
    }

    for field in ["model", "usage", "stop_reason"] {
        if let Some(value) = source_message.get(field).filter(|value| has_value(value)) {
            target_message.insert(field.to_string(), value.clone());
        }
    }
}

fn queued_command_as_user(record: &Value) -> Option<Value> {
    let attachment = record.get("attachment")?;
    if attachment.get("type").and_then(Value::as_str) != Some("queued_command") {
        return None;
    }
    let prompt = attachment
        .get("prompt")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let mut normalized = record.clone();
    let object = normalized.as_object_mut()?;
    object.insert("type".to_string(), Value::String("user".to_string()));
    object.insert(
        "message".to_string(),
        json!({ "role": "user", "content": prompt }),
    );
    object.remove("attachment");
    Some(normalized)
}

/// Content sniff for qoder transcripts that lost their container path (import copies, bundle
/// zips): the inline metadata / queued-command record types are qoder-only vocabulary that no
/// Claude Code or Codex transcript produces.
pub(crate) fn looks_qoder_records(records: &[Value]) -> bool {
    records.iter().any(|record| match record.get("type").and_then(Value::as_str) {
        Some("agent-setting") | Some("ai-title") | Some("custom-title") | Some("last-prompt")
        | Some("workspace-directories") | Some("runtime-config") => true,
        Some("attachment") => {
            record
                .get("attachment")
                .and_then(|attachment| attachment.get("type"))
                .and_then(Value::as_str)
                == Some("queued_command")
        }
        _ => false,
    })
}

/// Convert Qoder's append-only wire records into the Claude-like records expected by the shared
/// history shaper. Atomic assistant wrappers with the same `message.id` collapse at their first
/// position, queued prompts become user messages, and opaque duplicate thinking blocks are
/// discarded in favor of the corresponding ordinary `thinking` block.
pub(crate) fn normalize_records(records: &[Value]) -> Vec<Value> {
    let mut normalized = Vec::with_capacity(records.len());
    let mut assistant_by_message_id: HashMap<String, usize> = HashMap::new();

    for record in records {
        if let Some(user) = queued_command_as_user(record) {
            normalized.push(user);
            continue;
        }
        if record.get("type").and_then(Value::as_str) != Some("assistant") {
            normalized.push(record.clone());
            continue;
        }

        let wrapper = without_redacted_thinking(record);
        let message_id = wrapper
            .get("message")
            .and_then(|message| message.get("id"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .map(str::to_owned);
        if let Some(message_id) = message_id {
            if let Some(index) = assistant_by_message_id.get(&message_id).copied() {
                merge_assistant_wrapper(&mut normalized[index], &wrapper);
            } else {
                assistant_by_message_id.insert(message_id, normalized.len());
                normalized.push(wrapper);
            }
        } else {
            normalized.push(wrapper);
        }
    }

    normalized
}

/// (custom title, tags, deleted) from the shared agent sidecar (~/.ccbud/agent-meta.json).
pub fn sidecar_meta(file: &Path) -> (Option<String>, Vec<String>, bool) {
    crate::sidecar::meta(&crate::sidecar::agent_file(), &sidecar_key(file))
}

pub fn is_deleted(file: &Path) -> bool {
    sidecar_meta(file).2
}

pub fn set_meta(file: &str, patch: &Value) -> Value {
    let key = sidecar_key(Path::new(file));
    if key == "qoder:" {
        return json!({ "ok": false, "reason": "empty" });
    }
    crate::sidecar::set_meta(&crate::sidecar::agent_file(), &key, patch)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("ccbud-qoder-{name}-{}", std::process::id()))
    }

    #[test]
    fn detects_qoder_paths() {
        assert!(looks_qoder_path(Path::new(
            "/h/.qoder/projects/-Users-a-p/1111-uuid.jsonl"
        )));
        assert!(looks_qoder_path(Path::new(
            "/h/.qoderwork/projects/-Users-a-p/1111-uuid.jsonl"
        )));
        // subagent transcripts under the session's own dir route too (search scans them)
        assert!(looks_qoder_path(Path::new(
            "/h/.qoder/projects/-enc/1111-uuid/subagents/agent-x.jsonl"
        )));
        assert!(!looks_qoder_path(Path::new(
            "/h/.claude/projects/-enc/1111-uuid.jsonl"
        )));
        assert!(!looks_qoder_path(Path::new(
            "/h/.qoder/projects/-enc/session-state.json"
        )));
        // projects/ must be DIRECTLY under the qoder root
        assert!(!looks_qoder_path(Path::new(
            "/h/.qoder/sessions/-enc/1111-uuid.jsonl"
        )));
        assert!(!looks_qoder_path(Path::new(
            "/h/qoder/projects/-enc/1111-uuid.jsonl"
        )));
    }

    #[test]
    fn extracts_inline_title_workspace_and_runtime_metadata() {
        let records = vec![
            json!({ "type": "user", "isMeta": true, "message": { "content": "hidden setup" } }),
            json!({ "type": "user", "message": { "content": [{ "type": "tool_result", "content": "not a title" }] } }),
            json!({ "type": "user", "message": { "content": " First real prompt " } }),
            json!({ "type": "summary", "summary": " Summary fallback " }),
            json!({ "type": "last-prompt", "lastPrompt": " Older prompt " }),
            json!({ "type": "last-prompt", "lastPrompt": " Latest prompt " }),
            json!({ "type": "ai-title", "aiTitle": " Generated title " }),
            json!({ "type": "custom-title", "customTitle": " " }),
            json!({ "type": "custom-title", "customTitle": " Chosen title " }),
            json!({ "type": "workspace-directories", "directories": ["/old/workspace"] }),
            json!({ "type": "workspace-directories", "directories": [" ", "/work/project", "/work/secondary"] }),
            json!({ "type": "runtime-config", "model": "basic" }),
            json!({ "type": "runtime-config", "model": " " }),
            json!({ "type": "runtime-config", "model": "ultimate" }),
        ];

        assert_eq!(
            session_title_from(&records).as_deref(),
            Some("Chosen title")
        );
        assert_eq!(working_dir_from(&records).as_deref(), Some("/work/project"));
        assert_eq!(model_from(&records).as_deref(), Some("ultimate"));

        assert_eq!(
            session_title_from(&records[..8]).as_deref(),
            Some("Generated title")
        );
        assert_eq!(
            session_title_from(&records[..6]).as_deref(),
            Some("Latest prompt")
        );
        assert_eq!(
            session_title_from(&records[..4]).as_deref(),
            Some("Summary fallback")
        );
        assert_eq!(
            session_title_from(&records[..3]).as_deref(),
            Some("First real prompt")
        );
    }

    #[test]
    fn normalizes_atomic_assistant_wrappers_and_queued_commands() {
        let records = vec![
            json!({ "type": "runtime-config", "model": "ultimate" }),
            json!({
                "type": "assistant", "uuid": "wrapper-1", "timestamp": "2026-01-01T00:00:00Z",
                "message": {
                    "id": "message-1", "role": "assistant", "model": "draft",
                    "content": [
                        { "type": "thinking", "thinking": "plan" },
                        { "type": "redacted_thinking", "data": "opaque duplicate" }
                    ],
                    "usage": { "input_tokens": 1 }, "stop_reason": null
                }
            }),
            json!({
                "type": "assistant", "uuid": "wrapper-2", "timestamp": "2026-01-01T00:00:01Z",
                "message": {
                    "id": "message-1", "role": "assistant", "model": "ultimate",
                    "content": [{ "type": "text", "text": "checking" }],
                    "usage": null, "stop_reason": "tool_use"
                }
            }),
            json!({
                "type": "assistant", "uuid": "wrapper-3", "timestamp": "2026-01-01T00:00:02Z",
                "message": {
                    "id": "message-1", "role": "assistant", "model": " ",
                    "content": [{ "type": "tool_use", "id": "tool-1", "name": "Read", "input": { "file_path": "/work/file" } }],
                    "usage": { "input_tokens": 7, "output_tokens": 3 }, "stop_reason": null
                }
            }),
            json!({
                "type": "attachment", "uuid": "queued-1", "cwd": "/work/project",
                "attachment": { "type": "queued_command", "prompt": "follow up", "commandMode": "agent" }
            }),
            json!({
                "type": "assistant", "uuid": "wrapper-without-id",
                "message": { "role": "assistant", "content": [
                    { "type": "redacted_thinking", "data": "drop me" },
                    { "type": "text", "text": "kept" }
                ] }
            }),
        ];

        let normalized = normalize_records(&records);
        assert_eq!(normalized.len(), 4);
        assert_eq!(normalized[0]["type"], "runtime-config");

        let assistant = &normalized[1];
        assert_eq!(assistant["uuid"], "wrapper-1");
        assert_eq!(assistant["timestamp"], "2026-01-01T00:00:00Z");
        assert_eq!(assistant["message"]["model"], "ultimate");
        assert_eq!(
            assistant["message"]["usage"],
            json!({ "input_tokens": 7, "output_tokens": 3 })
        );
        assert_eq!(assistant["message"]["stop_reason"], "tool_use");
        assert_eq!(
            assistant["message"]["content"]
                .as_array()
                .unwrap()
                .iter()
                .map(|block| block["type"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["thinking", "text", "tool_use"]
        );

        let queued = &normalized[2];
        assert_eq!(queued["type"], "user");
        assert_eq!(queued["uuid"], "queued-1");
        assert_eq!(queued["cwd"], "/work/project");
        assert_eq!(
            queued["message"],
            json!({ "role": "user", "content": "follow up" })
        );
        assert!(queued.get("attachment").is_none());

        assert_eq!(
            normalized[3]["message"]["content"],
            json!([{ "type": "text", "text": "kept" }])
        );
        // The caller's parsed records remain untouched.
        assert_eq!(
            records[1]["message"]["content"].as_array().unwrap().len(),
            2
        );
    }

    #[test]
    fn decodes_batch_helper_base64() {
        assert_eq!(b64_decode("").unwrap(), b"");
        assert_eq!(b64_decode("aGVsbG8=").unwrap(), b"hello");
        assert_eq!(b64_decode("aGVsbG8h").unwrap(), b"hello!");
        assert_eq!(b64_decode("aA==").unwrap(), b"h");
        assert_eq!(b64_decode("5Lit5paH").unwrap(), "中文".as_bytes());
        assert!(b64_decode("not base64!").is_none());
        assert!(b64_decode("aGVsbG8").is_none()); // truncated group
    }

    #[test]
    fn helper_cache_serves_only_fresh_stamps() {
        let path = test_dir("cache").join("t.jsonl");
        assert!(helper_cache_get(&path, 1.0, 10).is_none());
        helper_cache_put(&path, 1.0, 10, Arc::new(b"v1".to_vec()));
        assert_eq!(helper_cache_get(&path, 1.0, 10).unwrap(), b"v1");
        // a changed mtime or size means a new file version — the stale entry must not serve
        assert!(helper_cache_get(&path, 2.0, 10).is_none());
        assert!(helper_cache_get(&path, 1.0, 11).is_none());
        helper_cache_put(&path, 2.0, 10, Arc::new(b"v2".to_vec()));
        assert_eq!(helper_cache_get(&path, 2.0, 10).unwrap(), b"v2");
    }

    #[test]
    fn sniffs_qoder_records_by_inline_vocabulary() {
        assert!(looks_qoder_records(&[json!({ "type": "ai-title", "aiTitle": "t" })]));
        assert!(looks_qoder_records(&[
            json!({ "type": "user", "message": { "content": "hi" } }),
            json!({ "type": "attachment", "attachment": { "type": "queued_command", "prompt": "p" } }),
        ]));
        // plain Claude / Codex shapes must not sniff as qoder
        assert!(!looks_qoder_records(&[
            json!({ "type": "user", "message": { "content": "hi" }, "cwd": "/x" }),
            json!({ "type": "assistant", "message": { "role": "assistant", "content": [] } }),
            json!({ "type": "attachment", "attachment": { "type": "file" } }),
            json!({ "type": "session_meta", "payload": {} }),
        ]));
    }

    #[test]
    fn ordinary_reads_do_not_require_a_qoder_path() {
        let dir = test_dir("ordinary-read");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join("ordinary.txt");
        fs::write(&file, "local UTF-8 文本").unwrap();

        assert_eq!(read_bytes(&file).unwrap(), "local UTF-8 文本".as_bytes());
        assert_eq!(read_text(&file).unwrap(), "local UTF-8 文本");

        fs::write(&file, [0xff, 0xfe]).unwrap();
        assert_eq!(
            read_text(&file).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn helper_target_is_limited_to_canonical_qoder_project_data() {
        let dir = test_dir("path-validation");
        let _ = fs::remove_dir_all(&dir);
        let projects = dir.join(".qoder").join("projects");
        let session = projects.join("-encoded-cwd").join("session-id");
        fs::create_dir_all(&session).unwrap();

        let transcript = projects.join("-encoded-cwd").join("session-id.jsonl");
        let state = session.join("state.json");
        let metadata = session.join("agent-worker.meta.json");
        fs::write(&transcript, "{}\n").unwrap();
        fs::write(&state, "{}").unwrap();
        fs::write(&metadata, "{}").unwrap();

        for file in [&transcript, &state, &metadata] {
            let (validated, root) = validated_qoder_data_path(file).unwrap();
            assert_eq!(validated, fs::canonicalize(file).unwrap());
            assert_eq!(root, fs::canonicalize(dir.join(".qoder")).unwrap());
        }

        let arbitrary = session.join("secret.txt");
        fs::write(&arbitrary, "not helper-readable").unwrap();
        assert_eq!(
            validated_qoder_data_path(&arbitrary).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );

        let outside = dir.join("outside.jsonl");
        fs::write(&outside, "{}\n").unwrap();
        assert_eq!(
            validated_qoder_data_path(&outside).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let escaped = session.join("escaped.jsonl");
            symlink(&outside, &escaped).unwrap();
            assert_eq!(
                validated_qoder_data_path(&escaped).unwrap_err().kind(),
                io::ErrorKind::PermissionDenied
            );
        }

        let _ = fs::remove_dir_all(&dir);
    }
}
