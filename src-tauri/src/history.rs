// Conversation history.
//
// Reads Claude Code and Codex on-disk sessions across configured dirs, imported snapshots, and
// the app-managed recycle bin. Shapes list/detail payloads for the renderer, including subagents,
// custom title/tags/delete metadata, bundle import/export helpers, and live-watch roots.

#![allow(dead_code)]

use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

/// Synthetic "recycle bin" bucket id. Not a real projects tree (never in all_dirs /
/// each_session_file) — a cross-cutting view of soft-deleted sessions across every dir.
pub const TRASH_ID: &str = "__trash__";

fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

fn expand_tilde(p: &str) -> PathBuf {
    if let Some(rest) = p.strip_prefix("~/") {
        home().join(rest)
    } else if p == "~" {
        home()
    } else {
        PathBuf::from(p)
    }
}

/// Configured dirs → (id, label, projects_dir). id == the dir string (historyActive matches it).
fn config_dirs(config: &Value) -> Vec<(String, String, PathBuf)> {
    let mut out = vec![];
    if let Some(arr) = config.get("historyDirs").and_then(|v| v.as_array()) {
        for d in arr {
            if let Some(s) = d.as_str() {
                out.push((s.to_string(), s.to_string(), expand_tilde(s).join("projects")));
            }
        }
    }
    out
}

pub(crate) fn base_name(p: &str) -> String {
    p.split('/').filter(|s| !s.is_empty()).last().unwrap_or(p).to_string()
}

/// Best-effort decode of an encoded project dir name → cwd (record cwd wins when present).
fn decode_dir_name(name: &str) -> Option<String> {
    if name.is_empty() {
        return None;
    }
    let trimmed = name.trim_start_matches('-');
    Some(format!("/{}", trimmed.replace('-', "/")))
}

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

