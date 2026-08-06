use std::path::{Path, PathBuf};

use super::jsonl::{mtime_ms, parse_lines, read_head};
use super::session::read_import_meta;
use super::text::read_ccbud;

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
pub(super) fn is_session_deleted(file: &Path) -> bool {
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

/// Freshness stamp for the list-meta / search caches: plain mtime, except Antigravity DBs
/// where a live agy writes into the WAL without touching the main file.
pub(super) fn cache_stamp_ms(file: &Path) -> f64 {
    match foreign_kind(file) {
        Some(Foreign::Antigravity) => crate::antigravity::wal_mtime_ms(file),
        _ => mtime_ms(file),
    }
}
