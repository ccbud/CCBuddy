// The run-once startup migrations that add each detected coding CLI's data dir to historyDirs.
// Moved verbatim from store.rs.

use serde_json::json;
use std::path::PathBuf;

use super::io::{read_config, write_config};
use super::paths::collapse_home;

/// One-time startup migration: when a Codex install exists (its sessions tree is on disk),
/// add its config dir (`~/.codex`, CODEX_HOME-aware) to historyDirs so Codex conversations
/// appear in 对话 like any other work dir. The `codexDirAutoAdded` flag makes this run once —
/// a user who later REMOVES the dir isn't fighting an auto-re-add. Returns true if it changed
/// the config (caller refreshes the history views). Mirrors main.js ensureCodexDir.
pub fn ensure_codex_dir() -> bool {
    let mut cfg = read_config();
    if cfg.get("codexDirAutoAdded").and_then(|v| v.as_bool()).unwrap_or(false) {
        return false;
    }
    if !crate::codex::root_exists() {
        return false; // no Codex install yet — keep probing on future launches
    }
    let label = crate::codex::codex_label();
    let obj = cfg.as_object_mut().unwrap();
    let mut dirs: Vec<String> = obj
        .get("historyDirs")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|d| d.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default();
    if !dirs.iter().any(|d| *d == label) {
        dirs.push(label);
    }
    obj.insert("historyDirs".into(), json!(dirs));
    obj.insert("codexDirAutoAdded".into(), json!(true));
    write_config(cfg);
    true
}

/// Shared body of the ensure_*_dir migrations: when `exists` and the run-once `flag` hasn't
/// fired, add `label` to historyDirs (dedup) and set the flag. Returns true when the config
/// changed (caller refreshes the history views). A user who later REMOVES the dir isn't
/// fighting an auto-re-add; a missing install keeps probing on future launches.
fn ensure_history_dir(flag: &str, exists: bool, label: String) -> bool {
    let mut cfg = read_config();
    if cfg.get(flag).and_then(|v| v.as_bool()).unwrap_or(false) {
        return false;
    }
    if !exists {
        return false; // nothing there yet — keep probing on future launches
    }
    let obj = cfg.as_object_mut().unwrap();
    let mut dirs: Vec<String> = obj
        .get("historyDirs")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|d| d.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default();
    if !dirs.iter().any(|d| *d == label) {
        dirs.push(label);
    }
    obj.insert("historyDirs".into(), json!(dirs));
    obj.insert(flag.into(), json!(true));
    write_config(cfg);
    true
}

/// One-time startup migrations for the other coding CLIs whose sessions the 对话 view can
/// browse: Grok Build (~/.grok, GROK_HOME-aware), GitHub Copilot CLI (~/.copilot), and the
/// Antigravity CLI (~/.gemini/antigravity-cli). Same run-once contract as ensure_codex_dir.
pub fn ensure_grok_dir() -> bool {
    ensure_history_dir("grokDirAutoAdded", crate::grok::root_exists(), crate::grok::grok_label())
}

pub fn ensure_copilot_dir() -> bool {
    ensure_history_dir("copilotDirAutoAdded", crate::copilot::root_exists(), crate::copilot::copilot_label())
}

pub fn ensure_antigravity_dir() -> bool {
    ensure_history_dir("antigravityDirAutoAdded", crate::antigravity::root_exists(), crate::antigravity::agy_label())
}

/// Qoder writes Claude-format sessions under two known roots (~/.qoder and ~/.qoderwork) —
/// each detected root joins historyDirs once, under its own run-once flag.
pub fn ensure_qoder_dir() -> bool {
    let mut changed = false;
    for (flag, root) in
        [("qoderDirAutoAdded", crate::qoder::default_root()), ("qoderworkDirAutoAdded", crate::qoder::work_root())]
    {
        changed |= ensure_history_dir(flag, crate::qoder::root_exists(&root), collapse_home(&root.to_string_lossy()));
    }
    changed
}

/// One-time startup migration (ccusage parity): Claude Code also writes history under the XDG
/// config dir (`$XDG_CONFIG_HOME/claude`, default `~/.config/claude`) — when that tree exists,
/// add it to historyDirs so its sessions count toward conversations and usage. Same run-once
/// contract as ensure_codex_dir.
pub fn ensure_xdg_claude_dir() -> bool {
    let mut cfg = read_config();
    if cfg.get("xdgClaudeDirAutoAdded").and_then(|v| v.as_bool()).unwrap_or(false) {
        return false;
    }
    let base = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from("."))
                .join(".config")
        });
    let dir = base.join("claude");
    if !dir.join("projects").is_dir() {
        return false; // nothing there yet — keep probing on future launches
    }
    let label = dir.to_string_lossy().to_string();
    let obj = cfg.as_object_mut().unwrap();
    let mut dirs: Vec<String> = obj
        .get("historyDirs")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|d| d.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default();
    if !dirs.iter().any(|d| *d == label) {
        dirs.push(label);
    }
    obj.insert("historyDirs".into(), json!(dirs));
    obj.insert("xdgClaudeDirAutoAdded".into(), json!(true));
    write_config(cfg);
    true
}