fn read_head_result(file: &Path, max: usize) -> std::io::Result<String> {
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

fn read_session_text(file: &Path) -> std::io::Result<String> {
    if crate::qoder::looks_qoder_path(file) {
        crate::qoder::read_text(file)
    } else {
        fs::read_to_string(file)
    }
}

fn read_session_bytes(file: &Path) -> std::io::Result<Vec<u8>> {
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

fn usage_of(u: &Value) -> Value {
    let mut usage = json!({
        "inputTokens": u.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "outputTokens": u.get("output_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "cacheRead": u.get("cache_read_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "cacheCreation": u.get("cache_creation_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
    });
    let object = usage.as_object_mut().unwrap();
    // Qoder supplies billing/context facts alongside its zeroed token counters. Keep them on the
    // per-turn usage object without adding empty fields to ordinary Claude Code messages.
    for (source, target) in [
        ("credits", "credits"),
        ("original_credits", "originalCredits"),
        ("context_usage_ratio", "contextUsageRatio"),
    ] {
        if let Some(value) = u.get(source).filter(|value| value.is_number()) {
            object.insert(target.to_string(), value.clone());
        }
    }
    usage
}

fn content_text(content: &Value) -> String {
    if let Some(s) = content.as_str() {
        return s.to_string();
    }
    if let Some(arr) = content.as_array() {
        return arr
            .iter()
            .filter(|b| b.get("type").and_then(|t| t.as_str()) == Some("text"))
            .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
            .collect::<Vec<_>>()
            .join(" ");
    }
    String::new()
}

fn command_label(raw: &str) -> String {
    let name = raw
        .split_once("<command-name>")
        .and_then(|(_, r)| r.split_once("</command-name>"))
        .map(|(n, _)| n.trim().to_string())
        .unwrap_or_default();
    if name.is_empty() {
        return String::new();
    }
    let args = raw
        .split_once("<command-args>")
        .and_then(|(_, r)| r.split_once("</command-args>"))
        .map(|(a, _)| a.trim().to_string())
        .unwrap_or_default();
    format!("{} {}", name, args).trim().to_string()
}

/// First human prose turn (skips slash-command XML / meta / interrupt notices), capped at 90 chars.
pub(crate) fn first_user_text(messages: &[Value]) -> String {
    let mut fallback_cmd = String::new();
    for m in messages {
        if m.get("role").and_then(|r| r.as_str()) != Some("user") {
            continue;
        }
        if m.get("_meta").and_then(|v| v.as_bool()).unwrap_or(false) {
            continue;
        }
        let content = m.get("content").cloned().unwrap_or(Value::Null);
        let raw = content_text(&content);
        let raw = raw.trim();
        if raw.is_empty() {
            continue;
        }
        if raw.starts_with('<') {
            if fallback_cmd.is_empty() {
                fallback_cmd = command_label(raw);
            }
            continue;
        }
        let t: String = raw.split_whitespace().collect::<Vec<_>>().join(" ");
        if t.starts_with("[Request interrupted") || t.starts_with("Caveat:") {
            continue;
        }
        return t.chars().take(90).collect();
    }
    fallback_cmd.chars().take(90).collect()
}

/// __ccbud__ customization (custom title + tags + soft-delete flag) from any record carrying it.
pub(crate) fn read_ccbud(recs: &[Value]) -> (Option<String>, Vec<String>, bool) {
    let c = recs.iter().find_map(|r| r.get("__ccbud__"));
    let title = c
        .and_then(|c| c.get("title"))
        .and_then(|t| t.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let tags = c
        .and_then(|c| c.get("tagList"))
        .and_then(|t| t.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|t| t.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect()
        })
        .unwrap_or_default();
    let deleted = c.and_then(|c| c.get("delete")).and_then(|v| v.as_bool()).unwrap_or(false);
    (title, tags, deleted)
}

/// The foreign-CLI session sources routed by CONTAINER SHAPE (their path layouts are
/// distinctive per tool, and one of them isn't even jsonl) — content sniffing stays reserved
/// for the historical Claude-vs-Codex jsonl split.
#[derive(Clone, Copy, PartialEq)]
pub(crate) enum Foreign {
    Grok,
    Copilot,
    Antigravity,
}

pub(crate) fn foreign_kind(file: &Path) -> Option<Foreign> {
    if crate::grok::looks_grok_path(file) {
        return Some(Foreign::Grok);
    }
    if crate::copilot::looks_copilot_path(file) {
        return Some(Foreign::Copilot);
    }
    if crate::antigravity::looks_agy_path(file) {
        return Some(Foreign::Antigravity);
    }
    None
}

/// Cached soft-delete verdict for one file: a Claude session's flag (rides its first line, so it's
/// final for a given mtime), or "this belongs to another CLI" (Codex rollout / Qoder session /
/// foreign source, whose flag lives in a sidecar and can flip WITHOUT touching the file — so only
/// the format verdict is cached, never the flag).
#[derive(Clone, Copy)]
enum DelKind {
    Claude(bool),
    Codex,
    Qoder,
    Foreign(Foreign),
}

/// Process-lifetime memo of soft-delete status, keyed `path -> (mtime, kind)`. mtime is the
/// invalidation signal: set_ccbud rewrites a Claude file (bumping mtime) whenever the flag flips,
/// so a matching mtime means the cached answer is still valid. This lets dir_stats *stat*
/// unchanged sessions on each refresh instead of re-reading them.
fn deleted_cache() -> &'static std::sync::Mutex<std::collections::HashMap<PathBuf, (f64, DelKind)>> {
    static CACHE: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<PathBuf, (f64, DelKind)>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

/// Cheap soft-delete probe for counting, memoized by mtime. A Claude session's `__ccbud__.delete`
/// rides on the first parseable line, so a small head read suffices; a Codex rollout's flag is
/// re-read from the sidecar every time (itself mtime-cached and cheap).
fn is_session_deleted(file: &Path) -> bool {
    let mt = mtime_ms(file);
    let cached: Option<DelKind> = deleted_cache()
        .lock()
        .ok()
        .and_then(|c| c.get(file).filter(|(cmt, _)| *cmt == mt).map(|(_, k)| *k));
    let kind = cached.unwrap_or_else(|| {
        // Foreign sources are recognized by path shape alone — no read needed. Qoder is
        // Claude-FORMAT but another tool's file, so its flag lives in the sidecar too.
        let kind = if let Some(fk) = foreign_kind(file) {
            DelKind::Foreign(fk)
        } else if crate::qoder::looks_qoder_path(file) {
            DelKind::Qoder
        } else {
            // Read the same window session_meta uses: a Codex rollout's first (session_meta) line
            // embeds the full system prompt (~22 KB), so a smaller head truncates it, parse yields
            // nothing, and the session mis-sniffs as Claude — desyncing dir vs trash counts.
            let recs = parse_lines(&read_head(file, 131072));
            // Imported codex COPIES carry the flag in-file like Claude sessions (see set_ccbud) —
            // only live rollouts (no .import.json) use the sidecar.
            if crate::codex::looks_codex(&recs) && read_import_meta(&file.to_string_lossy()).is_none() {
                DelKind::Codex
            } else {
                DelKind::Claude(read_ccbud(&recs).2)
            }
        };
        if let Ok(mut cache) = deleted_cache().lock() {
            cache.insert(file.to_path_buf(), (mt, kind));
        }
        kind
    });
    match kind {
        DelKind::Claude(del) => del,
        DelKind::Codex => crate::codex::is_deleted(file),
        DelKind::Qoder => crate::qoder::is_deleted(file),
        DelKind::Foreign(Foreign::Grok) => crate::grok::is_deleted(file),
        DelKind::Foreign(Foreign::Copilot) => crate::copilot::is_deleted(file),
        DelKind::Foreign(Foreign::Antigravity) => crate::antigravity::is_deleted(file),
    }
}

fn line_to_message(rec: &Value) -> Option<Value> {
    let t = rec.get("type").and_then(|v| v.as_str())?;
    if t != "user" && t != "assistant" {
        return None;
    }
    let m = rec.get("message")?;
    let role = m.get("role").and_then(|v| v.as_str())?;
    let mut out = json!({
        "role": role,
        "content": m.get("content").cloned().unwrap_or(Value::Null),
        "_ts": rec.get("timestamp").cloned().unwrap_or(Value::Null),
        "_sidechain": rec.get("isSidechain").and_then(|v| v.as_bool()).unwrap_or(false),
        "_meta": rec.get("isMeta").and_then(|v| v.as_bool()).unwrap_or(false),
    });
    if t == "assistant" {
        let o = out.as_object_mut().unwrap();
        o.insert("_model".into(), m.get("model").cloned().unwrap_or(Value::Null));
        o.insert("_usage".into(), m.get("usage").map(usage_of).unwrap_or(Value::Null));
        o.insert("_stopReason".into(), m.get("stop_reason").cloned().unwrap_or(Value::Null));
    }
    Some(out)
}

struct Shaped {
    messages: Vec<Value>,
    totals: Value,
    model: Option<String>,
    first_ts: Option<String>,
    last_ts: Option<String>,
}

/// The renderer's normalized session shape shared by every non-Claude source (Codex, Grok,
/// Copilot, Antigravity): Anthropic-style messages (`role` + content blocks of
/// text/thinking/tool_use/tool_result) plus the session-level facts each format can recover.
pub struct Norm {
    pub messages: Vec<Value>,
    pub totals: Value,
    pub model: Option<String>,
    pub first_ts: Option<String>,
    pub last_ts: Option<String>,
    pub cwd: Option<String>,
    pub session_id: Option<String>,
    pub thread_id: Option<String>,
    pub parent_thread_id: Option<String>,
    pub forked_from_id: Option<String>,
    pub is_subagent: bool,
    pub agent_path: Option<String>,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    pub agent_depth: Option<i64>,
    pub git_branch: Option<String>,
    pub version: Option<String>,
}

impl Default for Norm {
    fn default() -> Self {
        Norm {
            messages: vec![],
            totals: json!({ "in": 0, "out": 0, "cacheRead": 0, "cacheCreation": 0, "turns": 0 }),
            model: None,
            first_ts: None,
            last_ts: None,
            cwd: None,
            session_id: None,
            thread_id: None,
            parent_thread_id: None,
            forked_from_id: None,
            is_subagent: false,
            agent_path: None,
            agent_nickname: None,
            agent_role: None,
            agent_depth: None,
            git_branch: None,
            version: None,
        }
    }
}

/// data-URL image → Claude-style image source block, else None.
pub(crate) fn image_block(url: &str) -> Option<Value> {
    let rest = url.strip_prefix("data:")?;
    let (mime, b64) = rest.split_once(";base64,")?;
    Some(json!({ "type": "image", "source": { "type": "base64", "media_type": mime, "data": b64 } }))
}

fn shape_messages(recs: &[Value]) -> Shaped {
    let mut messages = vec![];
    let (mut tin, mut tout, mut tcr, mut tcc, mut turns) = (0i64, 0i64, 0i64, 0i64, 0i64);
    let mut credits = 0.0f64;
    let mut has_credits = false;
    let mut model: Option<String> = None;
    let mut first_ts: Option<String> = None;
    let mut last_ts: Option<String> = None;
    for r in recs {
        let lm = match line_to_message(r) {
            Some(m) => m,
            None => continue,
        };
        if lm.get("_meta").and_then(|v| v.as_bool()).unwrap_or(false) {
            continue;
        }
        let ts = lm.get("_ts").and_then(|v| v.as_str()).map(|s| s.to_string());
        if let Some(t) = &ts {
            if first_ts.is_none() {
                first_ts = Some(t.clone());
            }
            last_ts = Some(t.clone());
        }
        let mut msg = json!({ "role": lm.get("role").cloned().unwrap_or(Value::Null), "content": lm.get("content").cloned().unwrap_or(Value::Null) });
        let mo = msg.as_object_mut().unwrap();
        if lm.get("_sidechain").and_then(|v| v.as_bool()).unwrap_or(false) {
            mo.insert("isSidechain".into(), json!(true));
        }
        if let Some(t) = &ts {
            mo.insert("ts".into(), json!(t));
        }
        if r.get("type").and_then(|v| v.as_str()) == Some("assistant") {
            if let Some(md) = lm.get("_model").and_then(|v| v.as_str()) {
                mo.insert("modelActual".into(), json!(md));
                model = Some(md.to_string());
            }
            let u = lm.get("_usage").cloned().unwrap_or(Value::Null);
            if u.is_object() {
                mo.insert("usage".into(), u.clone());
                tin += u.get("inputTokens").and_then(|v| v.as_i64()).unwrap_or(0);
                tout += u.get("outputTokens").and_then(|v| v.as_i64()).unwrap_or(0);
                tcr += u.get("cacheRead").and_then(|v| v.as_i64()).unwrap_or(0);
                tcc += u.get("cacheCreation").and_then(|v| v.as_i64()).unwrap_or(0);
                if let Some(value) = u.get("credits").and_then(|v| v.as_f64()) {
                    credits += value;
                    has_credits = true;
                }
                turns += 1;
            }
            if let Some(sr) = lm.get("_stopReason").and_then(|v| v.as_str()) {
                mo.insert("stopReason".into(), json!(sr));
            }
        }
        messages.push(msg);
    }
    let mut totals = json!({ "in": tin, "out": tout, "cacheRead": tcr, "cacheCreation": tcc, "turns": turns });
    if has_credits {
        let totals = totals.as_object_mut().unwrap();
        totals.insert("credits".into(), json!(credits));
        // Qoder's source log may omit usable token accounting while still providing real credits.
        // Flag that state so the UI does not misrepresent unavailable token counts as zero usage.
        if tin == 0 && tout == 0 && tcr == 0 && tcc == 0 {
            totals.insert("tokenUsageAvailable".into(), json!(false));
        }
    }
    Shaped {
        messages,
        totals,
        model,
        first_ts,
        last_ts,
    }
}

fn mtime_ms(file: &Path) -> f64 {
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

fn imports_root() -> PathBuf {
    crate::store::ccbud_home().join("imports")
}
/// Configured dirs + the synthetic imported-transcripts store (id `__imported__`).
fn all_dirs(config: &Value) -> Vec<(String, String, PathBuf)> {
    let mut dirs = config_dirs(config);
    dirs.push(("__imported__".to_string(), "导入".to_string(), imports_root().join("projects")));
    dirs
}
/// A sibling data tree next to a dir entry's `projects/`. Every configured dir is probed for
/// EVERY layout (Claude Code AND Qoder write `<dir>/projects/…`, Codex and Grok
/// `<dir>/sessions/…`, Copilot `<dir>/session-state/…`, Antigravity `<dir>/conversations/*.db`),
/// so `~/.codex`, `~/.grok`, `~/.copilot`, `~/.gemini/antigravity-cli`, `~/.qoder` are just
/// configured dirs rather than special cases.
fn sibling_dir(projects_dir: &Path, name: &str) -> Option<PathBuf> {
    projects_dir.parent().map(|b| b.join(name))
}

fn sessions_dir(projects_dir: &Path) -> Option<PathBuf> {
    sibling_dir(projects_dir, "sessions")
}

/// Dirs to watch for live history changes — each work dir's data trees (all four layouts).
pub fn watch_roots(config: &Value) -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = vec![];
    for (_, _, pd) in all_dirs(config) {
        for name in ["sessions", "session-state", "conversations"] {
            if let Some(sd) = sibling_dir(&pd, name) {
                roots.push(sd);
            }
        }
        roots.push(pd);
    }
    roots
}

/// Walk every session .jsonl across the configured dirs (+ imports), invoking
/// `cb(file, dir_name, dir_id, dir_label)` — both the Claude projects/ tree and the
/// Codex sessions/ tree of each dir.
fn each_session_file<F: FnMut(PathBuf, String, &str, &str)>(config: &Value, mut cb: F) {
    for (id, label, root) in all_dirs(config) {
        if let Ok(entries) = fs::read_dir(&root) {
            for ent in entries.flatten() {
                if !ent.path().is_dir() {
                    continue;
                }
                let dir_name = ent.file_name().to_string_lossy().into_owned();
                let pfiles = match fs::read_dir(ent.path()) {
                    Ok(f) => f,
                    Err(_) => continue,
                };
                for f in pfiles.flatten() {
                    let p = f.path();
                    if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                        cb(p, dir_name.clone(), &id, &label);
                    }
                }
            }
        }
        // Codex rollouts live in a date-sharded sessions/ tree; Grok shares the same sessions/
        // root but keys children by percent-encoded cwd (and stuffs sidecar jsonl — events/
        // updates/rewind — beside each chat_history.jsonl), so children are routed one by one
        // rather than letting the codex walker sweep grok trees into garbage rows.
        if let Some(sd) = sessions_dir(&root) {
            if let Ok(children) = fs::read_dir(&sd) {
                for ent in children.flatten() {
                    let p = ent.path();
                    let name = ent.file_name().to_string_lossy().into_owned();
                    if p.is_dir() && crate::grok::is_cwd_dir_name(&name) {
                        crate::grok::walk_cwd_dir(&p, &mut |f| cb(f, String::new(), &id, &label));
                    } else if p.is_dir() {
                        crate::codex::walk_sessions(&p, |f| cb(f, String::new(), &id, &label));
                    } else if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                        cb(p, String::new(), &id, &label);
                    }
                }
            }
        }
        // Copilot session logs (flat <uuid>.jsonl + <uuid>/events.jsonl).
        if let Some(ss) = sibling_dir(&root, "session-state") {
            crate::copilot::walk(&ss, &mut |f| cb(f, String::new(), &id, &label));
        }
        // Antigravity conversations (one SQLite per session).
        if let Some(cd) = sibling_dir(&root, "conversations") {
            crate::antigravity::walk(&cd, &mut |f| cb(f, String::new(), &id, &label));
        }
    }
}

/// Mtime+size-keyed memo of session_meta list rows (mirrors the JS metaCache). List refreshes
/// fire on every watched write during a live session and previously re-read every candidate's
/// file head each time — with the memo, unchanged sessions cost a stat. Pruned in list_sessions
/// against the live file set; a live Codex rollout's sidecar edit (which does NOT touch the
/// file) is invalidated explicitly by set_ccbud.
fn meta_cache() -> &'static std::sync::Mutex<std::collections::HashMap<PathBuf, (f64, u64, Value)>> {
    static CACHE: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<PathBuf, (f64, u64, Value)>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

/// Freshness stamp for the list-meta / search caches: plain mtime, except Antigravity DBs
/// where a live agy writes into the WAL without touching the main file.
fn cache_stamp_ms(file: &Path) -> f64 {
    match foreign_kind(file) {
        Some(Foreign::Antigravity) => crate::antigravity::wal_mtime_ms(file),
        _ => mtime_ms(file),
    }
}

fn session_meta(file: &Path, dir_name: &str, dir_id: &str, dir_label: &str) -> Option<Value> {
    let (mt, size) = (cache_stamp_ms(file), fs::metadata(file).ok()?.len());
    if let Ok(cache) = meta_cache().lock() {
        if let Some((cmt, csz, v)) = cache.get(file) {
            if *cmt == mt && *csz == size {
                return Some(v.clone());
            }
        }
    }
    let built = build_session_meta(file, dir_name, dir_id, dir_label)?;
    // A permission failure is recoverable without changing the transcript's mtime/size (for
    // example after the user grants macOS App Data access) — never memoize that placeholder row,
    // otherwise it would stay "(conversation)" until the process restarts. Every OTHER read
    // error is memoized like a normal row: the mtime/size key already invalidates it when the
    // file changes, and skipping the memo would re-read a broken transcript on every refresh.
    let awaiting_grant = built
        .get("readError")
        .and_then(|e| e.get("kind"))
        .and_then(|k| k.as_str())
        == Some("permissionDenied");
    if !awaiting_grant {
        if let Ok(mut cache) = meta_cache().lock() {
            cache.insert(file.to_path_buf(), (mt, size, built.clone()));
        }
    }
    Some(built)
}

fn build_session_meta(file: &Path, dir_name: &str, dir_id: &str, dir_label: &str) -> Option<Value> {
    // Foreign sources first — routed by container shape BEFORE any content read (one of them
    // isn't even text), each through its own shaper.
    match foreign_kind(file) {
        Some(Foreign::Grok) => return crate::grok::session_meta_from(file, dir_id, dir_label),
        Some(Foreign::Copilot) => {
            let recs = parse_lines(&read_head(file, 131072));
            return crate::copilot::session_meta_from(file, &recs, dir_id, dir_label);
        }
        Some(Foreign::Antigravity) => return crate::antigravity::session_meta_from(file, dir_id, dir_label),
        None => {}
    }
    let meta = fs::metadata(file).ok()?;
    let size = meta.len();
    let qoder = crate::qoder::looks_qoder_path(file);
    // Qoder stores title/workspace/runtime records throughout the transcript, and its first JSON
    // line can itself exceed the ordinary 128 KiB list window. Read the full file once (the row
    // cache makes this a one-time cost per mtime/size); other formats retain the bounded head.
    let raw = if qoder {
        crate::qoder::read_text(file)
    } else {
        read_head_result(file, 131072)
    };
    let (parsed_recs, read_error) = match raw {
        Ok(raw) => (parse_lines(&raw), Value::Null),
        Err(error) => (
            vec![],
            session_read_error(file, &error)
                .get("error")
                .cloned()
                .unwrap_or(Value::Null),
        ),
    };
    let qoder_title = if qoder {
        crate::qoder::session_title_from(&parsed_recs)
    } else {
        None
    };
    let qoder_cwd = if qoder {
        crate::qoder::working_dir_from(&parsed_recs)
    } else {
        None
    };
    let qoder_model = if qoder {
        crate::qoder::model_from(&parsed_recs)
    } else {
        None
    };
    let recs = if qoder {
        crate::qoder::normalize_records(&parsed_recs)
    } else {
        parsed_recs
    };
    // Codex rollouts (a dir's sessions/ tree, or snapshots imported into the app store) list
    // through the codex shaper — the record format shares nothing with Claude's.
    if crate::codex::looks_codex(&recs) {
        return crate::codex::session_meta_from(file, &recs, dir_id, dir_label);
    }
    // Qoder sessions use Claude-like user/assistant envelopes plus inline title/workspace/runtime
    // records and atomic assistant content wrappers. normalize_records makes the message stream
    // Claude-shaped; Qoder-specific metadata remains app-sidecar + inline JSONL data.
    let meta_rec = recs
        .iter()
        .find(|r| r.get("cwd").is_some())
        .or_else(|| recs.iter().find(|r| r.get("sessionId").is_some()));
    let agent_rec = recs.iter().find(|r| r.get("agentId").is_some());
    let msgs: Vec<Value> = recs.iter().filter_map(line_to_message).collect();
    let (cc_title, cc_tags, cc_deleted) =
        if qoder { crate::qoder::sidecar_meta(file) } else { read_ccbud(&recs) };
    let auto_title = qoder_title.unwrap_or_else(|| first_user_text(&msgs));
    let mut model: Option<String> = None;
    for r in &recs {
        if r.get("type").and_then(|v| v.as_str()) == Some("assistant") {
            if let Some(md) = r.get("message").and_then(|m| m.get("model")).and_then(|v| v.as_str()) {
                model = Some(md.to_string());
            }
        }
    }
    if qoder_model.is_some() {
        model = qoder_model;
    }
    let subagent = agent_rec.is_some();
    let top_level_cwd = meta_rec
        .and_then(|r| r.get("cwd"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let cwd = (if qoder {
        qoder_cwd.or(top_level_cwd)
    } else {
        top_level_cwd
    })
    .or_else(|| decode_dir_name(dir_name));
    let stem = file.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
    let mt = mtime_ms(file);
    Some(json!({
        "id": if qoder { format!("qoder:{}", stem) } else { format!("disk:{}{}", stem, if subagent { ":sub" } else { "" }) },
        "file": file.to_string_lossy(),
        "source": if qoder { "qoder" } else { "disk" },
        "dirId": dir_id,
        "dirLabel": dir_label,
        "sessionId": meta_rec.and_then(|r| r.get("sessionId")).and_then(|v| v.as_str()).unwrap_or(&stem),
        "cwd": cwd.clone(),
        "project": cwd.as_deref().map(base_name).unwrap_or_default(),
        "gitBranch": meta_rec.and_then(|r| r.get("gitBranch")).cloned().unwrap_or(Value::Null),
        "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
        "autoTitle": auto_title,
        "tags": cc_tags,
        "model": model,
        "isSubagent": subagent,
        "imported": dir_id == "__imported__",
        "deleted": cc_deleted,
        "readError": read_error,
        "createdAt": record_created_ms(&recs, file),
        "lastActivity": mt,
        "sizeKB": (size as f64 / 1024.0).round() as i64,
    }))
}

fn canonical_codex_key(session: &Value) -> Option<String> {
    if session.get("source").and_then(Value::as_str) != Some("codex") {
        return None;
    }
    if session.get("canonicalThreadIdValid").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let thread_id = session.get("threadId").and_then(Value::as_str)?;
    let dir_id = session.get("dirId").and_then(Value::as_str).unwrap_or("");
    Some(format!("{dir_id}\0{thread_id}"))
}

fn codex_canonical_filename(session: &Value) -> bool {
    let Some(thread_id) = session.get("threadId").and_then(Value::as_str) else {
        return false;
    };
    let Some(file) = session.get("file").and_then(Value::as_str) else {
        return false;
    };
    let stem = Path::new(file).file_stem().and_then(|value| value.to_str()).unwrap_or("");
    stem == thread_id || stem.strip_suffix(thread_id).is_some_and(|prefix| prefix.ends_with('-'))
}

fn codex_candidate_preferred(candidate: &Value, current: &Value) -> bool {
    let candidate_file = candidate.get("file").and_then(Value::as_str).unwrap_or("");
    let current_file = current.get("file").and_then(Value::as_str).unwrap_or("");
    let thread_id = candidate
        .get("threadId")
        .and_then(Value::as_str)
        .or_else(|| current.get("threadId").and_then(Value::as_str))
        .unwrap_or("");

    // Codex's completed state DB is authoritative when its rollout_path still exists. Both
    // candidates already passed ccbud's first-SessionMeta parse, so a matching path also verifies
    // that the DB row belongs to this canonical id.
    let preferred_path = [candidate_file, current_file]
        .into_iter()
        .filter(|file| !file.is_empty())
        .find_map(|file| crate::codex::preferred_rollout_path(Path::new(file), thread_id));
    if let Some(preferred) = preferred_path {
        let candidate_matches = Path::new(candidate_file) == preferred.as_path();
        let current_matches = Path::new(current_file) == preferred.as_path();
        if candidate_matches != current_matches {
            return candidate_matches;
        }
    }

    let imported = |value: &Value| value.get("imported").and_then(Value::as_bool).unwrap_or(false);
    if imported(candidate) != imported(current) {
        return !imported(candidate);
    }
    let archived = |file: &str| {
        Path::new(file)
            .components()
            .any(|part| part.as_os_str().to_str() == Some("archived_sessions"))
    };
    if archived(candidate_file) != archived(current_file) {
        return !archived(candidate_file);
    }
    let number = |value: &Value, field: &str| value.get(field).and_then(Value::as_f64).unwrap_or(0.0);
    for field in ["lastActivity", "createdAt"] {
        let candidate_value = number(candidate, field);
        let current_value = number(current, field);
        if candidate_value != current_value {
            return candidate_value > current_value;
        }
    }
    if codex_canonical_filename(candidate) != codex_canonical_filename(current) {
        return codex_canonical_filename(candidate);
    }
    let candidate_size = number(candidate, "sizeKB");
    let current_size = number(current, "sizeKB");
    if candidate_size != current_size {
        return candidate_size > current_size;
    }
    candidate_file > current_file
}

fn dedupe_canonical_codex_sessions(sessions: Vec<Value>) -> Vec<Value> {
    let mut out = Vec::with_capacity(sessions.len());
    let mut positions = std::collections::HashMap::<String, usize>::new();
    for session in sessions {
        let Some(key) = canonical_codex_key(&session) else {
            out.push(session);
            continue;
        };
        if let Some(index) = positions.get(&key).copied() {
            if codex_candidate_preferred(&session, &out[index]) {
                out[index] = session;
            }
        } else {
            positions.insert(key, out.len());
            out.push(session);
        }
    }
    out
}

fn limit_with_codex_ancestors(sessions: Vec<Value>, limit: usize) -> Vec<Value> {
    if sessions.len() <= limit {
        return sessions;
    }
    let mut positions = std::collections::HashMap::<String, usize>::new();
    for (index, session) in sessions.iter().enumerate() {
        if let Some(key) = canonical_codex_key(session) {
            positions.insert(key, index);
        }
    }
    let mut included: std::collections::HashSet<usize> = (0..limit).collect();
    let mut queue: Vec<usize> = (0..limit).collect();
    let mut cursor = 0usize;
    while cursor < queue.len() {
        let index = queue[cursor];
        cursor += 1;
        let session = &sessions[index];
        if canonical_codex_key(session).is_none() {
            continue;
        }
        let dir_id = session.get("dirId").and_then(Value::as_str).unwrap_or("");
        let direct_parent = session.get("parentThreadId").and_then(Value::as_str);
        let root_parent = session
            .get("isSubagent")
            .and_then(Value::as_bool)
            .unwrap_or(false)
            .then(|| session.get("rootSessionId").and_then(Value::as_str))
            .flatten();
        let parent_index = [direct_parent, root_parent]
            .into_iter()
            .flatten()
            .find_map(|parent_id| positions.get(&format!("{dir_id}\0{parent_id}")).copied());
        let Some(parent_index) = parent_index else {
            continue;
        };
        if included.insert(parent_index) {
            queue.push(parent_index);
        }
    }
    sessions
        .into_iter()
        .enumerate()
        .filter_map(|(index, session)| included.contains(&index).then_some(session))
        .collect()
}

pub fn list_sessions(config: &Value, active: &str, limit: usize) -> Vec<Value> {
    // The recycle bin spans every dir and shows only soft-deleted sessions; every other view
    // is scoped to its dir and hides them.
    let trash = active == TRASH_ID;
    // Read (memoized) metas for EVERY candidate, then dedupe/order before the limit cut. Most
    // formats use content-derived CreatedAt so title/tag rewrites cannot reshuffle rows; Codex
    // uses rollout UpdatedAt because its custom metadata is sidecar-only and Codex defines latest
    // that way. The meta cache turns the full walk into stats for unchanged files.
    let mut live: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
    let mut candidates: Vec<(PathBuf, String, String, String)> = Vec::new();
    each_session_file(config, |file, dir_name, id, label| {
        live.insert(file.clone());
        if !trash && active != "all" && id != active {
            return;
        }
        candidates.push((file, dir_name, id.to_string(), label.to_string()));
    });
    // Warm the qoder helper cache in ONE batch before the per-row reads — on a macOS install with
    // protected app data, every stale row would otherwise spawn its own helper process.
    let qoder_files: Vec<PathBuf> = candidates
        .iter()
        .map(|(file, _, _, _)| file.clone())
        .filter(|file| crate::qoder::looks_qoder_path(file))
        .collect();
    crate::qoder::prefetch(&qoder_files);
    let mut out: Vec<Value> = Vec::new();
    for (file, dir_name, id, label) in &candidates {
        if let Some(m) = session_meta(file, dir_name, id, label) {
            out.push(m);
        }
    }
    // Drop memo entries for files that no longer exist, so removed dirs don't pin stale rows.
    if let Ok(mut cache) = meta_cache().lock() {
        cache.retain(|k, _| live.contains(k));
    }
    // Collapse only true physical duplicates (same dir + canonical thread id) BEFORE limit.
    // Threads that merely share rootSessionId are distinct root/subagent nodes and remain intact.
    let mut out = dedupe_canonical_codex_sessions(out);
    // Apply recycle-bin visibility to the selected logical representative, not to each physical
    // candidate. Otherwise deleting the authoritative copy could make a stale duplicate reappear
    // in the normal list while the same logical thread also sits in the recycle bin.
    out.retain(|session| {
        session.get("deleted").and_then(Value::as_bool).unwrap_or(false) == trash
    });
    let key = |v: &Value| {
        // Codex defines "latest" as UpdatedAt (rollout mtime); its title/tags live in a sidecar,
        // so this timestamp is not dirtied by ccbud edits. Keep the stable CreatedAt policy for
        // formats whose transcript itself is rewritten when metadata changes.
        let field = if v.get("source").and_then(Value::as_str) == Some("codex") {
            "lastActivity"
        } else {
            "createdAt"
        };
        v.get(field).and_then(Value::as_f64).unwrap_or(0.0)
    };
    out.sort_by(|a, b| {
        key(b)
            .partial_cmp(&key(a))
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                let updated = |value: &Value| {
                    value.get("lastActivity").and_then(Value::as_f64).unwrap_or(0.0)
                };
                updated(b)
                    .partial_cmp(&updated(a))
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| {
                let a_id = a
                    .get("threadId")
                    .or_else(|| a.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let b_id = b
                    .get("threadId")
                    .or_else(|| b.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                b_id.cmp(a_id)
            })
    });
    // Soft-cap Codex trees: include the parent/root chain of every selected child so a busy tree
    // cannot show orphan subagents merely because its older root fell just below the limit.
    limit_with_codex_ancestors(out, limit)
}

pub fn list_projects(config: &Value, active: &str) -> Vec<Value> {
    let sessions = list_sessions(config, active, 600);
    let mut order: Vec<String> = vec![];
    let mut groups: std::collections::HashMap<String, Value> = std::collections::HashMap::new();
    for s in sessions {
        let cwd = s.get("cwd").and_then(|v| v.as_str()).unwrap_or("(unknown)").to_string();
        let la = s.get("lastActivity").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let ct = s.get("createdAt").and_then(|v| v.as_f64()).unwrap_or(la);
        let sk = if s.get("source").and_then(Value::as_str) == Some("codex") { la } else { ct };
        let g = groups.entry(cwd.clone()).or_insert_with(|| {
            order.push(cwd.clone());
            json!({ "cwd": s.get("cwd").cloned().unwrap_or(Value::Null), "name": s.get("project").cloned().unwrap_or(Value::Null), "sessions": [], "lastActivity": 0.0, "createdAt": 0.0, "sortActivity": 0.0 })
        });
        g["sessions"].as_array_mut().unwrap().push(s.clone());
        if la > g["lastActivity"].as_f64().unwrap_or(0.0) {
            g["lastActivity"] = json!(la);
        }
        if ct > g["createdAt"].as_f64().unwrap_or(0.0) {
            g["createdAt"] = json!(ct);
        }
        if sk > g["sortActivity"].as_f64().unwrap_or(0.0) {
            g["sortActivity"] = json!(sk);
        }
    }
    // Codex's latest semantic is rollout UpdatedAt; other formats retain CreatedAt so in-file
    // title/tag edits cannot reorder them. Apply the same source-aware rule to rows and projects.
    let sort_key = |v: &Value| {
        let field = if v.get("source").and_then(Value::as_str) == Some("codex") {
            "lastActivity"
        } else {
            "createdAt"
        };
        v.get(field).and_then(Value::as_f64).unwrap_or(0.0)
    };
    let mut arr: Vec<Value> = order.into_iter().filter_map(|k| groups.remove(&k)).collect();
    for g in &mut arr {
        g["sessions"].as_array_mut().unwrap().sort_by(|a, b| {
            sort_key(b).partial_cmp(&sort_key(a)).unwrap_or(std::cmp::Ordering::Equal)
        });
    }
    arr.sort_by(|a, b| {
        let key = |value: &Value| {
            value.get("sortActivity").and_then(Value::as_f64).unwrap_or(0.0)
        };
        key(b).partial_cmp(&key(a)).unwrap_or(std::cmp::Ordering::Equal)
    });
    for group in &mut arr {
        if let Some(object) = group.as_object_mut() {
            object.remove("sortActivity");
        }
    }
    arr
}

pub fn dir_stats(config: &Value) -> Vec<Value> {
    // Per-dir counts exclude soft-deleted sessions (they're hidden from those views); the deleted
    // ones are tallied separately into the synthetic recycle-bin bucket. Reuse list_sessions so
    // counts reflect canonical logical rows rather than duplicate physical rollout files.
    let mut counts: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
    for session in list_sessions(config, "all", usize::MAX) {
        let id = session.get("dirId").and_then(Value::as_str).unwrap_or("");
        *counts.entry(id.to_string()).or_insert(0) += 1;
    }
    let trash = list_sessions(config, TRASH_ID, usize::MAX).len() as i64;
    let mut out: Vec<Value> = all_dirs(config)
        .into_iter()
        .map(|(id, label, pd)| {
            // A dir "exists" when ANY data tree is on disk — ~/.codex has only sessions/,
            // ~/.copilot only session-state/, ~/.gemini/antigravity-cli only conversations/.
            let exists = pd.is_dir()
                || ["sessions", "session-state", "conversations"]
                    .iter()
                    .any(|n| sibling_dir(&pd, n).map(|s| s.is_dir()).unwrap_or(false));
            let imported = id == "__imported__";
            json!({
                "id": id.clone(), "label": label, "projectsDir": pd.to_string_lossy(),
                "sessions": counts.get(&id).copied().unwrap_or(0), "exists": exists, "imported": imported,
            })
        })
        .collect();
    out.push(json!({
        "id": TRASH_ID, "label": "回收站", "projectsDir": "",
        "sessions": trash, "exists": true, "imported": false, "trash": true,
    }));
    out
}

/// A skill-forked subagent transcript opens with a sentinel user line
/// "Base directory for this skill: <path>/<skill-dir>" — the last path segment names the skill.
/// Fallback attribution only: the spawning `Skill` tool_use in the parent thread
/// (apply_skill_names) is authoritative and overrides this when present. (history.js skillFromRecs)
const SKILL_BASE_DIR_PREFIX: &str = "Base directory for this skill: ";
pub(crate) fn skill_from_recs(recs: &[Value]) -> Option<String> {
    let first = recs.iter().find(|r| {
        r.get("type").and_then(|v| v.as_str()) == Some("user")
            && r.get("message").is_some()
            && !r.get("isMeta").and_then(|v| v.as_bool()).unwrap_or(false)
    })?;
    let text = content_text(first.get("message")?.get("content").unwrap_or(&Value::Null));
    // Only the opening prompt carries the sentinel — don't scan further user turns.
    let rest = text.trim().strip_prefix(SKILL_BASE_DIR_PREFIX)?;
    let line = rest.lines().next().unwrap_or("").trim();
    line.split(['/', '\\']).filter(|s| !s.is_empty()).last().map(|s| s.to_string())
}

/// Primary skill attribution (history.js applySkillNames): a subagent spawned by the `Skill` tool
/// is named by the spawning tool_use's input.skill (matched by tool_use id — the subagents map
/// key), in whichever thread the call lives (main or a nested subagent). Overrides the sentinel
/// fallback from skill_from_recs.
pub(crate) fn apply_skill_names(main_messages: &[Value], subs: &mut serde_json::Map<String, Value>) {
    if subs.is_empty() {
        return;
    }
    fn scan(msgs: &[Value], subs: &serde_json::Map<String, Value>, out: &mut Vec<(String, String)>) {
        for m in msgs {
            let blocks = match m.get("content").and_then(|c| c.as_array()) {
                Some(b) => b,
                None => continue,
            };
            for b in blocks {
                if b.get("type").and_then(|v| v.as_str()) != Some("tool_use")
                    || b.get("name").and_then(|v| v.as_str()) != Some("Skill")
                {
                    continue;
                }
                let id = match b.get("id").and_then(|v| v.as_str()) {
                    Some(i) if subs.contains_key(i) => i,
                    _ => continue,
                };
                if let Some(s) = b.get("input").and_then(|i| i.get("skill")).and_then(|v| v.as_str()) {
                    let s = s.trim();
                    if !s.is_empty() {
                        out.push((id.to_string(), s.to_string()));
                    }
                }
            }
        }
    }
    let mut named: Vec<(String, String)> = vec![];
    scan(main_messages, subs, &mut named);
    for (_, v) in subs.iter() {
        if let Some(msgs) = v.get("messages").and_then(|m| m.as_array()) {
            scan(msgs, subs, &mut named);
        }
    }
    for (id, name) in named {
        if let Some(o) = subs.get_mut(&id).and_then(|s| s.as_object_mut()) {
            o.insert("skill".into(), json!(name));
        }
    }
}

/// Read a session's child subagent dialogues from `<stem>/subagents/agent-*.jsonl` (+ .meta.json),
/// keyed by the spawning tool_use id so the renderer can nest them. {} when none. (history.js readSubagents)
fn read_subagents(file: &str) -> serde_json::Map<String, Value> {
    let p = Path::new(file);
    let qoder = crate::qoder::looks_qoder_path(p);
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let dir = match p.parent() {
        Some(d) => d.join(stem).join("subagents"),
        None => return serde_json::Map::new(),
    };
    let mut by_tool = serde_json::Map::new();
    let entries = match fs::read_dir(&dir) {
        Ok(e) => e,
        Err(_) => return by_tool,
    };
    let mut agent_files: Vec<(String, PathBuf)> = vec![];
    for ent in entries.flatten() {
        let name = ent.file_name().to_string_lossy().to_string();
        if name.starts_with("agent-") && name.ends_with(".jsonl") {
            agent_files.push((name, ent.path()));
        }
    }
    // A protected qoder session's subagent transcripts + meta sidecars warm in one helper batch
    // instead of two spawns per agent.
    if qoder {
        let mut warm: Vec<PathBuf> = vec![];
        for (name, path) in &agent_files {
            warm.push(path.clone());
            let agent_id = name.trim_start_matches("agent-").trim_end_matches(".jsonl");
            warm.push(dir.join(format!("agent-{}.meta.json", agent_id)));
        }
        crate::qoder::prefetch(&warm);
    }
    for (name, transcript_path) in agent_files {
        let agent_id = name
            .trim_start_matches("agent-")
            .trim_end_matches(".jsonl")
            .to_string();
        let meta_path = dir.join(format!("agent-{}.meta.json", agent_id));
        let meta_raw = if qoder {
            crate::qoder::read_text(&meta_path)
        } else {
            fs::read_to_string(&meta_path)
        };
        let meta: Value = meta_raw
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_else(|| json!({}));
        let raw = match read_session_text(&transcript_path) {
            Ok(s) => s,
            Err(_) => continue,
        };
        let parsed = parse_lines(&raw);
        let recs = if qoder {
            crate::qoder::normalize_records(&parsed)
        } else {
            parsed
        };
        let shaped = shape_messages(&recs);
        let key = meta
            .get("toolUseId")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| format!("agent:{}", agent_id));
        let agent_type = meta
            .get("agentType")
            .and_then(|v| v.as_str())
            .or_else(|| meta.get("subagent_type").and_then(|v| v.as_str()))
            .unwrap_or("agent");
        by_tool.insert(
            key,
            json!({
                "agentId": agent_id,
                "file": transcript_path.to_string_lossy(),
                "type": agent_type,
                "description": meta.get("description").and_then(|v| v.as_str()).unwrap_or(""),
                "skill": skill_from_recs(&recs),
                "count": shaped.messages.len(),
                "totals": shaped.totals,
                "messages": shaped.messages,
            }),
        );
    }
    by_tool
}

/// A session's subagents directory: `<dir>/<stem>/subagents`. None when the path has no stem.
fn subagent_dir(file: &Path) -> Option<PathBuf> {
    let stem = file.file_stem().and_then(|s| s.to_str())?;
    file.parent().map(|d| d.join(stem).join("subagents"))
}

/// The raw subagent sidecar files for a session — `(agent-*.jsonl | agent-*.meta.json, bytes)`.
/// Empty when the session spawned no subagents. Shared by bundle export, import, and replay-merge.
fn read_subagent_files(file: &Path) -> Vec<(String, Vec<u8>)> {
    let dir = match subagent_dir(file) {
        Some(d) => d,
        None => return vec![],
    };
    let qoder = crate::qoder::looks_qoder_path(file);
    let mut out = vec![];
    if let Ok(entries) = fs::read_dir(&dir) {
        for ent in entries.flatten() {
            let p = ent.path();
            if !p.is_file() {
                continue;
            }
            let name = ent.file_name().to_string_lossy().into_owned();
            let lower = name.to_lowercase();
            if lower.starts_with("agent-") && (lower.ends_with(".jsonl") || lower.ends_with(".meta.json")) {
                let bytes = if qoder {
                    crate::qoder::read_bytes(&p)
                } else {
                    fs::read(&p)
                };
                if let Ok(bytes) = bytes {
                    out.push((name, bytes));
                }
            }
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0)); // deterministic bundle order
    out
}

/// Whether a session has any subagent transcripts (drives export → .zip vs plain .jsonl).
pub fn session_has_subagents(file: &str) -> bool {
    !read_subagent_files(Path::new(file)).is_empty()
}

/// Build a conversation-bundle ZIP: the main session `<basename>.jsonl` at the top level and each
/// subagent file under `subagents/`. Caller uses this only when the session actually has subagents
/// (a plain .jsonl export otherwise). Round-trips through import_zip / splitBundle.
pub fn export_bundle(file: &str) -> std::io::Result<Vec<u8>> {
    let path = Path::new(file);
    let main = read_session_bytes(path)?;
    let main_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("conversation.jsonl")
        .to_string();
    let mut entries = vec![crate::ziputil::Entry { name: main_name, data: main }];
    for (name, bytes) in read_subagent_files(path) {
        entries.push(crate::ziputil::Entry { name: format!("subagents/{}", name), data: bytes });
    }
    Ok(crate::ziputil::build(&entries))
}

/// Absolute paths of a session's subagent transcripts (`<stem>/subagents/agent-*.jsonl`), sorted.
/// Empty when the session has no subagents. Powers "Claude 分析": every subagent transcript is
/// attached alongside the main session in the Cowork deep link (which takes a repeated `file=` param),
/// so the analysis covers subagent runs — not just the main thread.
pub fn subagent_transcript_paths(file: &str) -> Vec<String> {
    let dir = match subagent_dir(Path::new(file)) {
        Some(d) => d,
        None => return vec![],
    };
    let mut out = vec![];
    if let Ok(entries) = fs::read_dir(&dir) {
        for ent in entries.flatten() {
            let p = ent.path();
            if !p.is_file() {
                continue;
            }
            let name = ent.file_name().to_string_lossy().to_lowercase();
            if name.starts_with("agent-") && name.ends_with(".jsonl") {
                out.push(p.to_string_lossy().into_owned());
            }
        }
    }
    out.sort();
    out
}

/// Read the import provenance sidecar (`<stem>.import.json`) for an imported transcript.
pub(crate) fn read_import_meta(file: &str) -> Option<Value> {
    let p = Path::new(file);
    let stem = p.file_stem().and_then(|s| s.to_str())?;
    let dir = p.parent()?;
    let raw = fs::read_to_string(dir.join(format!("{}.import.json", stem))).ok()?;
    serde_json::from_str(&raw).ok()
}

pub fn get_session(file: &str) -> Value {
    let path = Path::new(file);
    let qoder = crate::qoder::looks_qoder_path(path);
    // Foreign sources route by container shape BEFORE the text read — Antigravity sessions are
    // SQLite, and grok/copilot jsonl would otherwise fall through to the Claude shaper.
    match foreign_kind(path) {
        Some(Foreign::Antigravity) => return crate::antigravity::session_from(file),
        Some(fk) => {
            let raw = match read_session_text(path) {
                Ok(s) => s,
                Err(error) => return session_read_error(path, &error),
            };
            let recs = parse_lines(&raw);
            return match fk {
                Foreign::Grok => crate::grok::session_from_recs(file, &recs),
                _ => crate::copilot::session_from_recs(file, &recs),
            };
        }
        None => {}
    }
    let raw = match read_session_text(path) {
        Ok(s) => s,
        Err(error) => return session_read_error(path, &error),
    };
    let parsed_recs = parse_lines(&raw);
    if crate::codex::looks_codex(&parsed_recs) {
        return crate::codex::session_from_recs(file, &parsed_recs);
    }
    let qoder_title = if qoder {
        crate::qoder::session_title_from(&parsed_recs)
    } else {
        None
    };
    let qoder_cwd = if qoder {
        crate::qoder::working_dir_from(&parsed_recs)
    } else {
        None
    };
    let qoder_model = if qoder {
        crate::qoder::model_from(&parsed_recs)
    } else {
        None
    };
    let recs = if qoder {
        crate::qoder::normalize_records(&parsed_recs)
    } else {
        parsed_recs
    };
    let meta_rec = recs
        .iter()
        .find(|r| r.get("cwd").is_some())
        .or_else(|| recs.iter().find(|r| r.get("sessionId").is_some()));
    let agent_rec = recs.iter().find(|r| r.get("agentId").is_some());
    let agent_id = agent_rec
        .and_then(|r| r.get("agentId"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let summary = recs
        .iter()
        .find(|r| r.get("type").and_then(|v| v.as_str()) == Some("summary") && r.get("summary").is_some())
        .and_then(|r| r.get("summary").cloned());
    // Qoder detail mirrors build_session_meta: normalized atomic wrappers, inline metadata, and
    // app-owned title/tags/delete overrides without rewriting another CLI's transcript.
    let (cc_title, cc_tags, cc_deleted) =
        if qoder { crate::qoder::sidecar_meta(path) } else { read_ccbud(&recs) };
    let shaped = shape_messages(&recs);
    let auto_title = qoder_title.unwrap_or_else(|| first_user_text(&shaped.messages));
    let subagent = agent_rec.is_some();
    let top_level_cwd = meta_rec
        .and_then(|r| r.get("cwd"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let cwd = if qoder {
        qoder_cwd.or(top_level_cwd)
    } else {
        top_level_cwd
    };
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
    let base_id = meta_rec
        .and_then(|r| r.get("sessionId"))
        .and_then(|v| v.as_str())
        .unwrap_or(&stem)
        .to_string();
    // A subagent session's id carries the agent suffix; only a top-level session embeds subagents.
    let sess_id = match (subagent, &agent_id) {
        (true, Some(aid)) => format!("{}-{}", base_id, aid),
        _ => base_id.clone(),
    };
    let mut subs = if subagent { serde_json::Map::new() } else { read_subagents(file) };
    apply_skill_names(&shaped.messages, &mut subs);
    // Live Qoder files are never imported snapshots; avoid probing a protected sibling sidecar.
    let import_meta = if qoder { None } else { read_import_meta(file) };

    json!({
        "meta": {
            "id": if qoder { format!("qoder:{}", stem) } else { format!("disk:{}{}", stem, if subagent { ":sub" } else { "" }) },
            "file": file,
            "source": if qoder { "qoder" } else { "disk" },
            // Renderer falls back to Claude when null (the app's home turf carries no label).
            "assistant": if qoder { json!("Qoder") } else { Value::Null },
            "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
            "autoTitle": auto_title,
            "tags": cc_tags,
            "summary": summary,
            "sessionId": sess_id,
            "cwd": cwd.clone(),
            "project": cwd.as_deref().map(base_name).unwrap_or_default(),
            "gitBranch": meta_rec.and_then(|r| r.get("gitBranch")).cloned().unwrap_or(Value::Null),
            "version": meta_rec.and_then(|r| r.get("version")).cloned().unwrap_or(Value::Null),
            "isSubagent": subagent,
            // A standalone subagent transcript self-reports its invoking skill via the sentinel.
            "skill": if subagent { skill_from_recs(&recs) } else { None::<String> },
            "deleted": cc_deleted,
            "imported": import_meta.is_some(),
            "importedFrom": import_meta.as_ref().and_then(|m| m.get("originalPath")).cloned().unwrap_or(Value::Null),
            "importedAt": import_meta.as_ref().and_then(|m| m.get("importedAt")).cloned().unwrap_or(Value::Null),
            "model": qoder_model.or(shaped.model),
            "totals": shaped.totals,
            "messages": shaped.messages.len(),
            "subagentCount": subs.len(),
            "firstTs": shaped.first_ts,
            "lastTs": shaped.last_ts,
        },
        "messages": shaped.messages,
        "subagents": subs,
    })
}

// ---- content search (the session list's "big search") ----
//
// Scans session CONTENT (message text / thinking / tool calls + results) across every listed
// session — main threads, their subagent transcripts, and Codex rollouts — and reports, per
// matching session, WHERE the first match lives ("main" or a subagent's tool_use key) plus a
// display snippet. The renderer opens the session, switches the panel to that agent, and
// re-finds the query locally, so list hits and in-conversation positioning stay aligned.
//
// Performance model (this runs per keystroke, debounced):
//  - extraction cache: path -> (mtime, size, extracted text), so repeated queries pay the JSON
//    parse + shaping once per file version;
//  - raw prefilter: on a cache miss the raw JSONL bytes are substring-scanned first, and only
//    files that could match are parsed at all (JSON escapes quotes/backslashes/control chars,
//    so the prefilter is skipped for queries containing those);
//  - parallel scan: per-file work fans out over a small thread pool.

/// ASCII-case-insensitive substring search (byte-wise; non-ASCII must match exactly — CJK has no
/// case). A valid-UTF-8 needle can only match at char boundaries of valid-UTF-8 text (ASCII bytes
/// never equal continuation bytes), so the returned byte offset is safe to slice on.
fn ifind(hay: &str, needle: &str, from: usize) -> Option<usize> {
    let h = hay.as_bytes();
    let n = needle.as_bytes();
    if n.is_empty() || h.len() < n.len() {
        return None;
    }
    let last = h.len() - n.len();
    let n0 = n[0].to_ascii_lowercase();
    let mut i = from;
    while i <= last {
        if h[i].to_ascii_lowercase() == n0 {
            let mut k = 1;
            while k < n.len() && h[i + k].to_ascii_lowercase() == n[k].to_ascii_lowercase() {
                k += 1;
            }
            if k == n.len() {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

/// Non-overlapping case-insensitive occurrence count (same fold as ifind).
fn icount(hay: &str, needle: &str) -> usize {
    let (mut i, mut c) = (0usize, 0usize);
    while let Some(p) = ifind(hay, needle, i) {
        c += 1;
        i = p + needle.len().max(1);
    }
    c
}

/// Mirror of the renderer's formatCodexBootstrap (conversations.js / runtime.js): Codex records
/// its initial AGENTS.md instructions + environment snapshot as one XML-ish user text block, and
/// the panel renders it as compact Markdown — search must index that same Markdown, not the raw
/// transport shape. None = not a bootstrap message (ordinary prose passes through untouched).
fn format_codex_bootstrap(source: &str) -> Option<String> {
    static AGENTS_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static ENV_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static ROOT_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let agents_re = AGENTS_RE.get_or_init(|| {
        regex::Regex::new(
            r"(?is)^\s*#\s+AGENTS\.md instructions for ([^\r\n]+).*?<INSTRUCTIONS\b[^>]*>(.*?)</INSTRUCTIONS>",
        )
        .unwrap()
    });
    let env_re = ENV_RE.get_or_init(|| {
        regex::Regex::new(r"(?is)<environment_context\b[^>]*>(.*?)</environment_context>").unwrap()
    });
    let root_re =
        ROOT_RE.get_or_init(|| regex::Regex::new(r"(?is)<root\b[^>]*>(.*?)</root>").unwrap());
    let agents = agents_re.captures(source)?;

    // Dynamic per-name regexes are fine here: at most one bootstrap message exists per session.
    let tag = |block: &str, name: &str| -> String {
        regex::Regex::new(&format!(r"(?is)<{name}\b[^>]*>(.*?)</{name}>"))
            .ok()
            .and_then(|re| re.captures(block).and_then(|c| c.get(1).map(|m| m.as_str().trim().to_string())))
            .unwrap_or_default()
    };
    let attr = |block: &str, name: &str, attribute: &str| -> String {
        regex::Regex::new(&format!(r#"(?i)<{name}\b[^>]*\b{attribute}=["']([^"']+)["']"#))
            .ok()
            .and_then(|re| re.captures(block).and_then(|c| c.get(1).map(|m| m.as_str().trim().to_string())))
            .unwrap_or_default()
    };
    let code = |value: &str| -> String {
        if value.is_empty() { String::new() } else { format!("`{}`", value) }
    };

    let mut parts: Vec<String> =
        vec![format!("# AGENTS.md instructions for {}", agents.get(1).map(|m| m.as_str().trim()).unwrap_or(""))];
    let instructions = agents.get(2).map(|m| m.as_str().trim()).unwrap_or("");
    if !instructions.is_empty() {
        let lines: Vec<&str> = instructions.lines().filter(|line| !line.trim().is_empty()).collect();
        parts.push(if lines.len() == 1 {
            format!("**INSTRUCTIONS:** {}", lines[0].trim())
        } else {
            format!("**INSTRUCTIONS:**\n\n{}", instructions)
        });
    }

    let env = env_re.captures(source);
    if let Some(env) = &env {
        let block = env.get(1).map(|m| m.as_str()).unwrap_or("");
        let roots: Vec<String> = root_re
            .captures_iter(block)
            .filter_map(|c| c.get(1).map(|m| m.as_str().trim().to_string()))
            .filter(|r| !r.is_empty())
            .map(|r| code(&r))
            .collect();
        let fields: Vec<(&str, String)> = vec![
            ("environment_context", code(&tag(block, "cwd"))),
            ("shell", tag(block, "shell")),
            ("current_date", tag(block, "current_date")),
            ("timezone", tag(block, "timezone")),
            ("workspace_roots", roots.join(", ")),
            ("permission_profile", attr(block, "permission_profile", "type")),
            ("file_system", attr(block, "file_system", "type")),
        ]
        .into_iter()
        .filter(|(_, value)| !value.is_empty())
        .collect();
        if !fields.is_empty() {
            parts.push(
                fields
                    .iter()
                    .map(|(name, value)| format!("**{}:** {}", name, value))
                    .collect::<Vec<_>>()
                    .join("  \n"),
            );
        }
    }

    let mut rest = source.replacen(agents.get(0).map(|m| m.as_str()).unwrap_or(""), "", 1);
    if let Some(env) = &env {
        rest = rest.replacen(env.get(0).map(|m| m.as_str()).unwrap_or(""), "", 1);
    }
    let rest = rest.trim();
    if !rest.is_empty() {
        parts.push(rest.to_string());
    }
    Some(parts.join("\n\n").trim().to_string())
}

/// Strip harness-injected blocks from user prose — MUST stay rule-for-rule in sync with the
/// renderer's stripInjected (conversations.js) and the export viewer's copy (runtime.js), so what
/// the big search matches is exactly what the in-conversation search (and the panel) will show.
/// The Codex AGENTS bootstrap reformats to the same Markdown the panel renders; task-notification
/// envelopes keep their human-facing <result> body; the transport metadata (ids, status, summary)
/// is dropped and must therefore never be searchable.
fn strip_injected(s: &str) -> String {
    static SKILL_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static TASK_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static RESULT_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    // Same rule order as the JS: the Codex AGENTS bootstrap is reformatted FIRST, then the
    // envelope rules run over the (possibly rewritten) text.
    let bootstrap = format_codex_bootstrap(s);
    let s: &str = bootstrap.as_deref().unwrap_or(s);
    // A turn that is nothing but a <skill> envelope is Codex's recorded skill-instruction
    // injection — runtime context the panel suppresses wholesale, so search must too. Prose that
    // merely quotes <skill> markup alongside other text stays searchable.
    let skill_re = SKILL_RE
        .get_or_init(|| regex::Regex::new(r"(?is)^\s*<skill\b[^>]*>.*</skill>\s*$").unwrap());
    if skill_re.is_match(s) {
        return String::new();
    }
    let task_re = TASK_RE.get_or_init(|| {
        regex::Regex::new(r"(?is)<task-notification\b[^>]*>.*?</task-notification>").unwrap()
    });
    let result_re =
        RESULT_RE.get_or_init(|| regex::Regex::new(r"(?is)<result\b[^>]*>(.*?)</result>").unwrap());
    let re = RE.get_or_init(|| {
        regex::Regex::new(
            r"(?s)<system-reminder>.*?</system-reminder>|<command-[a-z-]+>.*?</command-[a-z-]+>|<local-command-[a-z]+>.*?</local-command-[a-z]+>",
        )
        .unwrap()
    });
    let unwrapped = task_re.replace_all(s, |caps: &regex::Captures| {
        result_re
            .captures(caps.get(0).map(|m| m.as_str()).unwrap_or(""))
            .and_then(|c| c.get(1))
            .map(|m| format!("\n{}\n", m.as_str().trim()))
            .unwrap_or_default()
    });
    re.replace_all(&unwrapped, "").trim().to_string()
}

fn tool_result_search_text(c: &Value) -> String {
    if let Some(s) = c.as_str() {
        return s.to_string();
    }
    if let Some(arr) = c.as_array() {
        return arr
            .iter()
            .filter_map(|x| x.get("text").and_then(|t| t.as_str()))
            .collect::<Vec<_>>()
            .join("\n");
    }
    String::new()
}

/// One searchable text blob for a shaped message list — the renderer's messagePlainText, flattened:
/// user prose (injected blocks stripped), assistant text, thinking, tool name + input JSON, and
/// tool results. Images and raw structure are skipped so a hit here is findable in the panel.
fn extract_search_text(messages: &[Value]) -> String {
    let mut out = String::new();
    let mut push = |t: &str| {
        if !t.is_empty() {
            out.push_str(t);
            out.push('\n');
        }
    };
    for m in messages {
        let role = m.get("role").and_then(|v| v.as_str()).unwrap_or("");
        let content = match m.get("content") {
            Some(c) => c,
            None => continue,
        };
        if let Some(s) = content.as_str() {
            if role == "user" {
                push(&strip_injected(s));
            } else {
                push(s);
            }
            continue;
        }
        let arr = match content.as_array() {
            Some(a) => a,
            None => continue,
        };
        for b in arr {
            match b.get("type").and_then(|v| v.as_str()).unwrap_or("") {
                "text" => {
                    let t = b.get("text").and_then(|v| v.as_str()).unwrap_or("");
                    if role == "user" {
                        push(&strip_injected(t));
                    } else {
                        push(t);
                    }
                }
                "thinking" => push(b.get("thinking").and_then(|v| v.as_str()).unwrap_or("")),
                "skill_load" => {
                    push(b.get("name").and_then(Value::as_str).unwrap_or(""));
                    push(b.get("path").and_then(Value::as_str).unwrap_or(""));
                    push(b.get("snapshot").and_then(Value::as_str).unwrap_or(""));
                }
                "tool_use" => {
                    let name = b.get("name").and_then(|v| v.as_str()).unwrap_or("");
                    let input = b.get("input").map(|i| i.to_string()).unwrap_or_default();
                    push(&format!("{} {}", name, input));
                }
                "tool_result" => {
                    push(&tool_result_search_text(b.get("content").unwrap_or(&Value::Null)))
                }
                _ => {}
            }
        }
    }
    out
}

struct SearchCache {
    map: std::collections::HashMap<PathBuf, (f64, u64, std::sync::Arc<String>)>,
    bytes: usize,
}
/// Extracted-text memo, keyed path -> (mtime, size, text). Cleared wholesale past the byte budget
/// (crude but safe — the next search simply re-extracts what it touches).
fn search_cache() -> &'static std::sync::Mutex<SearchCache> {
    static CACHE: std::sync::OnceLock<std::sync::Mutex<SearchCache>> = std::sync::OnceLock::new();
    CACHE.get_or_init(|| std::sync::Mutex::new(SearchCache { map: std::collections::HashMap::new(), bytes: 0 }))
}
const SEARCH_CACHE_BUDGET: usize = 128 * 1024 * 1024;

/// Search one transcript file for `q`: (extracted text, first-match byte offset), or None.
/// Serves from the extraction cache when fresh; otherwise prefilters the raw bytes and only
/// parses candidates — files that can't match are neither parsed nor cached.
fn thread_scan(path: &Path, q: &str, raw_safe: bool) -> Option<(std::sync::Arc<String>, usize)> {
    let meta = fs::metadata(path).ok()?;
    let (mt, sz) = (cache_stamp_ms(path), meta.len());
    if let Ok(cache) = search_cache().lock() {
        if let Some((cmt, csz, text)) = cache.map.get(path) {
            if *cmt == mt && *csz == sz {
                let t = text.clone();
                drop(cache);
                return ifind(&t, q, 0).map(|p| (t, p));
            }
        }
    }
    let fk = foreign_kind(path);
    let messages: Vec<Value> = if fk == Some(Foreign::Antigravity) {
        // SQLite source: no raw-bytes prefilter (the payloads are binary) — extraction is
        // cached, so the decode is paid once per file version.
        crate::antigravity::normalize_db(path).messages
    } else {
        let raw = read_session_text(path).ok()?;
        if raw_safe && ifind(&raw, q, 0).is_none() {
            return None;
        }
        let parsed = parse_lines(&raw);
        let recs = if crate::qoder::looks_qoder_path(path) {
            crate::qoder::normalize_records(&parsed)
        } else {
            parsed
        };
        match fk {
            Some(Foreign::Grok) => crate::grok::normalize(&recs, None).messages,
            Some(Foreign::Copilot) => crate::copilot::normalize(&recs).messages,
            _ => {
                if crate::codex::looks_codex(&recs) {
                    crate::codex::session_from_recs(&path.to_string_lossy(), &recs)
                        .get("messages")
                        .and_then(|v| v.as_array())
                        .cloned()
                        .unwrap_or_default()
                } else {
                    shape_messages(&recs).messages
                }
            }
        }
    };
    let text = std::sync::Arc::new(extract_search_text(&messages));
    if let Ok(mut cache) = search_cache().lock() {
        if cache.bytes + text.len() > SEARCH_CACHE_BUDGET {
            cache.map.clear();
            cache.bytes = 0;
        }
        if let Some((_, _, old)) = cache.map.insert(path.to_path_buf(), (mt, sz, text.clone())) {
            cache.bytes = cache.bytes.saturating_sub(old.len()); // replaced a stale entry
        }
        cache.bytes += text.len();
    }
    ifind(&text, q, 0).map(|p| (text, p))
}

/// Display snippet around the first match: ~56 chars of context either side, whitespace collapsed,
/// ellipsized at cut edges. Slice bounds snap outward/inward to char boundaries.
fn snippet_around(text: &str, pos: usize, match_len: usize) -> String {
    const CTX: usize = 56;
    let mut start = pos.saturating_sub(CTX);
    while start > 0 && !text.is_char_boundary(start) {
        start -= 1;
    }
    let mut end = (pos + match_len + CTX).min(text.len());
    while end < text.len() && !text.is_char_boundary(end) {
        end += 1;
    }
    let body = text[start..end].split_whitespace().collect::<Vec<_>>().join(" ");
    format!("{}{}{}", if start > 0 { "…" } else { "" }, body, if end < text.len() { "…" } else { "" })
}

/// Scan one session — main thread first, then each subagent transcript — and shape the hit the
/// renderer needs to auto-locate: which agent matched, a snippet, and the occurrence count.
fn scan_session(file: &Path, q: &str, raw_safe: bool) -> Option<Value> {
    if let Some((text, pos)) = thread_scan(file, q, raw_safe) {
        return Some(json!({
            "file": file.to_string_lossy(),
            "agent": "main",
            "snippet": snippet_around(&text, pos, q.len()),
            "count": icount(&text, q),
        }));
    }
    let dir = subagent_dir(file)?;
    let mut names: Vec<String> = vec![];
    if let Ok(entries) = fs::read_dir(&dir) {
        for ent in entries.flatten() {
            let name = ent.file_name().to_string_lossy().into_owned();
            if name.starts_with("agent-") && name.ends_with(".jsonl") {
                names.push(name);
            }
        }
    }
    names.sort();
    for name in names {
        if let Some((text, pos)) = thread_scan(&dir.join(&name), q, raw_safe) {
            let agent_id = name.trim_start_matches("agent-").trim_end_matches(".jsonl").to_string();
            let meta_path = dir.join(format!("agent-{}.meta.json", agent_id));
            let meta_raw = if crate::qoder::looks_qoder_path(file) {
                crate::qoder::read_text(&meta_path)
            } else {
                fs::read_to_string(&meta_path)
            };
            let meta: Value = meta_raw
                .ok()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_else(|| json!({}));
            // Key by the spawning tool_use id — the same key read_subagents uses, so the renderer
            // can switch its panel straight to this agent.
            let key = meta
                .get("toolUseId")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| format!("agent:{}", agent_id));
            let agent_type = meta
                .get("agentType")
                .and_then(|v| v.as_str())
                .or_else(|| meta.get("subagent_type").and_then(|v| v.as_str()))
                .unwrap_or("agent");
            return Some(json!({
                "file": file.to_string_lossy(),
                "agent": key,
                "agentType": agent_type,
                "snippet": snippet_around(&text, pos, q.len()),
                "count": icount(&text, q),
            }));
        }
    }
    None
}

/// Content search over the same candidate set (and dir/trash scoping) as the list view, newest
/// first. Returns [{ file, agent, agentType?, snippet, count }] for up to `limit` sessions.
pub fn search_sessions(config: &Value, active: &str, query: &str, limit: usize) -> Vec<Value> {
    let q = query.trim();
    if q.is_empty() {
        return vec![];
    }
    let trash = active == TRASH_ID;
    // The raw-bytes prefilter only applies to queries whose every byte is guaranteed to appear
    // verbatim in the file's JSON encoding: printable ASCII minus the chars JSON escapes
    // (quote/backslash/control). Non-ASCII stays OFF the prefilter — some producers (e.g.
    // Python's json.dumps default) escape it as \uXXXX, which a byte scan would miss; those
    // queries always take the parse+extract path (cached, so paid once per file version).
    let raw_safe = q.bytes().all(|b| b.is_ascii() && b != b'"' && b != b'\\' && b >= 0x20);
    // Reuse the list's pre-limit canonical-thread dedupe, directory/trash scope, and ordering.
    // Otherwise duplicate physical rollouts could consume the 600-file search window even though
    // the sidebar shows only their selected representative.
    let files: Vec<(PathBuf, f64)> = list_sessions(config, active, 600)
        .into_iter()
        .filter_map(|session| {
            let file = PathBuf::from(session.get("file")?.as_str()?);
            let created = session
                .get("createdAt")
                .and_then(Value::as_f64)
                .unwrap_or_else(|| created_ms(&file));
            Some((file, created))
        })
        .collect();
    // One batch helper call instead of a spawn per protected qoder file inside the worker loop
    // (repeat scans of unchanged files are then served by the extraction + helper caches).
    let qoder_files: Vec<PathBuf> = files
        .iter()
        .map(|(file, _)| file.clone())
        .filter(|file| crate::qoder::looks_qoder_path(file))
        .collect();
    crate::qoder::prefetch(&qoder_files);
    let hits = std::sync::Mutex::new(Vec::<(f64, Value)>::new());
    let next = std::sync::atomic::AtomicUsize::new(0);
    let workers = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(1, 8);
    std::thread::scope(|s| {
        for _ in 0..workers {
            s.spawn(|| loop {
                let i = next.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                if i >= files.len() {
                    break;
                }
                let (file, ct) = &files[i];
                if is_session_deleted(file) != trash {
                    continue;
                }
                if let Some(hit) = scan_session(file, q, raw_safe) {
                    if let Ok(mut h) = hits.lock() {
                        h.push((*ct, hit));
                    }
                }
            });
        }
    });
    let mut hits = hits.into_inner().unwrap_or_else(|e| e.into_inner());
    hits.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    hits.truncate(limit);
    hits.into_iter().map(|(_, v)| v).collect()
}

/// Write per-conversation customization (custom title + tags) onto the FIRST parseable line as a
/// `__ccbud__` field. Atomic (tmp + rename). Guarded to the configured dirs + the imports store
/// (renderer can't drive an arbitrary-path write, but imported sessions must be titleable/taggable
/// too — mirrors history.js setCcbud, whose getDirs() includes the imported dir).
pub fn set_ccbud(file: &str, patch: &Value, config: &Value) -> Value {
    let target = Path::new(file);
    if !within_scope(target, config) {
        return json!({ "ok": false, "reason": "out-of-scope" });
    }
    // Foreign-CLI sessions are other tools' files (one is SQLite): their title/tags/delete
    // flag always live in the app-owned sidecar. Same cache-drop contract as the codex branch.
    if let Some(fk) = foreign_kind(target) {
        let r = match fk {
            Foreign::Grok => crate::grok::set_meta(file, patch),
            Foreign::Copilot => crate::copilot::set_meta(file, patch),
            Foreign::Antigravity => crate::antigravity::set_meta(file, patch),
        };
        if r.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
            if let Ok(mut cache) = meta_cache().lock() {
                cache.remove(target);
            }
        }
        return r;
    }
    // Qoder sessions are Claude-format but another tool's live files: title/tags/delete go to
    // the shared sidecar (keyed qoder:<uuid>) instead of an in-file rewrite. The sidecar edit
    // doesn't touch the file (no mtime bump), so the list-meta memo is dropped by hand.
    if crate::qoder::looks_qoder_path(target) {
        let r = crate::qoder::set_meta(file, patch);
        if r.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
            if let Ok(mut cache) = meta_cache().lock() {
                cache.remove(target);
            }
        }
        return r;
    }
    let raw = match fs::read_to_string(file) {
        Ok(s) => s,
        Err(_) => return json!({ "ok": false, "reason": "read" }),
    };
    // Live Codex rollouts are another tool's files — their title/tags/delete flag live in the
    // app-owned sidecar instead of being written into the rollout. Imported codex COPIES sit
    // inside our store (marked by .import.json) and take the normal in-file path below.
    let head: Vec<Value> = raw.lines().take(8).filter_map(|l| serde_json::from_str(l.trim()).ok()).collect();
    if crate::codex::looks_codex(&head) && read_import_meta(file).is_none() {
        let r = crate::codex::set_meta(file, patch);
        // A sidecar edit changes the row without touching the rollout file (no mtime bump), so
        // the list-meta memo must be dropped by hand. In-file writes below invalidate via mtime.
        if r.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
            if let Ok(mut cache) = meta_cache().lock() {
                cache.remove(target);
            }
        }
        return r;
    }
    let mut lines: Vec<String> = raw.split('\n').map(|s| s.to_string()).collect();
    let mut found: Option<(usize, Value)> = None;
    for (i, l) in lines.iter().enumerate() {
        let s = l.trim();
        if s.is_empty() {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<Value>(s) {
            if v.is_object() {
                found = Some((i, v));
                break;
            }
        }
    }
    let (idx, mut obj) = match found {
        Some(x) => x,
        None => return json!({ "ok": false, "reason": "empty" }),
    };
    let mut next = obj.get("__ccbud__").and_then(|v| v.as_object()).cloned().unwrap_or_default();
    if let Some(t) = patch.get("title") {
        let t = t.as_str().unwrap_or("").trim().to_string();
        if !t.is_empty() {
            next.insert("title".into(), json!(t));
        } else {
            next.remove("title");
        }
    }
    if let Some(tags) = patch.get("tags") {
        let mut arr: Vec<String> = vec![];
        if let Some(ta) = tags.as_array() {
            for x in ta {
                if let Some(s) = x.as_str() {
                    let s = s.trim();
                    if !s.is_empty() && !arr.iter().any(|y| y == s) {
                        arr.push(s.to_string());
                    }
                }
            }
        }
        if !arr.is_empty() {
            next.insert("tagList".into(), json!(arr));
        } else {
            next.remove("tagList");
        }
    }
    // Soft delete / restore: `delete: true` marks the session deleted; `delete: false` (restore)
    // drops the flag. Restore that empties __ccbud__ removes the field wholesale below.
    if let Some(d) = patch.get("delete") {
        if d.as_bool().unwrap_or(false) {
            next.insert("delete".into(), json!(true));
        } else {
            next.remove("delete");
        }
    }
    let o = obj.as_object_mut().unwrap();
    if !next.is_empty() {
        o.insert("__ccbud__".into(), Value::Object(next));
    } else {
        o.remove("__ccbud__");
    }
    lines[idx] = serde_json::to_string(&obj).unwrap_or_default();
    let out = lines.join("\n");
    let tmp = format!("{}.ccbud.tmp", file);
    if fs::write(&tmp, &out).is_err() {
        return json!({ "ok": false, "reason": "write" });
    }
    if fs::rename(&tmp, file).is_err() {
        let _ = fs::remove_file(&tmp);
        return json!({ "ok": false, "reason": "write" });
    }
    // The rewrite bumps mtime/size, which already invalidates the list-meta memo — dropping the
    // entry outright also covers a same-millisecond, same-length rewrite.
    if let Ok(mut cache) = meta_cache().lock() {
        cache.remove(target);
    }
    json!({ "ok": true })
}

/// Permanently remove a session's .jsonl from disk (recycle-bin "delete forever"). Guarded to the
/// configured dirs + the imports store exactly like set_ccbud, and also drops the session's
/// `<stem>/` subagents tree and any import sidecar (mirrors remove_import's cleanup).
/// Renderer-driven writes/deletes are confined to the configured work dirs' data trees
/// (projects/ AND sessions/) plus the imports store.
fn within_scope(target: &Path, config: &Value) -> bool {
    all_dirs(config).iter().any(|(_, _, pd)| {
        target.starts_with(pd)
            || ["sessions", "session-state", "conversations"]
                .iter()
                .any(|n| sibling_dir(pd, n).map(|sd| target.starts_with(sd)).unwrap_or(false))
    })
}

pub fn delete_session_file(file: &str, config: &Value) -> Value {
    let target = Path::new(file);
    if !within_scope(target, config) {
        return json!({ "ok": false, "reason": "out-of-scope" });
    }
    if !target.is_file() {
        return json!({ "ok": false, "reason": "missing" });
    }
    // A LIVE Codex rollout, Qoder session, or foreign-CLI session is another tool's file — the
    // app only ever soft-deletes those via the sidecar and never rewrites them (see set_ccbud),
    // so "delete forever" must not rm the source either. Imported codex COPIES (marked by an
    // .import.json) are our own snapshots and stay hard-deletable, like Claude sessions the app
    // manages in the configured dirs.
    if foreign_kind(target).is_some() || crate::qoder::looks_qoder_path(target) {
        return json!({ "ok": false, "reason": "foreign" });
    }
    let head = parse_lines(&read_head(target, 131072));
    if crate::codex::looks_codex(&head) && read_import_meta(file).is_none() {
        return json!({ "ok": false, "reason": "foreign" });
    }
    if fs::remove_file(target).is_err() {
        return json!({ "ok": false, "reason": "remove" });
    }
    crate::codex::remove_meta(file); // drop any codex sidecar entry (no-op for Claude sessions)
    let dir = target.parent().unwrap_or(Path::new("."));
    let stem = target.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    if !stem.is_empty() {
        let _ = fs::remove_dir_all(dir.join(stem)); // <stem>/subagents/...
        let _ = fs::remove_file(dir.join(format!("{}.import.json", stem)));
    }
    json!({ "ok": true })
}

/// Self-contained round-trip test of set_ccbud + get_session in a throwaway projects tree.
pub fn history_selftest(base_dir: &Path) -> Value {
    let proj = base_dir.join("test-claude").join("projects").join("-test-cwd");
    let _ = fs::create_dir_all(&proj);
    let file = proj.join("sess1.jsonl");
    let content = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello world from selfcheck\"},\"cwd\":\"/test/cwd\",\"sessionId\":\"sess1\",\"timestamp\":\"2025-01-01T10:00:00.000Z\"}\n";
    let _ = fs::write(&file, content);
    let config = json!({ "historyDirs": [ base_dir.join("test-claude").to_string_lossy() ] });
    let fpath = file.to_string_lossy().to_string();
    let set = set_ccbud(&fpath, &json!({ "title": "My Title", "tags": ["a", "b", "b"] }), &config);
    let sess = get_session(&fpath);
    let title = sess.get("meta").and_then(|m| m.get("title")).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let tags = sess.get("meta").and_then(|m| m.get("tags")).and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
    let auto = sess.get("meta").and_then(|m| m.get("autoTitle")).and_then(|v| v.as_str()).unwrap_or("").to_string();
    // Soft-delete round-trip: marked → hidden from "all" but present in trash → restored → back in "all".
    let _ = set_ccbud(&fpath, &json!({ "delete": true }), &config);
    let after_del = get_session(&fpath).get("meta").and_then(|m| m.get("deleted")).and_then(|v| v.as_bool()).unwrap_or(false);
    let hidden_in_all = !list_sessions(&config, "all", 50).iter().any(|s| s.get("file").and_then(|v| v.as_str()) == Some(fpath.as_str()));
    let shown_in_trash = list_sessions(&config, TRASH_ID, 50).iter().any(|s| s.get("file").and_then(|v| v.as_str()) == Some(fpath.as_str()));
    let _ = set_ccbud(&fpath, &json!({ "delete": false }), &config);
    let restored = !get_session(&fpath).get("meta").and_then(|m| m.get("deleted")).and_then(|v| v.as_bool()).unwrap_or(false);
    json!({
        "setOk": set.get("ok").and_then(|v| v.as_bool()).unwrap_or(false),
        "title": title,
        "tagCount": tags,
        "autoTitle": auto,
        "deletedAfterMark": after_del,
        "hiddenInAll": hidden_in_all,
        "shownInTrash": shown_in_trash,
        "restored": restored,
    })
}

#[cfg(test)]
mod foreign_probe {
    use super::*;

    // Diagnostic harness (not an assertion): list + open REAL foreign-CLI sessions so the
    // shapers can be eyeballed against live ~/.grok, ~/.copilot, ~/.gemini/antigravity-cli.
    // Run: CCBUD_PROBE_FOREIGN="~/.grok,~/.copilot,~/.gemini/antigravity-cli" \
    //      cargo test --lib probe_foreign_dirs -- --ignored --nocapture
    #[test]
    #[ignore]
    fn probe_foreign_dirs() {
        let Ok(dirs) = std::env::var("CCBUD_PROBE_FOREIGN") else {
            eprintln!("set CCBUD_PROBE_FOREIGN=dir1,dir2,…");
            return;
        };
        let list: Vec<&str> = dirs.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
        let config = json!({ "historyDirs": list });
        let sessions = list_sessions(&config, "all", 500);
        eprintln!("== {} sessions across {:?}", sessions.len(), list);
        let mut by_source: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
        for s in &sessions {
            *by_source
                .entry(s.get("source").and_then(|v| v.as_str()).unwrap_or("?").to_string())
                .or_insert(0) += 1;
        }
        eprintln!("== by source: {:?}", by_source);
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        for s in &sessions {
            let src = s.get("source").and_then(|v| v.as_str()).unwrap_or("?").to_string();
            if !seen.insert(src.clone()) {
                continue;
            }
            let file = s.get("file").and_then(|v| v.as_str()).unwrap_or("");
            eprintln!(
                "-- [{}] {} | cwd={} | title={:?}",
                src,
                file,
                s.get("cwd").and_then(|v| v.as_str()).unwrap_or("-"),
                s.get("title").and_then(|v| v.as_str()).unwrap_or("-")
            );
            let detail = get_session(file);
            let meta = detail.get("meta").cloned().unwrap_or(Value::Null);
            let msgs = detail.get("messages").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
            eprintln!(
                "   detail: assistant={:?} messages={} totals={} firstTs={:?}",
                meta.get("assistant").and_then(|v| v.as_str()),
                msgs,
                meta.get("totals").map(|t| t.to_string()).unwrap_or_default(),
                meta.get("firstTs").and_then(|v| v.as_str())
            );
            if let Some(arr) = detail.get("messages").and_then(|v| v.as_array()) {
                for m in arr.iter().take(4) {
                    let role = m.get("role").and_then(|v| v.as_str()).unwrap_or("?");
                    let kinds: Vec<String> = m
                        .get("content")
                        .and_then(|c| c.as_array())
                        .map(|a| {
                            a.iter()
                                .map(|b| b.get("type").and_then(|t| t.as_str()).unwrap_or("?").to_string())
                                .collect()
                        })
                        .unwrap_or_default();
                    eprintln!("   msg {} {:?}", role, kinds);
                }
            }
        }
    }
}

// ---- import (copy someone else's .jsonl into the app-managed store) ----

fn encode_cwd(cwd: Option<&str>) -> String {
    match cwd {
        Some(c) if !c.is_empty() => c.replace(['/', '\\'], "-"),
        _ => "-imported".to_string(),
    }
}

fn copy_dir(src: &Path, dst: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dst)?;
    for e in fs::read_dir(src)? {
        let e = e?;
        let s = e.path();
        let d = dst.join(e.file_name());
        if s.is_dir() {
            copy_dir(&s, &d)?;
        } else {
            fs::copy(&s, &d)?;
        }
    }
    Ok(())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn records_to_jsonl(records: &[Value]) -> String {
    let mut text = records
        .iter()
        .map(|r| serde_json::to_string(r).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("\n");
    text.push('\n');
    text
}

/// A qoder transcript imported into the app store loses its container path and would otherwise
/// re-parse as raw Claude records: queued commands vanish, redacted duplicates render, atomic
/// wrappers stay fragmented, and qoder's own title is lost. Sniffed by CONTENT (import copies and
/// bundle zips carry no .qoder path), the copy is rewritten up front — normalized records, with
/// the qoder title carried onto the first line's __ccbud__ so the import keeps its name.
fn qoder_import_raw(recs: &[Value]) -> Option<(String, Vec<Value>)> {
    if !crate::qoder::looks_qoder_records(recs) {
        return None;
    }
    let mut normalized = crate::qoder::normalize_records(recs);
    if let Some(title) = crate::qoder::session_title_from(recs) {
        if let Some(first) = normalized.iter_mut().find(|r| r.is_object()) {
            let obj = first.as_object_mut().unwrap();
            let mut cc = obj.get("__ccbud__").and_then(|v| v.as_object()).cloned().unwrap_or_default();
            cc.entry("title".to_string()).or_insert_with(|| json!(title));
            obj.insert("__ccbud__".into(), Value::Object(cc));
        }
    }
    Some((records_to_jsonl(&normalized), normalized))
}

/// Snapshot a transcript (already read into `raw`) plus its subagent sidecars into the import store,
/// laid out like a native projects/ tree + a provenance sidecar. `subagents`: (filename, bytes) to
/// drop under `<baseId>/subagents/` — names are basename-reduced and pattern-checked so a crafted
/// entry can't escape the directory. Returns 1 = imported, 2 = skipped (already present),
/// 0 = failed/not-a-transcript. Shared by the plain-.jsonl and .zip-bundle import paths.
fn write_imported(raw: &str, original_path: &str, original_name: &str, subagents: &[(String, Vec<u8>)]) -> i32 {
    let recs = parse_lines(raw);
    let is_codex = crate::codex::looks_codex(&recs);
    // Qoder content is rewritten to Claude shape before storing — the has_msg gate below then
    // sees the materialized queued-command user turns too.
    let (qoder_text, recs) = match qoder_import_raw(&recs) {
        Some((text, normalized)) => (Some(text), normalized),
        None => (None, recs),
    };
    let raw = qoder_text.as_deref().unwrap_or(raw);
    let has_msg = recs.iter().any(|r| {
        let t = r.get("type").and_then(|v| v.as_str());
        (t == Some("user") || t == Some("assistant")) && r.get("message").is_some()
    });
    if !has_msg && !is_codex {
        return 0;
    }
    let name_stem = || Path::new(original_name).file_stem().and_then(|s| s.to_str()).unwrap_or("import").to_string();
    // Codex rollouts keep cwd/session id inside the session_meta payload, not on the records.
    let (cwd_owned, base_id) = if is_codex {
        let (c, s) = crate::codex::head_ids(&recs);
        (c, s.unwrap_or_else(name_stem))
    } else {
        let meta_rec = recs.iter().find(|r| r.get("cwd").is_some()).or_else(|| recs.iter().find(|r| r.get("sessionId").is_some()));
        (
            meta_rec.and_then(|r| r.get("cwd")).and_then(|v| v.as_str()).map(|s| s.to_string()),
            meta_rec
                .and_then(|r| r.get("sessionId"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(name_stem),
        )
    };
    let cwd = cwd_owned.as_deref();
    let dest_dir = imports_root().join("projects").join(encode_cwd(cwd));
    let dest_file = dest_dir.join(format!("{}.jsonl", base_id));
    if dest_file.exists() {
        return 2;
    }
    if fs::create_dir_all(&dest_dir).is_err() || fs::write(&dest_file, raw).is_err() {
        return 0;
    }
    if !subagents.is_empty() {
        let sub_dir = dest_dir.join(&base_id).join("subagents");
        if fs::create_dir_all(&sub_dir).is_ok() {
            for (name, bytes) in subagents {
                // file_name() strips any directory component, so the write can't escape sub_dir.
                let safe = Path::new(name).file_name().and_then(|n| n.to_str()).unwrap_or("");
                let lower = safe.to_lowercase();
                if lower.starts_with("agent-") && (lower.ends_with(".jsonl") || lower.ends_with(".meta.json")) {
                    // A qoder session's subagent transcripts carry the same atomic wrappers —
                    // the parent's sniff decides, so the whole stored copy is Claude-shaped.
                    if qoder_text.is_some() && lower.ends_with(".jsonl") {
                        if let Ok(text) = std::str::from_utf8(bytes) {
                            let normalized = crate::qoder::normalize_records(&parse_lines(text));
                            let _ = fs::write(sub_dir.join(safe), records_to_jsonl(&normalized));
                            continue;
                        }
                    }
                    let _ = fs::write(sub_dir.join(safe), bytes);
                }
            }
        }
    }
    let sidecar = dest_dir.join(format!("{}.import.json", base_id));
    let _ = fs::write(
        &sidecar,
        serde_json::to_vec_pretty(&json!({
            "originalPath": original_path,
            "originalName": original_name,
            "sessionId": base_id,
            "importedAt": now_ms(),
        }))
        .unwrap_or_default(),
    );
    1
}

/// Import a plain .jsonl transcript, bringing along its on-disk subagents dir if present.
/// Foreign-CLI sources (Grok / Copilot / Antigravity) are intentionally not importable —
/// their layouts/formats aren't Claude/Codex, and a Grok chat_history head would otherwise
/// trip looks_codex (its `reasoning` lines look like old envelope-less Codex items).
fn import_one(src: &str) -> i32 {
    let src_path = Path::new(src);
    if foreign_kind(src_path).is_some() {
        return 0;
    }
    let raw = match read_session_text(src_path) {
        Ok(s) => s,
        Err(_) => return 0,
    };
    // Path-less copies of foreign transcripts: refuse anything whose head sniffs as Grok
    // chat_history (type:system + later reasoning/tool_result) or Copilot events
    // (type:session.start with producer copilot-agent).
    let head: Vec<Value> = raw.lines().take(8).filter_map(|l| serde_json::from_str(l.trim()).ok()).collect();
    if looks_foreign_jsonl(&head) {
        return 0;
    }
    let subs = read_subagent_files(src_path);
    let original_name = src_path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    write_imported(&raw, src, original_name, &subs)
}

/// Content sniff for foreign CLI jsonl (used by import when the path no longer carries the
/// original container shape — e.g. a bare chat_history.jsonl dropped into the import dialog).
fn looks_foreign_jsonl(recs: &[Value]) -> bool {
    recs.iter().take(8).any(|r| match r.get("type").and_then(|v| v.as_str()) {
        // Copilot event stream
        Some("session.start") | Some("user.message") | Some("assistant.message")
        | Some("tool.execution_complete") | Some("tool.execution_start") => true,
        // Grok chat_history: top-level system/reasoning/tool_result (Claude wraps these)
        Some("reasoning") | Some("tool_result") if r.get("message").is_none() => true,
        Some("system") if r.get("content").is_some() && r.get("message").is_none() => true,
        _ => false,
    })
}

/// Import a conversation-bundle .zip (main session + `subagents/`), restoring the subagent layout so
/// the pipeline nests them exactly as if they'd been captured live. Round-trips export_bundle.
fn import_zip(src: &str) -> i32 {
    let bytes = match fs::read(src) {
        Ok(b) => b,
        Err(_) => return 0,
    };
    let (main, subs) = crate::ziputil::split_bundle(crate::ziputil::read(&bytes));
    let main_data = match main {
        Some((_, data)) => data,
        None => return 0,
    };
    let raw = match String::from_utf8(main_data) {
        Ok(s) => s,
        Err(_) => return 0,
    };
    let original_name = Path::new(src).file_name().and_then(|n| n.to_str()).unwrap_or("");
    write_imported(&raw, src, original_name, &subs)
}

pub fn import_paths(paths: &[String]) -> Value {
    let (mut imported, mut skipped, mut failed) = (0, 0, 0);
    for src in paths {
        let lower = src.to_lowercase();
        let r = if lower.ends_with(".zip") {
            import_zip(src)
        } else if lower.ends_with(".jsonl") {
            import_one(src)
        } else {
            0
        };
        match r {
            1 => imported += 1,
            2 => skipped += 1,
            _ => failed += 1,
        }
    }
    json!({ "imported": imported, "skipped": skipped, "failed": failed })
}

pub fn remove_import(file: &str) -> Value {
    let root = imports_root();
    let f = Path::new(file);
    // Hard safety: only ever delete inside our own import store.
    if !f.starts_with(&root) {
        return json!({ "ok": false, "error": "outside import store" });
    }
    let dir = f.parent().unwrap_or(Path::new("."));
    let base = f.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let _ = fs::remove_file(f);
    let _ = fs::remove_file(dir.join(format!("{}.import.json", base)));
    let _ = fs::remove_dir_all(dir.join(base)); // subagents/
    json!({ "ok": true })
}

/// Self-contained test of import → list-as-imported → re-import-skip → remove.
pub fn import_selftest(base_dir: &Path) -> Value {
    std::env::set_var("CCBUD_HOME", base_dir); // imports_root() honors CCBUD_HOME
    let src_dir = base_dir.join("import-src");
    let _ = fs::create_dir_all(&src_dir);
    let src = src_dir.join("foreign.jsonl");
    let _ = fs::write(&src, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"imported hello\"},\"cwd\":\"/imp/cwd\",\"sessionId\":\"impsess\",\"timestamp\":\"2025-01-01T10:00:00.000Z\"}\n");
    let srcs = vec![src.to_string_lossy().to_string()];
    let r = import_paths(&srcs);
    let r2 = import_paths(&srcs);
    let config = json!({ "historyDirs": ["~/.claude"] });
    let sessions = list_sessions(&config, "__imported__", 50);
    let found = sessions.iter().any(|s| {
        s.get("imported").and_then(|v| v.as_bool()).unwrap_or(false)
            && s.get("title").and_then(|v| v.as_str()) == Some("imported hello")
    });
    let dest = imports_root().join("projects").join("-imp-cwd").join("impsess.jsonl");
    let rm = remove_import(&dest.to_string_lossy());

    // ---- bundle round-trip: a session WITH subagents exports as a .zip and re-imports with its
    // subagent transcripts restored (the export → import path the 对话 view drives). ----
    let bproj = base_dir.join("bundle-src").join("projects").join("-bnd-cwd");
    let _ = fs::create_dir_all(&bproj);
    let bmain = bproj.join("bundsess.jsonl");
    let _ = fs::write(&bmain, "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"tu9\",\"name\":\"Task\",\"input\":{}}]},\"cwd\":\"/bnd/cwd\",\"sessionId\":\"bundsess\",\"timestamp\":\"2025-01-01T10:00:00.000Z\"}\n");
    let bsub = bproj.join("bundsess").join("subagents");
    let _ = fs::create_dir_all(&bsub);
    let _ = fs::write(bsub.join("agent-b1.jsonl"), "{\"type\":\"assistant\",\"isSidechain\":true,\"agentId\":\"b1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"sub done\"}]},\"sessionId\":\"bundsess\",\"timestamp\":\"2025-01-01T10:00:01.000Z\"}\n");
    let _ = fs::write(bsub.join("agent-b1.meta.json"), "{\"agentType\":\"general-purpose\",\"description\":\"d\",\"toolUseId\":\"tu9\"}");
    let zip = export_bundle(&bmain.to_string_lossy()).unwrap_or_default();
    let zip_is_zip = zip.starts_with(&[0x50, 0x4b, 0x03, 0x04]);
    let zip_path = base_dir.join("bundle-src").join("bundsess.zip");
    let _ = fs::write(&zip_path, &zip);
    let rb = import_paths(&[zip_path.to_string_lossy().to_string()]);
    let imp_dir = imports_root().join("projects").join("-bnd-cwd");
    let sub_restored = imp_dir.join("bundsess").join("subagents").join("agent-b1.jsonl").exists()
        && imp_dir.join("bundsess").join("subagents").join("agent-b1.meta.json").exists();
    let bundle_sess = get_session(&imp_dir.join("bundsess.jsonl").to_string_lossy());
    let bundle_sub_count = bundle_sess.get("meta").and_then(|m| m.get("subagentCount")).and_then(|v| v.as_i64()).unwrap_or(0);

    json!({
        "imported": r.get("imported"),
        "reskipped": r2.get("skipped"),
        "appearsImported": found,
        "removed": rm.get("ok"),
        "gone": !dest.exists(),
        "bundleZip": zip_is_zip,
        "bundleImported": rb.get("imported"),
        "bundleSubRestored": sub_restored,
        "bundleSubagentCount": bundle_sub_count,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // One work dir carrying ALL foreign layouts (grok sessions/%2F…, copilot session-state/,
    // antigravity conversations/*.db): each session must list under its own source with cwd,
    // title and detail routed through its shaper, hard-delete must refuse, and content search
    // must reach every format.
    #[test]
    fn foreign_sources_route_end_to_end() {
        let base = std::env::temp_dir().join("ccbud-foreign-route-test");
        let _ = fs::remove_dir_all(&base);

        // grok: sessions/<enc-cwd>/<uuid>/chat_history.jsonl + summary.json
        let gdir = base.join("sessions").join("%2Ftmp%2Fgproj").join("0199-grok-uuid");
        fs::create_dir_all(&gdir).unwrap();
        fs::write(
            gdir.join("chat_history.jsonl"),
            "{\"type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"<user_query>grok needle walrus</user_query>\"}]}\n\
             {\"type\":\"assistant\",\"content\":\"done\",\"tool_calls\":[{\"id\":\"c1\",\"name\":\"run_terminal_command\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}]}\n",
        )
        .unwrap();
        fs::write(
            gdir.join("summary.json"),
            "{\"info\":{\"id\":\"0199-grok-uuid\",\"cwd\":\"/tmp/gproj\"},\"generated_title\":\"Grok 会话\",\"created_at\":\"2026-06-18T06:27:07.777Z\",\"current_model_id\":\"grok-build\"}",
        )
        .unwrap();
        // …and a stray sidecar jsonl the codex walker must NOT sweep into a session row
        fs::write(gdir.join("events.jsonl"), "{\"ts\":\"x\",\"type\":\"mcp_config_resolved\"}\n").unwrap();

        // copilot: session-state/<uuid>/events.jsonl + workspace.yaml
        let cdir = base.join("session-state").join("cp-uuid-1");
        fs::create_dir_all(&cdir).unwrap();
        fs::write(
            cdir.join("events.jsonl"),
            "{\"type\":\"session.start\",\"data\":{\"sessionId\":\"cp-uuid-1\",\"context\":{\"cwd\":\"/tmp/cproj\"}},\"timestamp\":\"2026-07-12T07:26:54.363Z\"}\n\
             {\"type\":\"user.message\",\"data\":{\"content\":\"copilot needle pelican\"},\"timestamp\":\"2026-07-12T07:27:14.463Z\"}\n",
        )
        .unwrap();
        fs::write(
            cdir.join("workspace.yaml"),
            "id: cp-uuid-1\ncwd: /tmp/cproj\nname: Copilot 会话\ncreated_at: 2026-07-12T07:26:54.368Z\n",
        )
        .unwrap();

        // antigravity: conversations/<uuid>.db with one user step (hand-encoded wire format)
        let adir = base.join("conversations");
        fs::create_dir_all(&adir).unwrap();
        let adb = adir.join("agy-uuid-1.db");
        {
            fn enc_varint(mut v: u64, out: &mut Vec<u8>) {
                loop {
                    let b = (v & 0x7f) as u8;
                    v >>= 7;
                    if v == 0 {
                        out.push(b);
                        break;
                    }
                    out.push(b | 0x80);
                }
            }
            fn put_varint(field: u32, v: u64, out: &mut Vec<u8>) {
                enc_varint(((field as u64) << 3) | 0, out);
                enc_varint(v, out);
            }
            fn put_bytes(field: u32, data: &[u8], out: &mut Vec<u8>) {
                enc_varint(((field as u64) << 3) | 2, out);
                enc_varint(data.len() as u64, out);
                out.extend_from_slice(data);
            }
            let mut ts = vec![];
            put_varint(1, 1_783_811_237, &mut ts);
            let mut meta5 = vec![];
            put_bytes(1, &ts, &mut meta5);
            let mut u19 = vec![];
            put_bytes(2, "agy needle capybara".as_bytes(), &mut u19);
            let mut step = vec![];
            put_varint(1, 14, &mut step);
            put_varint(4, 3, &mut step);
            put_bytes(5, &meta5, &mut step);
            put_bytes(19, &u19, &mut step);
            let conn = rusqlite::Connection::open(&adb).unwrap();
            conn.execute_batch(
                "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER NOT NULL DEFAULT 0, status INTEGER NOT NULL DEFAULT 0, step_payload BLOB);",
            )
            .unwrap();
            conn.execute("INSERT INTO steps (idx, step_type, status, step_payload) VALUES (0, 14, 3, ?1)", [&step])
                .unwrap();
        }
        {
            let conn = rusqlite::Connection::open(base.join("conversation_summaries.db")).unwrap();
            conn.execute_batch(
                "CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', preview TEXT NOT NULL DEFAULT '', step_count INTEGER NOT NULL DEFAULT 0, last_modified_time DATETIME, workspace_uris TEXT NOT NULL DEFAULT '[]');",
            )
            .unwrap();
            conn.execute(
                "INSERT INTO conversation_summaries (conversation_id, title, preview, step_count, workspace_uris) VALUES ('agy-uuid-1', 'Agy 会话', 'p', 1, '[\"file:///tmp/aproj\"]')",
                [],
            )
            .unwrap();
        }

        let config = json!({ "historyDirs": [ base.to_string_lossy() ] });
        let rows = list_sessions(&config, "all", 50);
        let by = |src: &str| {
            rows.iter()
                .find(|r| r.get("source").and_then(|v| v.as_str()) == Some(src))
                .unwrap_or_else(|| panic!("no {} row in {:?}", src, rows))
                .clone()
        };
        // exactly one row per source — the grok dir's stray events.jsonl must not add a fourth
        assert_eq!(rows.len(), 3, "rows: {:?}", rows);
        let (g, c, a) = (by("grok"), by("copilot"), by("antigravity"));
        assert_eq!(g["cwd"], "/tmp/gproj");
        assert_eq!(g["title"], "Grok 会话");
        assert_eq!(g["model"], "grok-build");
        assert_eq!(c["cwd"], "/tmp/cproj");
        assert_eq!(c["title"], "Copilot 会话");
        assert_eq!(a["cwd"], "/tmp/aproj");
        assert_eq!(a["title"], "Agy 会话");

        // detail routes through each shaper (assistant name is the renderer's header/stat hook)
        for (row, assistant, first_text) in [
            (&g, "Grok", "grok needle walrus"),
            (&c, "Copilot", "copilot needle pelican"),
            (&a, "Antigravity", "agy needle capybara"),
        ] {
            let file = row["file"].as_str().unwrap();
            let d = get_session(file);
            assert_eq!(d["meta"]["assistant"], assistant);
            assert_eq!(d["messages"][0]["content"][0]["text"], first_text);
            // another tool's live file: delete-forever must refuse and leave it on disk
            let del = delete_session_file(file, &config);
            assert_eq!(del["reason"], "foreign");
            assert!(Path::new(file).is_file());
        }

        // content search reaches every format (agy has no raw-text prefilter path)
        for needle in ["walrus", "pelican", "capybara"] {
            let hits = search_sessions(&config, "all", needle, 10);
            assert_eq!(hits.len(), 1, "search {}: {:?}", needle, hits);
        }

        let _ = fs::remove_dir_all(&base);
    }

    // Qoder writes Claude-like atomic event wrappers plus inline metadata into its own tree.
    // Rows and detail must use that metadata, merge one assistant response's content blocks,
    // retain queued commands as user turns, nest subagents, and remain searchable/exportable.
    #[test]
    fn qoder_sessions_route_end_to_end() {
        let base = std::env::temp_dir().join("ccbud-qoder-route-test");
        let _ = fs::remove_dir_all(&base);
        let root = base.join(".qoder");
        let proj = root.join("projects").join("-tmp-qproj");
        fs::create_dir_all(&proj).unwrap();
        let uuid = "11111111-1111-4111-8111-111111111111";
        let sess = proj.join(format!("{}.jsonl", uuid));
        let records = vec![
            json!({ "type": "agent-setting", "agentSetting": "triage", "entrypoint": "sdk-cli", "sessionId": uuid }),
            json!({ "type": "last-prompt", "sessionId": uuid, "lastPrompt": "last prompt fallback" }),
            json!({ "type": "ai-title", "sessionId": uuid, "aiTitle": "Qoder 会话" }),
            json!({ "type": "workspace-directories", "sessionId": uuid, "directories": ["/tmp/qproj"] }),
            json!({ "type": "runtime-config", "sessionId": uuid, "model": "ultimate", "reasoningEffort": "high" }),
            json!({
                "type": "user", "uuid": "u1", "timestamp": "2026-06-04T09:47:27.966Z",
                "message": { "role": "user", "content": "qoder needle axolotl" },
                "sessionId": uuid, "version": "1.1.13"
            }),
            json!({
                "type": "assistant", "uuid": "a1", "parentUuid": "u1", "timestamp": "2026-06-04T09:47:32.116Z",
                "message": { "id": "msg_1", "type": "message", "role": "assistant", "model": "wire-model", "content": [
                    { "type": "redacted_thinking", "data": "must not render" }
                ]}, "sessionId": uuid
            }),
            json!({
                "type": "assistant", "uuid": "a2", "parentUuid": "a1", "timestamp": "2026-06-04T09:47:32.216Z",
                "message": { "id": "msg_1", "type": "message", "role": "assistant", "content": [
                    { "type": "thinking", "thinking": "considering" }
                ]}, "sessionId": uuid
            }),
            json!({
                "type": "assistant", "uuid": "a3", "parentUuid": "a2", "timestamp": "2026-06-04T09:47:32.316Z",
                "message": { "id": "msg_1", "type": "message", "role": "assistant", "content": [
                    { "type": "text", "text": "done" }
                ]}, "sessionId": uuid
            }),
            json!({
                "type": "assistant", "uuid": "a4", "parentUuid": "a3", "timestamp": "2026-06-04T09:47:32.416Z",
                "message": {
                    "id": "msg_1", "type": "message", "role": "assistant", "stop_reason": "end_turn",
                    "usage": { "input_tokens": 100, "cache_creation_input_tokens": 7, "cache_read_input_tokens": 50, "output_tokens": 30 },
                    "content": [{ "type": "tool_use", "id": "tu1", "name": "Task", "input": {} }]
                }, "sessionId": uuid
            }),
            json!({
                "type": "attachment", "attachment": { "type": "queued_command", "prompt": "queued narwhal follow-up", "commandMode": false },
                "uuid": "u2", "parentUuid": "a4", "timestamp": "2026-06-04T09:47:35.000Z", "sessionId": uuid
            }),
        ];
        let raw = records
            .iter()
            .map(|record| serde_json::to_string(record).unwrap())
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        fs::write(&sess, raw).unwrap();
        let sub = proj.join(uuid).join("subagents");
        fs::create_dir_all(&sub).unwrap();
        fs::write(
            sub.join("agent-q1.jsonl"),
            format!("{{\"type\":\"assistant\",\"isSidechain\":true,\"agentId\":\"q1\",\"message\":{{\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":\"sub quetzal done\"}}]}},\"sessionId\":\"{}\",\"timestamp\":\"2026-06-04T09:47:40.000Z\"}}\n", uuid),
        )
        .unwrap();
        fs::write(
            sub.join("agent-q1.meta.json"),
            "{\"agentType\":\"general-purpose\",\"description\":\"d\",\"toolUseId\":\"tu1\"}",
        )
        .unwrap();

        let config = json!({ "historyDirs": [ root.to_string_lossy() ] });
        let rows = list_sessions(&config, "all", 50);
        assert_eq!(rows.len(), 1, "rows: {:?}", rows);
        let r = &rows[0];
        assert_eq!(r["source"], "qoder");
        assert_eq!(r["id"], format!("qoder:{}", uuid));
        assert_eq!(r["title"], "Qoder 会话");
        assert_eq!(r["autoTitle"], "Qoder 会话");
        assert_eq!(r["cwd"], "/tmp/qproj");
        assert_eq!(r["model"], "ultimate");
        assert_eq!(r["deleted"], false);

        let file = r["file"].as_str().unwrap();
        let d = get_session(file);
        assert_eq!(d["meta"]["assistant"], "Qoder");
        assert_eq!(d["meta"]["source"], "qoder");
        assert_eq!(d["meta"]["id"], format!("qoder:{}", uuid));
        assert_eq!(d["meta"]["title"], "Qoder 会话");
        assert_eq!(d["meta"]["model"], "ultimate");
        assert_eq!(d["meta"]["subagentCount"], 1);
        assert_eq!(d["messages"].as_array().unwrap().len(), 3);
        assert_eq!(d["messages"][0]["content"], "qoder needle axolotl"); // string-content user turn
        let assistant_blocks = d["messages"][1]["content"].as_array().unwrap();
        assert_eq!(
            assistant_blocks
                .iter()
                .filter_map(|block| block.get("type").and_then(Value::as_str))
                .collect::<Vec<_>>(),
            vec!["thinking", "text", "tool_use"]
        );
        assert_eq!(d["messages"][1]["usage"]["inputTokens"], 100);
        assert_eq!(d["messages"][1]["stopReason"], "end_turn");
        assert_eq!(d["messages"][2]["role"], "user");
        assert_eq!(d["messages"][2]["content"], "queued narwhal follow-up");
        assert_eq!(d["subagents"]["tu1"]["messages"][0]["content"][0]["text"], "sub quetzal done");

        // another tool's live file: delete-forever must refuse and leave it on disk
        let del = delete_session_file(file, &config);
        assert_eq!(del["reason"], "foreign");
        assert!(Path::new(file).is_file());

        // content search reaches the main thread and the subagent transcript
        let hits = search_sessions(&config, "all", "axolotl", 10);
        assert_eq!(hits.len(), 1, "{:?}", hits);
        assert_eq!(hits[0]["agent"], "main");
        let hits = search_sessions(&config, "all", "narwhal", 10);
        assert_eq!(hits.len(), 1, "{:?}", hits);
        assert_eq!(hits[0]["agent"], "main");
        let hits = search_sessions(&config, "all", "quetzal", 10);
        assert_eq!(hits.len(), 1, "{:?}", hits);
        assert_eq!(hits[0]["agent"], "tu1");

        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn session_read_errors_are_structured() {
        let base = std::env::temp_dir().join(format!(
            "ccbud-session-read-error-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&base);
        let project = base.join(".qoder").join("projects").join("-tmp-error");
        fs::create_dir_all(&project).unwrap();

        let missing = project.join("missing.jsonl");
        let detail = get_session(&missing.to_string_lossy());
        assert_eq!(detail["error"]["kind"], "notFound");

        let invalid = project.join("invalid.jsonl");
        fs::write(&invalid, [0xff, 0xfe]).unwrap();
        let detail = get_session(&invalid.to_string_lossy());
        assert_eq!(detail["error"]["kind"], "readFailed");

        let denied = session_read_error(
            &invalid,
            &std::io::Error::new(std::io::ErrorKind::PermissionDenied, "denied"),
        );
        assert_eq!(denied["error"]["kind"], "permissionDenied");

        let _ = fs::remove_dir_all(&base);
    }

    // The Rust search extractor and the renderer's stripInjected must agree: a task-notification
    // envelope surfaces only its <result> body — transport metadata must never be searchable.
    #[test]
    fn strip_injected_unwraps_task_notifications() {
        let s = strip_injected(
            "before <task-notification id=\"t1\">\n<status>completed</status>\n<summary>transport-noise</summary>\n<result>\nDone **ok**\n</result>\n</task-notification> after",
        );
        assert!(s.contains("before") && s.contains("after"));
        assert!(s.contains("Done **ok**"));
        assert!(!s.contains("transport-noise"));
        assert!(!s.contains("task-notification"));
        // an envelope without a <result> vanishes wholesale, like a system-reminder
        let gone = strip_injected("x <task-notification><status>running</status></task-notification> y");
        assert!(gone.contains('x') && gone.contains('y') && !gone.contains("running"));
        // the pre-existing rules still apply after the unwrap
        assert_eq!(strip_injected("hi<system-reminder>meta</system-reminder>"), "hi");
        // a standalone Codex <skill> injection vanishes; quoting one alongside prose does not
        assert_eq!(strip_injected("  <skill name=\"x\">skill-body</skill>\n"), "");
        assert!(strip_injected("see <skill>quoted</skill> here").contains("quoted"));
    }

    // The Codex AGENTS bootstrap must index as the SAME compact Markdown the panel renders
    // (formatCodexBootstrap parity) — not as the raw XML-ish transport shape.
    #[test]
    fn strip_injected_formats_codex_bootstrap_like_the_panel() {
        let raw = "# AGENTS.md instructions for /work/proj\n\n<INSTRUCTIONS>\nAlways run tests.\n</INSTRUCTIONS>\n\n<environment_context>\n  <cwd>/work/proj</cwd>\n  <shell>zsh</shell>\n  <root>/work/proj</root>\n  <permission_profile type=\"workspace-write\" />\n</environment_context>";
        let s = strip_injected(raw);
        assert!(s.starts_with("# AGENTS.md instructions for /work/proj"), "{s}");
        assert!(s.contains("**INSTRUCTIONS:** Always run tests."), "{s}");
        assert!(s.contains("**environment_context:** `/work/proj`"), "{s}");
        assert!(s.contains("**shell:** zsh"), "{s}");
        assert!(s.contains("**workspace_roots:** `/work/proj`"), "{s}");
        assert!(s.contains("**permission_profile:** workspace-write"), "{s}");
        assert!(!s.contains("<INSTRUCTIONS") && !s.contains("<environment_context"), "{s}");
        // multi-line instructions keep their block form
        let multi = strip_injected("# AGENTS.md instructions for /p\n<INSTRUCTIONS>\na\nb\n</INSTRUCTIONS>");
        assert!(multi.contains("**INSTRUCTIONS:**\n\na\nb"), "{multi}");
        // ordinary prose is untouched
        assert_eq!(strip_injected("ordinary prose"), "ordinary prose");
    }

    // Imported qoder content is rewritten to Claude shape (wrappers merged, queued commands
    // materialized) with qoder's own title carried onto __ccbud__; Claude content passes through.
    #[test]
    fn qoder_imports_are_normalized_with_title() {
        let recs = vec![
            json!({ "type": "ai-title", "aiTitle": "Qoder 导入标题" }),
            json!({ "type": "assistant", "uuid": "w1", "message": { "id": "m1", "role": "assistant", "content": [{ "type": "thinking", "thinking": "t" }] } }),
            json!({ "type": "assistant", "uuid": "w2", "message": { "id": "m1", "role": "assistant", "content": [{ "type": "text", "text": "done" }] } }),
            json!({ "type": "attachment", "attachment": { "type": "queued_command", "prompt": "queued prompt" } }),
        ];
        let (text, normalized) = qoder_import_raw(&recs).expect("sniffs as qoder");
        let assistants: Vec<&Value> = normalized.iter().filter(|r| r["type"] == "assistant").collect();
        assert_eq!(assistants.len(), 1, "wrappers merged: {:?}", normalized);
        assert_eq!(assistants[0]["message"]["content"].as_array().unwrap().len(), 2);
        assert!(normalized
            .iter()
            .any(|r| r["type"] == "user" && r["message"]["content"] == "queued prompt"));
        let first: Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
        assert_eq!(first["__ccbud__"]["title"], "Qoder 导入标题");
        assert!(qoder_import_raw(&[json!({ "type": "user", "message": { "content": "hi" } })]).is_none());
    }

    // A live Codex rollout (a work dir's sessions/ tree, no .import.json) must NEVER be hard-deleted
    // by "delete forever" — it's another tool's file. delete_session_file must refuse and leave it on
    // disk. A Claude session in the same dir's projects/ tree is still deletable.
    #[test]
    fn delete_forever_refuses_live_codex_rollout() {
        let base = std::env::temp_dir().join("ccbud-codex-del-test");
        let _ = fs::remove_dir_all(&base);
        // codex rollout under <base>/sessions/…
        let sdir = base.join("sessions").join("2026").join("07").join("04");
        fs::create_dir_all(&sdir).unwrap();
        let codex_file = sdir.join("rollout-x.jsonl");
        fs::write(
            &codex_file,
            "{\"timestamp\":\"2026-07-04T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"x\",\"cwd\":\"/x\"}}\n\
             {\"timestamp\":\"2026-07-04T00:00:01Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}}\n",
        )
        .unwrap();
        // claude session under <base>/projects/…
        let pdir = base.join("projects").join("-x");
        fs::create_dir_all(&pdir).unwrap();
        let claude_file = pdir.join("s1.jsonl");
        fs::write(&claude_file, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"},\"cwd\":\"/x\",\"sessionId\":\"s1\"}\n").unwrap();

        let config = json!({ "historyDirs": [ base.to_string_lossy() ] });

        // live codex → refused, file survives
        let r = delete_session_file(&codex_file.to_string_lossy(), &config);
        assert_eq!(r.get("reason").and_then(|v| v.as_str()), Some("foreign"), "live codex must be refused");
        assert!(codex_file.is_file(), "codex rollout must NOT be deleted");

        // claude session → deleted
        let r2 = delete_session_file(&claude_file.to_string_lossy(), &config);
        assert_eq!(r2.get("ok").and_then(|v| v.as_bool()), Some(true));
        assert!(!claude_file.is_file(), "claude session should be gone");

        let _ = fs::remove_dir_all(&base);
    }

    // Export a session-with-subagents and prove the .zip splits back into the main session + both
    // subagent sidecars (the shape import_zip then writes into the store). Avoids mutating CCBUD_HOME
    // so it can't race other threads under `cargo test`; the store round-trip is covered by the
    // in-app import_selftest and confirms in review via write_imported (shared with import_one).
    #[test]
    fn export_bundle_round_trips_through_split() {
        let base = std::env::temp_dir().join("ccbud-bundle-test");
        let _ = fs::remove_dir_all(&base);
        let proj = base.join("projects").join("-bnd-cwd");
        fs::create_dir_all(&proj).unwrap();
        let main = proj.join("bundsess.jsonl");
        fs::write(&main, "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"tu9\",\"name\":\"Task\",\"input\":{}}]},\"cwd\":\"/bnd/cwd\",\"sessionId\":\"bundsess\",\"timestamp\":\"2025-01-01T10:00:00.000Z\"}\n").unwrap();
        let sub = proj.join("bundsess").join("subagents");
        fs::create_dir_all(&sub).unwrap();
        fs::write(sub.join("agent-b1.jsonl"), "{\"type\":\"assistant\",\"isSidechain\":true,\"agentId\":\"b1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"sub done\"}]},\"sessionId\":\"bundsess\",\"timestamp\":\"2025-01-01T10:00:01.000Z\"}\n").unwrap();
        fs::write(sub.join("agent-b1.meta.json"), "{\"agentType\":\"general-purpose\",\"description\":\"d\",\"toolUseId\":\"tu9\"}").unwrap();

        assert!(session_has_subagents(&main.to_string_lossy()));

        let zip = export_bundle(&main.to_string_lossy()).unwrap();
        assert!(zip.starts_with(&[0x50, 0x4b, 0x03, 0x04]), "starts with PK local header");

        let (m, subs) = crate::ziputil::split_bundle(crate::ziputil::read(&zip));
        assert_eq!(m.as_ref().map(|(n, _)| n.as_str()), Some("bundsess.jsonl"));
        assert_eq!(subs.len(), 2);
        assert!(subs.iter().any(|(n, d)| n == "agent-b1.jsonl" && String::from_utf8_lossy(d).contains("sub done")));
        assert!(subs.iter().any(|(n, _)| n == "agent-b1.meta.json"));

        let _ = fs::remove_dir_all(&base);
    }

    // The list is ordered by the session's FIRST RECORD TIMESTAMP, not fs times — a title/tag
    // edit rewrites the file via tmp+rename (which resets its fs birth time to "now") and must
    // NOT reshuffle the list.
    #[test]
    fn list_order_survives_title_and_tag_edits() {
        let base = std::env::temp_dir().join("ccbud-order-test");
        let _ = fs::remove_dir_all(&base);
        let proj = base.join("projects").join("-ord-cwd");
        fs::create_dir_all(&proj).unwrap();
        let older = proj.join("older.jsonl");
        let newer = proj.join("newer.jsonl");
        fs::write(&older, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"old one\"},\"cwd\":\"/ord/cwd\",\"sessionId\":\"older\",\"timestamp\":\"2025-01-01T10:00:00.000Z\"}\n").unwrap();
        fs::write(&newer, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"new one\"},\"cwd\":\"/ord/cwd\",\"sessionId\":\"newer\",\"timestamp\":\"2025-06-01T10:00:00.000Z\"}\n").unwrap();
        let config = json!({ "historyDirs": [ base.to_string_lossy() ] });
        let order = |cfg: &Value| -> Vec<String> {
            list_sessions(cfg, "all", 50)
                .iter()
                .filter(|s| s.get("cwd").and_then(|v| v.as_str()) == Some("/ord/cwd"))
                .map(|s| s.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string())
                .collect()
        };
        assert_eq!(order(&config), vec!["newer", "older"], "newest record time first");

        // Rename + tag the OLDER session: the file is rewritten through a fresh tmp inode, yet
        // the list order must not change.
        let r = set_ccbud(&older.to_string_lossy(), &json!({ "title": "Renamed", "tags": ["pinned"] }), &config);
        assert_eq!(r.get("ok").and_then(|v| v.as_bool()), Some(true));
        assert_eq!(order(&config), vec!["newer", "older"], "tag/title edit must not reshuffle");

        // And the row's createdAt still reflects the record timestamp, not the rewrite moment,
        // while the edited title shows up immediately (list-meta memo invalidated by the write).
        let rows = list_sessions(&config, "all", 50);
        let row = rows.iter().find(|s| s.get("sessionId").and_then(|v| v.as_str()) == Some("older")).unwrap();
        let want = chrono::DateTime::parse_from_rfc3339("2025-01-01T10:00:00.000Z").unwrap().timestamp_millis() as f64;
        assert_eq!(row.get("createdAt").and_then(|v| v.as_f64()), Some(want));
        assert_eq!(row.get("title").and_then(|v| v.as_str()), Some("Renamed"));

        let _ = fs::remove_dir_all(&base);
    }

    // Content search: a main-thread hit reports agent "main"; a subagent-only hit reports the
    // spawning tool_use key (+ agent type); injected <system-reminder> text never matches; and
    // ASCII case folds. Runs twice so the second pass exercises the extraction cache.
    #[test]
    fn search_sessions_finds_main_and_subagent_content() {
        let base = std::env::temp_dir().join("ccbud-search-test");
        let _ = fs::remove_dir_all(&base);
        let proj = base.join("projects").join("-srch-cwd");
        fs::create_dir_all(&proj).unwrap();
        let main = proj.join("srchsess.jsonl");
        fs::write(
            &main,
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"find the zebra crossing<system-reminder>reminder-secret</system-reminder>\"},\"cwd\":\"/srch/cwd\",\"sessionId\":\"srchsess\",\"timestamp\":\"2025-01-01T10:00:00.000Z\"}\n\
             {\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"tu1\",\"name\":\"Task\",\"input\":{}}]},\"sessionId\":\"srchsess\",\"timestamp\":\"2025-01-01T10:00:01.000Z\"}\n",
        )
        .unwrap();
        let sub = proj.join("srchsess").join("subagents");
        fs::create_dir_all(&sub).unwrap();
        fs::write(
            sub.join("agent-s1.jsonl"),
            "{\"type\":\"assistant\",\"isSidechain\":true,\"agentId\":\"s1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"the quokka was found here\"}]},\"sessionId\":\"srchsess\",\"timestamp\":\"2025-01-01T10:00:02.000Z\"}\n",
        )
        .unwrap();
        fs::write(sub.join("agent-s1.meta.json"), "{\"agentType\":\"explore\",\"description\":\"d\",\"toolUseId\":\"tu1\"}").unwrap();
        // Content stored as \uXXXX escapes (e.g. python json.dumps output) — a byte scan can't
        // see the decoded text, so non-ASCII queries must bypass the raw prefilter.
        let esc = proj.join("escsess.jsonl");
        fs::write(
            &esc,
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\\u4e2d\\u6587\\u5185\\u5bb9 escaped\"},\"cwd\":\"/srch/cwd\",\"sessionId\":\"escsess\",\"timestamp\":\"2025-01-02T10:00:00.000Z\"}\n",
        )
        .unwrap();
        // A codex rollout in the same work dir's sessions/ tree — its own record format, scanned
        // through the codex shaper.
        let cdir = base.join("sessions").join("2026").join("07").join("04");
        fs::create_dir_all(&cdir).unwrap();
        fs::write(
            cdir.join("rollout-c.jsonl"),
            "{\"timestamp\":\"2026-07-04T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"c1\",\"cwd\":\"/cx\"}}\n\
             {\"timestamp\":\"2026-07-04T00:00:01Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"codex kangaroo request\"}]}}\n",
        )
        .unwrap();
        let config = json!({ "historyDirs": [ base.to_string_lossy() ] });

        for pass in 0..2 {
            // main-thread hit
            let hits = search_sessions(&config, "all", "zebra crossing", 50);
            assert_eq!(hits.len(), 1, "pass {}: one session matches", pass);
            assert_eq!(hits[0].get("agent").and_then(|v| v.as_str()), Some("main"));
            assert!(hits[0].get("snippet").and_then(|v| v.as_str()).unwrap_or("").contains("zebra"));

            // subagent-only hit → keyed by the spawning tool_use id, labeled with the agent type
            let hits = search_sessions(&config, "all", "QUOKKA", 50); // also proves case folding
            assert_eq!(hits.len(), 1);
            assert_eq!(hits[0].get("agent").and_then(|v| v.as_str()), Some("tu1"));
            assert_eq!(hits[0].get("agentType").and_then(|v| v.as_str()), Some("explore"));

            // codex rollout content is searchable too
            let hits = search_sessions(&config, "all", "kangaroo", 50);
            assert_eq!(hits.len(), 1, "pass {}: codex rollout matches", pass);
            assert_eq!(hits[0].get("agent").and_then(|v| v.as_str()), Some("main"));

            // \uXXXX-escaped content still matches a non-ASCII query (no raw prefilter for those)
            let hits = search_sessions(&config, "all", "中文", 50);
            assert_eq!(hits.len(), 1, "pass {}: escaped unicode content matches", pass);
            assert!(hits[0].get("snippet").and_then(|v| v.as_str()).unwrap_or("").contains("中文内容"));

            // injected system-reminder content is NOT searchable (matches the renderer)
            assert!(search_sessions(&config, "all", "reminder-secret", 50).is_empty());
            // no match at all
            assert!(search_sessions(&config, "all", "wombat", 50).is_empty());
        }

        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn subagent_transcript_paths_lists_only_agent_jsonl() {
        let base = std::env::temp_dir().join("ccbud-subpaths-test");
        let _ = fs::remove_dir_all(&base);
        let proj = base.join("projects").join("-m-cwd");
        fs::create_dir_all(&proj).unwrap();
        let main = proj.join("m.jsonl");
        fs::write(&main, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"},\"sessionId\":\"m\"}\n").unwrap();
        // no subagents → empty (caller attaches only the main file)
        assert!(subagent_transcript_paths(&main.to_string_lossy()).is_empty());

        let sub = proj.join("m").join("subagents");
        fs::create_dir_all(&sub).unwrap();
        fs::write(sub.join("agent-a.jsonl"), "{}\n").unwrap();
        fs::write(sub.join("agent-b.jsonl"), "{}\n").unwrap();
        fs::write(sub.join("agent-a.meta.json"), "{}").unwrap(); // sidecar must be excluded

        let paths = subagent_transcript_paths(&main.to_string_lossy());
        assert_eq!(paths.len(), 2, "only the two agent-*.jsonl, not the .meta.json");
        assert!(paths.iter().all(|p| p.ends_with(".jsonl")));
        assert!(paths.iter().any(|p| p.ends_with("agent-a.jsonl")));
        assert!(paths.iter().any(|p| p.ends_with("agent-b.jsonl")));

        let _ = fs::remove_dir_all(&base);
    }
}
