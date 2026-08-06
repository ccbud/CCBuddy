use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

use super::jsonl::{parse_lines, read_session_bytes, read_session_text};
use super::norm::shape_messages;
use super::skills::skill_from_recs;

/// Read a session's child subagent dialogues from `<stem>/subagents/agent-*.jsonl` (+ .meta.json),
/// keyed by the spawning tool_use id so the renderer can nest them. {} when none. (history.js readSubagents)
pub(super) fn read_subagents(file: &str) -> serde_json::Map<String, Value> {
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
pub(super) fn subagent_dir(file: &Path) -> Option<PathBuf> {
    let stem = file.file_stem().and_then(|s| s.to_str())?;
    file.parent().map(|d| d.join(stem).join("subagents"))
}

/// The raw subagent sidecar files for a session — `(agent-*.jsonl | agent-*.meta.json, bytes)`.
/// Empty when the session spawned no subagents. Shared by bundle export, import, and replay-merge.
pub(super) fn read_subagent_files(file: &Path) -> Vec<(String, Vec<u8>)> {
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
