use serde_json::{json, Value};

use super::text::content_text;

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
