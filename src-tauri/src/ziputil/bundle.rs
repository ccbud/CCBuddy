// Conversation-bundle shape: the FIRST level holds the main session .jsonl and `subagents/`
// holds the per-subagent files. split_bundle recovers that layout from a flat entry list.

use super::write::Entry;

fn norm(name: &str) -> String {
    name.replace('\\', "/").trim_start_matches("./").to_string()
}
fn in_subagents(name: &str) -> bool {
    norm(name).split('/').any(|seg| seg == "subagents")
}
fn depth(name: &str) -> usize {
    norm(name).matches('/').count()
}
fn base_name(name: &str) -> String {
    norm(name).split('/').filter(|s| !s.is_empty()).last().unwrap_or("").to_string()
}

/// Split a bundle's entries into (main, subagents), mirroring zipStore.js splitBundle: the main
/// session is the shallowest top-level *.jsonl (never under a subagents/ segment); subagents are the
/// agent-* transcript / meta files under any subagents/ directory. Tolerant of a wrapping folder.
/// Returns (Some((name, data)), Vec<(name, data)>); main is None when no session file is present.
pub fn split_bundle(entries: Vec<Entry>) -> (Option<(String, Vec<u8>)>, Vec<(String, Vec<u8>)>) {
    let mut main: Option<usize> = None;
    for (i, e) in entries.iter().enumerate() {
        if !e.name.to_lowercase().ends_with(".jsonl") || in_subagents(&e.name) {
            continue;
        }
        match main {
            Some(m) if depth(&entries[m].name) <= depth(&e.name) => {}
            _ => main = Some(i),
        }
    }
    let mut subagents: Vec<(String, Vec<u8>)> = Vec::new();
    for e in &entries {
        if !in_subagents(&e.name) {
            continue;
        }
        let base = base_name(&e.name);
        let lower = base.to_lowercase();
        if lower.starts_with("agent-") && (lower.ends_with(".jsonl") || lower.ends_with(".meta.json")) {
            subagents.push((base, e.data.clone()));
        }
    }
    let main_out = main.map(|i| (base_name(&entries[i].name), entries[i].data.clone()));
    (main_out, subagents)
}
