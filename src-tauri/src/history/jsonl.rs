use serde_json::{json, Value};
use std::fs;
use std::path::Path;

pub(crate) fn parse_lines(text: &str) -> Vec<Value> {
    let mut out = vec![];
    for line in text.split('\n') {
        let s = line.trim();
        if s.is_empty() {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<Value>(s) {
            out.push(v);
        }
    }
    out
}

pub(super) fn read_head_result(file: &Path, max: usize) -> std::io::Result<String> {
    use std::io::{BufRead, BufReader, Read};
    // Qoder data can be protected as "Other Application Data" on macOS. Its reader first
    // attempts the normal filesystem path and uses the installed Qoder CLI only for EPERM;
    // keep the same bounded-head contract used by list metadata after that read succeeds.
    if crate::qoder::looks_qoder_path(file) {
        let mut bytes = crate::qoder::read_bytes(file)?;
        bytes.truncate(max);
        return Ok(String::from_utf8_lossy(&bytes).into_owned());
    }
    let mut file = fs::File::open(file)?;
    let mut buf = vec![0u8; max];
    let read = file.read(&mut buf)?;
    buf.truncate(read);
    // SessionMeta may exceed the ordinary list window because it can embed base instructions and
    // dynamic tools. Extend ONLY when the first record itself has no newline yet; a later partial
    // record can be ignored, avoiding an accidental multi-megabyte image/tool-result read.
    let prefix_len = buf.len().min(4096);
    let compact_prefix: String = String::from_utf8_lossy(&buf[..prefix_len])
        .chars()
        .filter(|value| !value.is_ascii_whitespace())
        .collect();
    let codex_session_meta = compact_prefix
        .find("\"type\":\"session_meta\"")
        .is_some_and(|position| position < 512);
    if codex_session_meta && read == max && !buf.contains(&b'\n') {
        let mut reader = BufReader::new(file);
        let _ = reader.read_until(b'\n', &mut buf)?;
    }
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

pub(crate) fn read_head(file: &Path, max: usize) -> String {
    read_head_result(file, max).unwrap_or_default()
}

pub(super) fn read_session_text(file: &Path) -> std::io::Result<String> {
    if crate::qoder::looks_qoder_path(file) {
        crate::qoder::read_text(file)
    } else {
        fs::read_to_string(file)
    }
}

pub(super) fn read_session_bytes(file: &Path) -> std::io::Result<Vec<u8>> {
    if crate::qoder::looks_qoder_path(file) {
        crate::qoder::read_bytes(file)
    } else {
        fs::read(file)
    }
}

/// Verbatim bytes for raw export. Qoder sessions may require the guarded Qoder CLI fallback on
/// macOS; all other sources retain the ordinary filesystem read used before Qoder support.
pub(crate) fn raw_session_bytes(file: &str) -> std::io::Result<Vec<u8>> {
    read_session_bytes(Path::new(file))
}

pub(crate) fn session_read_error(file: &Path, error: &std::io::Error) -> Value {
    let kind = match error.kind() {
        std::io::ErrorKind::NotFound => "notFound",
        std::io::ErrorKind::PermissionDenied => "permissionDenied",
        _ => "readFailed",
    };
    json!({
        "error": {
            "kind": kind,
            "file": file.to_string_lossy(),
            "message": error.to_string(),
        }
    })
}

pub(super) fn mtime_ms(file: &Path) -> f64 {
    fs::metadata(file)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0)
}

/// File creation (birth) time in ms; mtime on filesystems that don't record one. NOT stable
/// across a title/tag edit — set_ccbud rewrites via tmp+rename, which gives the path the tmp
/// file's (fresh) birth time — so this is only the FALLBACK sort key when a session's records
/// carry no timestamp; record_created_ms is the real one.
pub(crate) fn created_ms(file: &Path) -> f64 {
    fs::metadata(file)
        .and_then(|m| m.created())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as f64)
        .filter(|v| *v > 0.0)
        .unwrap_or_else(|| mtime_ms(file))
}

/// Session creation time for ORDERING: the first record's timestamp, i.e. content-derived and
/// therefore immune to file rewrites — renaming/tagging a conversation (tmp+rename resets the
/// fs birth time) must never reshuffle the list. Falls back to fs times when no record carries
/// a timestamp. Claude records and Codex rollout lines both put `timestamp` at the top level.
pub(crate) fn record_created_ms(recs: &[Value], file: &Path) -> f64 {
    for r in recs {
        if let Some(ts) = r.get("timestamp").and_then(|v| v.as_str()) {
            if let Ok(d) = chrono::DateTime::parse_from_rfc3339(ts) {
                return d.timestamp_millis() as f64;
            }
        }
    }
    created_ms(file)
}
