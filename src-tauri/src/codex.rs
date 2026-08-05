// Codex CLI session support — reads OpenAI Codex's on-disk rollout logs
// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) and normalizes them into the SAME
// session/message shape the renderer consumes for Claude Code history, so the 对话 view
// (list / detail / search / live-follow / export) browses both without renderer forks.
//
// A rollout line is `{timestamp, type, payload}` with type ∈ {session_meta, turn_context,
// response_item, event_msg, compacted}. Conversation content lives in response_item payloads
// (message / reasoning / function_call / function_call_output / local_shell_call /
// custom_tool_call / web_search_call); event_msg mostly duplicates that content, but token_count
// carries usage and user_message supplies a bounded title fallback for image-heavy first turns.
// Very old Codex builds wrote
// payload objects directly per line (no envelope) — handled by treating such a line as its
// own payload.
//
// Tool calls are mapped onto the tool vocabulary the renderer already draws natively:
// shell/exec_command/local_shell_call → Bash, update_plan → TodoWrite, view_image → Read,
// web_search → WebSearch, apply_patch → ApplyPatch (a codex-specific card).
//
// Title/tags/soft-delete: Codex files belong to another tool, so per-conversation
// customization never rewrites them (unlike Claude's in-file `__ccbud__`) — it lives in a
// sidecar map at `~/.ccbud/codex-meta.json`, keyed by the rollout file stem.

#![allow(dead_code)]

use crate::history::{image_block, Norm};
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

/// The DEFAULT config dir as a history-dir entry string (`~/.codex`), used by the one-time
/// startup migration that adds it to `historyDirs`. Honors CODEX_HOME like the codex CLI.
pub fn codex_label() -> String {
    let root = sessions_root();
    let dir = root.parent().unwrap_or(&root);
    crate::store::collapse_home(&dir.to_string_lossy())
}

fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

/// Codex's DEFAULT sessions tree. Honors CODEX_HOME the way the codex CLI does. Only the
/// auto-add migration keys off this — browsing walks `<dir>/sessions` of every configured dir.
pub fn sessions_root() -> PathBuf {
    match std::env::var("CODEX_HOME") {
        Ok(h) if !h.trim().is_empty() => PathBuf::from(h).join("sessions"),
        _ => home().join(".codex").join("sessions"),
    }
}

pub fn root_exists() -> bool {
    sessions_root().is_dir()
}

fn codex_home_for_rollout(file: &Path) -> Option<PathBuf> {
    file.ancestors()
        .find(|dir| {
            matches!(
                dir.file_name().and_then(|name| name.to_str()),
                Some("sessions") | Some("archived_sessions")
            )
        })
        .and_then(Path::parent)
        .map(Path::to_path_buf)
}

fn resolve_sqlite_home_path(raw: &str, codex_home: &Path) -> Option<PathBuf> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    if raw == "~" {
        return Some(home());
    }
    if let Some(rest) = raw.strip_prefix("~/") {
        return Some(home().join(rest));
    }
    let path = PathBuf::from(raw);
    Some(if path.is_absolute() { path } else { codex_home.join(path) })
}

fn configured_sqlite_home(codex_home: &Path) -> Option<PathBuf> {
    let raw = fs::read_to_string(codex_home.join("config.toml")).ok()?;
    let doc = raw.parse::<toml_edit::DocumentMut>().ok()?;
    resolve_sqlite_home_path(doc.get("sqlite_home")?.as_str()?, codex_home)
}

/// Codex treats the completed state DB's rollout_path as authoritative for a canonical thread id.
/// This is intentionally queried only when ccbud has found duplicate physical candidates, so the
/// normal list walk never opens SQLite per row. A missing/stale/incomplete DB simply means callers
/// fall back to validated metadata + mtime, just as Codex does during scan-and-repair.
pub fn preferred_rollout_path(file: &Path, thread_id: &str) -> Option<PathBuf> {
    let codex_home = codex_home_for_rollout(file)?;
    let sqlite_home = configured_sqlite_home(&codex_home)
        .or_else(|| {
            std::env::var("CODEX_SQLITE_HOME")
                .ok()
                .and_then(|value| resolve_sqlite_home_path(&value, &codex_home))
        })
        .unwrap_or(codex_home);
    let db = sqlite_home.join("state_5.sqlite");
    if !db.is_file() {
        return None;
    }
    let conn = Connection::open_with_flags(
        db,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    let status = conn
        .query_row(
            "SELECT status FROM backfill_state WHERE id = 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .ok()??;
    if status != "complete" {
        return None;
    }
    let rollout = conn
        .query_row(
            "SELECT rollout_path FROM threads WHERE id = ?1 AND archived = 0",
            [thread_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .ok()??;
    let rollout = PathBuf::from(rollout);
    rollout.is_file().then_some(rollout)
}

/// Walk every rollout .jsonl under a sessions tree (date-sharded YYYY/MM/DD, but walked
/// generically so a layout change doesn't lose sessions). Depth-capped against cycles.
pub fn walk_sessions<F: FnMut(PathBuf)>(root: &Path, mut cb: F) {
    fn walk<F: FnMut(PathBuf)>(dir: &Path, depth: u32, cb: &mut F) {
        if depth > 6 {
            return;
        }
        let entries = match fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return,
        };
        for ent in entries.flatten() {
            let p = ent.path();
            if p.is_dir() {
                walk(&p, depth + 1, cb);
            } else if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                cb(p);
            }
        }
    }
    walk(root, 0, &mut cb);
}

/// Format sniff on parsed records — routes files that LOOK like Codex rollouts (incl. copies
/// imported into the app store, where the path no longer says so). Claude Code records never
/// use these type tags, and old-format bare Codex items lack Claude's `.message` wrapper.
pub fn looks_codex(recs: &[Value]) -> bool {
    recs.iter().take(8).any(|r| {
        match r.get("type").and_then(|v| v.as_str()) {
            Some("session_meta") | Some("turn_context") | Some("event_msg") | Some("compacted") => true,
            Some("response_item") => r.get("payload").is_some(),
            // old envelope-less rollout: response items at the top level
            Some("message") | Some("function_call") | Some("function_call_output")
            | Some("reasoning") | Some("local_shell_call") => r.get("message").is_none(),
            _ => r.get("record_type").is_some(),
        }
    })
}

/// (type, payload, timestamp) of a rollout line, tolerating the old envelope-less format.
fn split_line(rec: &Value) -> (&str, &Value, Option<&str>) {
    let ts = rec.get("timestamp").and_then(|v| v.as_str());
    let t = rec.get("type").and_then(|v| v.as_str()).unwrap_or("");
    if let Some(p) = rec.get("payload") {
        return (t, p, ts);
    }
    match t {
        "message" | "function_call" | "function_call_output" | "reasoning" | "local_shell_call"
        | "custom_tool_call" | "custom_tool_call_output" | "web_search_call" => ("response_item", rec, ts),
        // old first line: bare SessionMeta {id, timestamp, instructions, cwd?, git?}
        "" if rec.get("id").is_some() && rec.get("timestamp").is_some() => ("session_meta", rec, ts),
        _ => (t, rec, ts),
    }
}

#[derive(Default)]
struct CanonicalThreadMeta {
    thread_id: Option<String>,
    root_session_id: Option<String>,
    parent_thread_id: Option<String>,
    forked_from_id: Option<String>,
    is_subagent: bool,
    agent_path: Option<String>,
    agent_nickname: Option<String>,
    agent_role: Option<String>,
    agent_depth: Option<i64>,
}

// The first SessionMeta is canonical for the physical rollout. Subagent/fork rollouts can copy
// ancestor SessionMeta records behind it, and every thread in that tree intentionally shares the
// same session_id. The unique thread key is the first meta's id.
fn canonical_thread_meta(payload: &Value) -> CanonicalThreadMeta {
    let subagent = payload
        .get("source")
        .and_then(|source| source.get("subagent").or_else(|| source.get("sub_agent")))
        .or_else(|| {
            payload
                .get("thread_source")
                .and_then(|source| source.get("subagent").or_else(|| source.get("sub_agent")))
        });
    let detail = subagent.and_then(|source| {
        ["thread_spawn", "review", "compact", "other"]
            .iter()
            .find_map(|key| source.get(*key).filter(|value| value.is_object()))
            .or_else(|| source.as_object().and_then(|object| object.values().find(|value| value.is_object())))
    });
    let string = |value: Option<&Value>| {
        value
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string)
    };
    let thread_id = string(
        payload
            .get("id")
            .or_else(|| payload.get("thread_id")),
    );
    let root_session_id = string(payload.get("session_id")).or_else(|| thread_id.clone());
    let parent_thread_id = string(
        payload
            .get("parent_thread_id")
            .or_else(|| detail.and_then(|value| value.get("parent_thread_id"))),
    );
    let is_subagent = subagent.is_some()
        || payload.get("thread_source").and_then(Value::as_str) == Some("subagent")
        || payload
            .get("agent_path")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
        || payload
            .get("agent_nickname")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
        || (parent_thread_id.is_some() && thread_id != root_session_id);
    CanonicalThreadMeta {
        thread_id,
        root_session_id,
        parent_thread_id,
        forked_from_id: string(payload.get("forked_from_id")),
        is_subagent,
        // Current Codex stores the canonical Agent identity on SessionMeta itself. Older
        // rollouts only carried it inside source.subagent.<kind>, so keep that as a fallback.
        agent_path: string(
            payload
                .get("agent_path")
                .or_else(|| detail.and_then(|value| value.get("agent_path"))),
        ),
        agent_nickname: string(
            payload
                .get("agent_nickname")
                .or_else(|| detail.and_then(|value| value.get("agent_nickname"))),
        ),
        agent_role: string(
            payload
                .get("agent_role")
                .or_else(|| payload.get("agent_type"))
                .or_else(|| detail.and_then(|value| value.get("agent_role")))
                .or_else(|| detail.and_then(|value| value.get("agent_type"))),
        ),
        agent_depth: detail.and_then(|value| value.get("depth")).and_then(|value| value.as_i64()),
    }
}

/// Harness-injected user turns (environment/permissions/instructions wrappers) that aren't
/// human prose — hidden from the timeline, exactly like Claude's isMeta records.
fn is_meta_user_text(t: &str) -> bool {
    let t = t.trim_start();
    ["<environment_context>", "<user_instructions>", "<permissions", "<ide_", "<turn_context", "<AGENTS", "<workspace_"]
        .iter()
        .any(|p| t.starts_with(p))
}

// The workspace AGENTS bootstrap is user-role transport data. Keep it visible in the transcript
// (the renderer formats it as Markdown), but mark it as metadata so it cannot become the title.
fn is_agents_bootstrap(t: &str) -> bool {
    let source = t.trim_start();
    let Some(heading) = source.strip_prefix('#') else { return false; };
    let heading = heading.trim_start().to_ascii_lowercase();
    heading.starts_with("agents.md instructions for ")
        && heading.contains("<instructions")
        && heading.contains("</instructions>")
}

// Codex serializes a loaded Skill as a synthetic user turn. Keep the snapshot embedded in the
// rollout rather than reading the current SKILL.md from disk: historical sessions must show the
// exact instructions that were loaded at the time. Anchoring the whole envelope leaves quoted
// <skill> markup in normal user prose untouched.
fn skill_load_block(t: &str) -> Option<Value> {
    static SKILL_ENVELOPE_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = SKILL_ENVELOPE_RE.get_or_init(|| {
        regex::Regex::new(
            r"(?is)^\s*<skill>\s*<name>(.*?)</name>\s*<path>(.*?)</path>(.*)</skill>\s*$",
        )
        .unwrap()
    });
    let captures = re.captures(t)?;
    let name = captures.get(1)?.as_str().trim();
    let path = captures.get(2)?.as_str().trim();
    if name.is_empty() || path.is_empty() {
        return None;
    }
    let snapshot = captures.get(3)?.as_str();
    Some(json!({
        "type": "skill_load",
        "name": name,
        "path": path,
        "snapshot": snapshot,
    }))
}

fn joined_text(content: &Value, kinds: &[&str]) -> String {
    let arr = match content.as_array() {
        Some(a) => a,
        None => return content.as_str().unwrap_or("").to_string(),
    };
    arr.iter()
        .filter(|b| kinds.contains(&b.get("type").and_then(|t| t.as_str()).unwrap_or("")))
        .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
        .collect::<Vec<_>>()
        .join("\n")
}

// Codex surrounds each real input_image with text-only transport tags. Replace the opening tag
// with its safe display name (`[Image #1]`) and drop the closing tag; image_block still carries
// the actual bitmap to the renderer.
fn image_transport_label(text: &str) -> Option<String> {
    let source = text.trim();
    let lower = source.to_ascii_lowercase();
    if !lower.starts_with("<image") || !source.ends_with('>') {
        return None;
    }
    let boundary = source.as_bytes().get(6).copied();
    if !matches!(boundary, Some(b'>')) && !boundary.map(|b| b.is_ascii_whitespace()).unwrap_or(false) {
        return None;
    }

    let mut label = None;
    if let Some(pos) = lower.find("name") {
        let rest = source[pos + 4..].trim_start();
        if let Some(value) = rest.strip_prefix('=') {
            let value = value.trim_start();
            label = if let Some(quote) = value.chars().next().filter(|c| *c == '"' || *c == '\'') {
                value[quote.len_utf8()..]
                    .find(quote)
                    .map(|end| value[quote.len_utf8()..quote.len_utf8() + end].to_string())
            } else if value.starts_with('[') {
                value.find(']').map(|end| value[..=end].to_string())
            } else {
                Some(value.split(|c: char| c.is_whitespace() || c == '>').next().unwrap_or("").to_string())
            };
        }
    }
    Some(label.filter(|s| !s.trim().is_empty()).unwrap_or_else(|| "[Image]".to_string()))
}

fn joined_user_text(content: &Value) -> String {
    let arr = match content.as_array() {
        Some(a) => a,
        None => return content.as_str().unwrap_or("").to_string(),
    };
    let has_image = arr
        .iter()
        .any(|b| b.get("type").and_then(|t| t.as_str()) == Some("input_image"));
    arr.iter()
        .filter(|b| matches!(b.get("type").and_then(|t| t.as_str()), Some("input_text") | Some("text")))
        .filter_map(|b| {
            let text = b.get("text").and_then(|t| t.as_str()).unwrap_or("");
            if has_image {
                if text.trim().eq_ignore_ascii_case("</image>") {
                    return None;
                }
                if let Some(label) = image_transport_label(text) {
                    return Some(label);
                }
            }
            if text.is_empty() { None } else { Some(text.to_string()) }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn event_user_display_text(payload: &Value) -> String {
    let message = payload.get("message").and_then(|v| v.as_str()).unwrap_or("").trim();
    let image_count = payload.get("images").and_then(|v| v.as_array()).map(Vec::len).unwrap_or(0)
        + payload.get("local_images").and_then(|v| v.as_array()).map(Vec::len).unwrap_or(0);
    let labels = (1..=image_count)
        .map(|i| format!("[Image #{}]", i))
        .collect::<Vec<_>>()
        .join(" ");
    format!("{}{}{}", labels, if !labels.is_empty() && !message.is_empty() { " " } else { "" }, message)
        .trim()
        .to_string()
}

fn event_user_title_from_record(rec: &Value) -> String {
    let (ty, payload, _) = split_line(rec);
    if ty != "event_msg" || payload.get("type").and_then(|v| v.as_str()) != Some("user_message") {
        return String::new();
    }
    let text = event_user_display_text(payload);
    if text.is_empty() {
        String::new()
    } else {
        crate::history::first_user_text(&[json!({
            "role": "user",
            "content": [{ "type": "text", "text": text }],
        })])
    }
}

fn first_event_user_title(recs: &[Value]) -> String {
    recs.iter()
        .map(event_user_title_from_record)
        .find(|title| !title.is_empty())
        .unwrap_or_default()
}

fn append_scan_segment(line: &mut Vec<u8>, dropping: &mut bool, segment: &[u8], max_line: usize) {
    if *dropping || segment.is_empty() {
        return;
    }
    if line.len().saturating_add(segment.len()) > max_line {
        line.clear();
        *dropping = true;
    } else {
        line.extend_from_slice(segment);
    }
}

fn event_user_title_from_line(line: &[u8]) -> String {
    let line = line.strip_suffix(b"\r").unwrap_or(line);
    serde_json::from_slice::<Value>(line)
        .map(|rec| event_user_title_from_record(&rec))
        .unwrap_or_default()
}

// List metadata normally parses only the first 128 KiB. If an image-first response_item is a
// larger single JSON line, stream past it and read the following compact user_message event.
fn scan_event_user_title(file: &Path) -> String {
    const MAX_SCAN: usize = 64 * 1024 * 1024;
    const MAX_LINE: usize = 256 * 1024;
    let input = match fs::File::open(file) {
        Ok(file) => file,
        Err(_) => return String::new(),
    };
    let mut reader = BufReader::new(input);
    let mut line: Vec<u8> = vec![];
    let mut dropping = false;
    let mut scanned = 0usize;
    while scanned < MAX_SCAN {
        let available = match reader.fill_buf() {
            Ok(buf) if !buf.is_empty() => buf,
            Ok(_) | Err(_) => break,
        };
        let take = available.len().min(MAX_SCAN - scanned);
        let mut start = 0usize;
        for i in 0..take {
            if available[i] == b'\n' {
                append_scan_segment(&mut line, &mut dropping, &available[start..i], MAX_LINE);
                let title = if dropping { String::new() } else { event_user_title_from_line(&line) };
                line.clear();
                dropping = false;
                if !title.is_empty() {
                    return title;
                }
                start = i + 1;
            }
        }
        append_scan_segment(&mut line, &mut dropping, &available[start..take], MAX_LINE);
        reader.consume(take);
        scanned = scanned.saturating_add(take);
    }
    if dropping { String::new() } else { event_user_title_from_line(&line) }
}

/// argv → display command: unwrap the ["bash","-lc", script] convention, else shell-ish join.
fn join_argv(cmd: &Value) -> String {
    if let Some(s) = cmd.as_str() {
        return s.to_string();
    }
    let arr = match cmd.as_array() {
        Some(a) => a,
        None => return String::new(),
    };
    let parts: Vec<String> = arr.iter().map(|x| x.as_str().unwrap_or_default().to_string()).collect();
    if parts.len() == 3
        && ["bash", "sh", "zsh", "dash"].contains(&parts[0].as_str())
        && ["-lc", "-c"].contains(&parts[1].as_str())
    {
        return parts[2].clone();
    }
    parts
        .iter()
        .map(|p| {
            if p.is_empty() || p.chars().any(|c| c.is_whitespace() || c == '"' || c == '\'') {
                format!("{:?}", p) // debug-quote args with spaces/quotes
            } else {
                p.clone()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Codex tool name + parsed arguments → (renderer tool name, renderer input).
fn map_tool(name: &str, args: &Value) -> (String, Value) {
    let s = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    match name {
        "shell" | "local_shell" | "container.exec" => {
            let mut input = json!({ "command": join_argv(args.get("command").unwrap_or(&Value::Null)) });
            let desc = if !s("justification").is_empty() { s("justification") } else { s("workdir") };
            if !desc.is_empty() {
                input["description"] = json!(desc);
            }
            ("Bash".into(), input)
        }
        "shell_command" => ("Bash".into(), json!({ "command": s("command") })),
        "exec_command" => {
            let cmd = if !s("cmd").is_empty() { s("cmd") } else { s("command") };
            ("Bash".into(), json!({ "command": cmd }))
        }
        "apply_patch" => {
            let patch = if !s("input").is_empty() { s("input") } else { s("patch") };
            ("ApplyPatch".into(), json!({ "patch": patch }))
        }
        "update_plan" => {
            let todos: Vec<Value> = args
                .get("plan")
                .and_then(|p| p.as_array())
                .map(|a| {
                    a.iter()
                        .map(|st| {
                            json!({
                                "content": st.get("step").and_then(|v| v.as_str()).unwrap_or(""),
                                "status": st.get("status").and_then(|v| v.as_str()).unwrap_or("pending"),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            ("TodoWrite".into(), json!({ "todos": todos }))
        }
        "view_image" => ("Read".into(), json!({ "file_path": s("path") })),
        "web_search" => ("WebSearch".into(), json!({ "query": s("query") })),
        _ => (
            name.to_string(),
            if args.is_object() { args.clone() } else { json!({}) },
        ),
    }
}

// ---- code-mode `exec` scripts (custom_tool_call name "exec") ----
//
// Codex code-mode (gpt-*-sol) emits one custom tool named `exec` whose input is JavaScript
// calling `tools.*` (exec_command / write_stdin / …). The dominant shape by far is a single
// `tools.exec_command({cmd, workdir, …})` plus print plumbing (`text(r.output);` and friends) —
// semantically just a shell run, so it renders as the familiar Bash card (command + workdir).
// Anything else (write_stdin, Promise.all batches, real orchestration code) keeps the whole
// script as a `Script` card the renderer shows as highlighted JavaScript. Extraction is
// conservative: any parse doubt falls back to the Script card, never to a wrong command.

/// First `{…}` object literal at/after `from`, brace-matched with double-quoted strings (and
/// their escapes) treated as opaque — shell commands are full of braces and quotes.
fn extract_object(s: &str, from: usize) -> Option<(usize, usize)> {
    let start = from + s[from..].find('{')?;
    let (mut depth, mut in_str, mut esc) = (0i32, false, false);
    for (i, &b) in s.as_bytes().iter().enumerate().skip(start) {
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
            }
            continue;
        }
        match b {
            b'"' => in_str = true,
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some((start, i));
                }
            }
            _ => {}
        }
    }
    None
}

/// Quote bare JS object keys (`{cmd: …}` → `{"cmd": …}`) outside string context so serde can
/// parse code-mode's object-literal arguments; double-quoted string contents pass verbatim.
fn quote_js_keys(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len() + 16);
    let (mut in_str, mut esc) = (false, false);
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if in_str {
            if esc {
                esc = false;
            } else if c == '\\' {
                esc = true;
            } else if c == '"' {
                in_str = false;
            }
            out.push(c);
            i += 1;
            continue;
        }
        if c == '"' {
            in_str = true;
            out.push(c);
            i += 1;
            continue;
        }
        if c == '{' || c == ',' {
            out.push(c);
            i += 1;
            while i < chars.len() && chars[i].is_whitespace() {
                out.push(chars[i]);
                i += 1;
            }
            let start = i;
            while i < chars.len() && (chars[i].is_ascii_alphanumeric() || chars[i] == '_' || chars[i] == '$') {
                i += 1;
            }
            if i > start {
                let mut j = i;
                while j < chars.len() && chars[j].is_whitespace() {
                    j += 1;
                }
                let ident: String = chars[start..i].iter().collect();
                if j < chars.len() && chars[j] == ':' {
                    out.push('"');
                    out.push_str(&ident);
                    out.push('"');
                } else {
                    out.push_str(&ident);
                }
            }
            continue;
        }
        out.push(c);
        i += 1;
    }
    out
}

/// The `{…}` argument of a tools.* call: strict JSON first (code-mode usually emits JSON),
/// then a bare-key-quoted retry for JS object literals.
fn parse_call_args(obj: &str) -> Option<Value> {
    serde_json::from_str::<Value>(obj)
        .ok()
        .or_else(|| serde_json::from_str::<Value>(&quote_js_keys(obj)).ok())
        .filter(|v| v.is_object())
}

/// Code-mode exec script → renderer tool card (see module comment above).
fn map_exec_script(script: &str) -> (String, Value) {
    let fallback = || ("Script".to_string(), json!({ "code": script }));
    // exactly one tools.* call, and it must be exec_command (a cmd string that itself mentions
    // "tools." trips the count — conservative fallback, never a wrong command)
    if script.matches("tools.").count() != 1 {
        return fallback();
    }
    let call = match script.find("tools.exec_command(") {
        Some(i) => i,
        None => return fallback(),
    };
    // prefix must be assignment/await plumbing only: `const r = await` / `let out = await` / `await`
    let prefix: Vec<&str> = script[..call].split_whitespace().collect();
    let prefix_ok = match prefix.as_slice() {
        [] | ["await"] => true,
        [kw, _name, "=", "await"] => matches!(*kw, "const" | "let" | "var"),
        _ => false,
    };
    if !prefix_ok {
        return fallback();
    }
    let after = call + "tools.exec_command(".len();
    let (ostart, oend) = match extract_object(script, after) {
        Some(span) => span,
        None => return fallback(),
    };
    if !script[after..ostart].trim().is_empty() {
        return fallback();
    }
    let args = match parse_call_args(&script[ostart..=oend]) {
        Some(a) => a,
        None => return fallback(),
    };
    let cmd = args
        .get("cmd")
        .or_else(|| args.get("command"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if cmd.is_empty() {
        return fallback();
    }
    // tail must close the call, then carry only print plumbing
    let rest = script[oend + 1..].trim_start();
    let rest = match rest.strip_prefix(')') {
        Some(r) => r,
        None => return fallback(),
    };
    let rest = rest.strip_prefix(';').unwrap_or(rest);
    let plumbing = rest.lines().all(|l| {
        let l = l.trim();
        l.is_empty() || l.starts_with("text(") || l.starts_with("if (") || l.starts_with("//")
    });
    if !plumbing {
        return fallback();
    }
    let mut input = json!({ "command": cmd });
    if let Some(wd) = args.get("workdir").and_then(|v| v.as_str()) {
        if !wd.is_empty() {
            input["description"] = json!(wd);
        }
    }
    ("Bash".into(), input)
}

/// Error heuristic for code-mode exec output text: the runner's own status header
/// ("Script failed…" / "Exit code: N…").
fn exec_text_err(text: &str) -> bool {
    if text.starts_with("Script failed") {
        return true;
    }
    if let Some(rest) = text.strip_prefix("Exit code: ") {
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        return digits.parse::<i64>().map(|c| c != 0).unwrap_or(false);
    }
    false
}

/// Tool output payload → (display text, is_error). Unwraps codex's JSON-wrapped shell output
/// ({"output","metadata":{exit_code}}) and reads exec_command's "exited with code N" header.
fn shape_output(out: &Value) -> (String, bool) {
    // structured payload: { content, success? }
    if out.is_object() {
        let text = out
            .get("content")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| serde_json::to_string_pretty(out).unwrap_or_default());
        let err = out.get("success").and_then(|v| v.as_bool()) == Some(false);
        return (text, err);
    }
    let s = out.as_str().unwrap_or("").to_string();
    if let Ok(v) = serde_json::from_str::<Value>(&s) {
        if v.is_object() {
            if let Some(o) = v.get("output").and_then(|x| x.as_str()) {
                let code = v
                    .get("metadata")
                    .and_then(|m| m.get("exit_code"))
                    .and_then(|c| c.as_i64())
                    .unwrap_or(0);
                return (o.to_string(), code != 0);
            }
            if let Some(c) = v.get("content").and_then(|x| x.as_str()) {
                let err = v.get("success").and_then(|x| x.as_bool()) == Some(false);
                return (c.to_string(), err);
            }
        }
    }
    // code-mode runner header (older builds wrote it as a plain string): "Exit code: N…" /
    // "Script failed…"
    if exec_text_err(&s) {
        return (s, true);
    }
    // exec_command header: "…\nProcess exited with code N\n…" near the top
    let head: String = s.chars().take(240).collect();
    if let Some(pos) = head.find("exited with code ") {
        let digits: String = head[pos + "exited with code ".len()..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        if let Ok(code) = digits.parse::<i64>() {
            return (s, code != 0);
        }
    }
    (s, false)
}

/// Normalize parsed rollout records into the renderer's message model.
pub fn normalize(recs: &[Value]) -> Norm {
    let mut messages: Vec<Value> = vec![];
    let (mut tin, mut tout, mut tcr, mut turns) = (0i64, 0i64, 0i64, 0i64);
    let mut model: Option<String> = None;
    let mut cwd: Option<String> = None;
    let mut session_id: Option<String> = None;
    let mut thread_id: Option<String> = None;
    let mut parent_thread_id: Option<String> = None;
    let mut forked_from_id: Option<String> = None;
    let mut is_subagent = false;
    let mut agent_path: Option<String> = None;
    let mut agent_nickname: Option<String> = None;
    let mut agent_role: Option<String> = None;
    let mut agent_depth: Option<i64> = None;
    let mut saw_session_meta = false;
    let mut git_branch: Option<String> = None;
    let mut version: Option<String> = None;

    for rec in recs {
        let (ty, p, ts) = split_line(rec);
        let with_ts = |mut m: Value| {
            if let Some(t) = ts {
                m["ts"] = json!(t);
            }
            m
        };
        match ty {
            "session_meta" => {
                if !saw_session_meta {
                    saw_session_meta = true;
                    let identity = canonical_thread_meta(p);
                    thread_id = identity.thread_id;
                    session_id = identity.root_session_id;
                    parent_thread_id = identity.parent_thread_id;
                    forked_from_id = identity.forked_from_id;
                    is_subagent = identity.is_subagent;
                    agent_path = identity.agent_path;
                    agent_nickname = identity.agent_nickname;
                    agent_role = identity.agent_role;
                    agent_depth = identity.agent_depth;
                }
                let sid = p
                    .get("session_id")
                    .or_else(|| p.get("id"))
                    .and_then(|v| v.as_str());
                if session_id.is_none() {
                    session_id = sid.map(|s| s.to_string());
                }
                if cwd.is_none() {
                    cwd = p.get("cwd").and_then(|v| v.as_str()).map(|s| s.to_string());
                }
                if version.is_none() {
                    version = p.get("cli_version").and_then(|v| v.as_str()).map(|s| s.to_string());
                }
                if git_branch.is_none() {
                    git_branch = p
                        .get("git")
                        .and_then(|g| g.get("branch"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());
                }
            }
            "turn_context" => {
                if let Some(m) = p.get("model").and_then(|v| v.as_str()) {
                    model = Some(m.to_string());
                }
                if cwd.is_none() {
                    cwd = p.get("cwd").and_then(|v| v.as_str()).map(|s| s.to_string());
                }
            }
            "compacted" => {
                let text = p.get("message").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
                if !text.is_empty() {
                    messages.push(with_ts(json!({ "role": "user", "content": [{ "type": "text", "text": text }] })));
                }
            }
            "event_msg" => match p.get("type").and_then(|v| v.as_str()).unwrap_or("") {
                "token_count" => {
                    let u = p.get("info").and_then(|i| i.get("last_token_usage"));
                    if let Some(u) = u {
                        let input = u.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                        let cached = u.get("cached_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                        let output = u.get("output_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                        if input + cached + output > 0 {
                            let usage = json!({
                                "inputTokens": (input - cached).max(0),
                                "outputTokens": output,
                                "cacheRead": cached,
                                "cacheCreation": 0,
                            });
                            tin += (input - cached).max(0);
                            tout += output;
                            tcr += cached;
                            turns += 1;
                            // Per-turn usage rides the turn's last assistant message (codex emits
                            // one token_count per model turn).
                            if let Some(m) = messages
                                .iter_mut()
                                .rev()
                                .find(|m| m.get("role").and_then(|r| r.as_str()) == Some("assistant") && m.get("usage").is_none())
                            {
                                m["usage"] = usage;
                            }
                        }
                    }
                }
                "turn_aborted" => {
                    messages.push(with_ts(json!({
                        "role": "user",
                        "content": [{ "type": "text", "text": "[Request interrupted by user]" }],
                    })));
                }
                _ => {}
            },
            "response_item" => {
                let it = p.get("type").and_then(|v| v.as_str()).unwrap_or("");
                match it {
                    "message" => {
                        let role = p.get("role").and_then(|v| v.as_str()).unwrap_or("");
                        let content = p.get("content").cloned().unwrap_or(Value::Null);
                        if role == "assistant" {
                            let text = joined_text(&content, &["output_text", "text"]);
                            if !text.trim().is_empty() {
                                let mut m = json!({ "role": "assistant", "content": [{ "type": "text", "text": text }] });
                                if let Some(md) = &model {
                                    m["modelActual"] = json!(md);
                                }
                                messages.push(with_ts(m));
                            }
                        } else if role == "user" {
                            let text = joined_user_text(&content);
                            if let Some(skill) = skill_load_block(&text) {
                                messages.push(with_ts(json!({
                                    "role": "user",
                                    "_meta": true,
                                    "content": [skill],
                                })));
                                continue;
                            }
                            if is_meta_user_text(&text) {
                                continue;
                            }
                            let mut blocks: Vec<Value> = vec![];
                            if !text.trim().is_empty() {
                                blocks.push(json!({ "type": "text", "text": text }));
                            }
                            if let Some(arr) = content.as_array() {
                                for b in arr {
                                    if b.get("type").and_then(|t| t.as_str()) == Some("input_image") {
                                        if let Some(img) = b
                                            .get("image_url")
                                            .and_then(|u| u.as_str())
                                            .and_then(image_block)
                                        {
                                            blocks.push(img);
                                        }
                                    }
                                }
                            }
                            if !blocks.is_empty() {
                                let mut message = json!({ "role": "user", "content": blocks });
                                if is_agents_bootstrap(&text) {
                                    message["_meta"] = json!(true);
                                }
                                messages.push(with_ts(message));
                            }
                        } // system / developer turns: harness plumbing, not conversation
                    }
                    "reasoning" => {
                        let mut txt = joined_text(&p.get("summary").cloned().unwrap_or(Value::Null), &["summary_text", "text"]);
                        let extra = joined_text(&p.get("content").cloned().unwrap_or(Value::Null), &["reasoning_text", "text"]);
                        if !extra.trim().is_empty() {
                            if !txt.trim().is_empty() {
                                txt.push_str("\n\n");
                            }
                            txt.push_str(&extra);
                        }
                        if !txt.trim().is_empty() {
                            let mut m = json!({ "role": "assistant", "content": [{ "type": "thinking", "thinking": txt }] });
                            if let Some(md) = &model {
                                m["modelActual"] = json!(md);
                            }
                            messages.push(with_ts(m));
                        }
                    }
                    "function_call" => {
                        let name = p.get("name").and_then(|v| v.as_str()).unwrap_or("tool");
                        let args: Value = p
                            .get("arguments")
                            .and_then(|v| v.as_str())
                            .and_then(|s| serde_json::from_str(s).ok())
                            .unwrap_or_else(|| p.get("arguments").cloned().unwrap_or(json!({})));
                        let (tname, input) = map_tool(name, &args);
                        let id = p
                            .get("call_id")
                            .or_else(|| p.get("id"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        let mut m = json!({
                            "role": "assistant",
                            "content": [{ "type": "tool_use", "id": id, "name": tname, "input": input }],
                        });
                        if let Some(md) = &model {
                            m["modelActual"] = json!(md);
                        }
                        messages.push(with_ts(m));
                    }
                    "local_shell_call" => {
                        let cmd = p
                            .get("action")
                            .and_then(|a| a.get("command"))
                            .cloned()
                            .unwrap_or(Value::Null);
                        let id = p
                            .get("call_id")
                            .or_else(|| p.get("id"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        let mut m = json!({
                            "role": "assistant",
                            "content": [{ "type": "tool_use", "id": id, "name": "Bash", "input": { "command": join_argv(&cmd) } }],
                        });
                        if let Some(md) = &model {
                            m["modelActual"] = json!(md);
                        }
                        messages.push(with_ts(m));
                    }
                    "custom_tool_call" => {
                        let name = p.get("name").and_then(|v| v.as_str()).unwrap_or("tool");
                        let input_s = p.get("input").and_then(|v| v.as_str()).unwrap_or("");
                        let (tname, input) = if name == "apply_patch" {
                            ("ApplyPatch".to_string(), json!({ "patch": input_s }))
                        } else if name == "exec" {
                            map_exec_script(input_s)
                        } else {
                            (name.to_string(), json!({ "input": input_s }))
                        };
                        let id = p
                            .get("call_id")
                            .or_else(|| p.get("id"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        let mut m = json!({
                            "role": "assistant",
                            "content": [{ "type": "tool_use", "id": id, "name": tname, "input": input }],
                        });
                        if let Some(md) = &model {
                            m["modelActual"] = json!(md);
                        }
                        messages.push(with_ts(m));
                    }
                    "function_call_output" | "custom_tool_call_output" => {
                        let out = p.get("output").cloned().unwrap_or(Value::Null);
                        let id = p.get("call_id").and_then(|v| v.as_str()).unwrap_or("");
                        // Newer code-mode outputs are block ARRAYS — {input_text} chunks (status
                        // header + stdout, concatenated verbatim) plus optional {input_image}
                        // screenshots, which become renderer image blocks.
                        let (content, err) = if let Some(arr) = out.as_array() {
                            let text: String = arr
                                .iter()
                                .filter(|b| {
                                    matches!(
                                        b.get("type").and_then(|t| t.as_str()),
                                        Some("input_text") | Some("output_text") | Some("text")
                                    )
                                })
                                .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
                                .collect();
                            let images: Vec<Value> = arr
                                .iter()
                                .filter(|b| b.get("type").and_then(|t| t.as_str()) == Some("input_image"))
                                .filter_map(|b| b.get("image_url").and_then(|u| u.as_str()).and_then(image_block))
                                .collect();
                            let err = exec_text_err(&text);
                            if images.is_empty() {
                                (json!(text), err)
                            } else {
                                let mut blocks = vec![json!({ "type": "text", "text": text })];
                                blocks.extend(images);
                                (Value::Array(blocks), err)
                            }
                        } else {
                            let (text, err) = shape_output(&out);
                            (json!(text), err)
                        };
                        let mut tr = json!({ "type": "tool_result", "tool_use_id": id, "content": content });
                        if err {
                            tr["is_error"] = json!(true);
                        }
                        messages.push(with_ts(json!({ "role": "user", "content": [tr] })));
                    }
                    "web_search_call" => {
                        let q = p
                            .get("action")
                            .and_then(|a| a.get("query"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        let id = p
                            .get("id")
                            .or_else(|| p.get("call_id"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        let mut m = json!({
                            "role": "assistant",
                            "content": [{ "type": "tool_use", "id": id, "name": "WebSearch", "input": { "query": q } }],
                        });
                        if let Some(md) = &model {
                            m["modelActual"] = json!(md);
                        }
                        messages.push(with_ts(m));
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }

    let first_ts = messages
        .first()
        .and_then(|m| m.get("ts"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let last_ts = messages
        .last()
        .and_then(|m| m.get("ts"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    Norm {
        messages,
        totals: json!({ "in": tin, "out": tout, "cacheRead": tcr, "cacheCreation": 0, "turns": turns }),
        model,
        first_ts,
        last_ts,
        cwd,
        session_id,
        thread_id,
        parent_thread_id,
        forked_from_id,
        is_subagent,
        agent_path,
        agent_nickname,
        agent_role,
        agent_depth,
        git_branch,
        version,
    }
}

/// (cwd, canonical thread id) from a Codex head — used to name an imported store copy.
pub fn head_ids(recs: &[Value]) -> (Option<String>, Option<String>) {
    for rec in recs {
        let (ty, p, _) = split_line(rec);
        if ty == "session_meta" {
            let cwd = p.get("cwd").and_then(|v| v.as_str()).map(|s| s.to_string());
            let sid = p
                // Every subagent in a tree shares session_id. The FIRST SessionMeta.id is the
                // unique rollout key; using session_id makes sibling imports collide.
                .get("id")
                .or_else(|| p.get("thread_id"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            return (cwd, sid);
        }
    }
    (None, None)
}

// ---- sidecar customization (shared store, ~/.ccbud/codex-meta.json, keyed by rollout stem) ----

fn stem_of(file: &Path) -> String {
    file.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string()
}

/// (custom title, tags, deleted) for a codex session, from the sidecar.
fn sidecar_meta(file: &Path) -> (Option<String>, Vec<String>, bool) {
    crate::sidecar::meta(&crate::sidecar::codex_file(), &stem_of(file))
}

pub fn is_deleted(file: &Path) -> bool {
    sidecar_meta(file).2
}

/// set_ccbud-equivalent for codex sessions: same patch semantics ({title?, tags?, delete?}),
/// persisted to the sidecar instead of the rollout file (never mutate another tool's data).
pub fn set_meta(file: &str, patch: &Value) -> Value {
    let stem = stem_of(Path::new(file));
    if stem.is_empty() {
        return json!({ "ok": false, "reason": "empty" });
    }
    crate::sidecar::set_meta(&crate::sidecar::codex_file(), &stem, patch)
}

/// Drop a session's sidecar entry (after its rollout file is deleted forever).
pub fn remove_meta(file: &str) {
    crate::sidecar::remove_meta(&crate::sidecar::codex_file(), &stem_of(Path::new(file)));
}

// ---- list/detail shapes (codex flavors of history.rs session_meta / get_session) ----

fn subagent_title(n: &Norm) -> String {
    if !n.is_subagent {
        return String::new();
    }
    let path = n
        .agent_path
        .as_deref()
        .unwrap_or("")
        .trim_start_matches('/')
        .strip_prefix("root/")
        .unwrap_or_else(|| n.agent_path.as_deref().unwrap_or("").trim_start_matches('/'));
    let mut parts = Vec::new();
    if let Some(nickname) = n.agent_nickname.as_deref().filter(|value| !value.trim().is_empty()) {
        parts.push(nickname.trim());
    }
    if !path.is_empty() {
        parts.push(path);
    }
    if parts.is_empty() {
        "Codex subagent".to_string()
    } else {
        parts.join(" · ")
    }
}

fn is_canonical_thread_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && [8usize, 13, 18, 23].into_iter().all(|index| bytes[index] == b'-')
        && bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| [8usize, 13, 18, 23].contains(&index) || byte.is_ascii_hexdigit())
}

/// List-row meta from already-parsed head records. `dir_id` is `__codex__` for the live tree
/// or `__imported__` for snapshots copied into the app store.
pub fn session_meta_from(file: &Path, recs: &[Value], dir_id: &str, dir_label: &str) -> Option<Value> {
    let meta = fs::metadata(file).ok()?;
    let n = normalize(recs);
    // Live rollouts customize via the sidecar (never rewrite another tool's files); imported
    // COPIES (marked by an .import.json) are our own files, where the standard in-file
    // __ccbud__ (written by set_ccbud) applies.
    let native = crate::history::read_import_meta(&file.to_string_lossy()).is_none();
    let (cc_title, cc_tags, cc_deleted) = if native {
        sidecar_meta(file)
    } else {
        crate::history::read_ccbud(recs)
    };
    let mut transcript_title = crate::history::first_user_text(&n.messages);
    if transcript_title.is_empty() {
        transcript_title = first_event_user_title(recs);
    }
    if transcript_title.is_empty() && meta.len() > 131072 {
        transcript_title = scan_event_user_title(file);
    }
    let agent_title = subagent_title(&n);
    let auto_title = if agent_title.is_empty() { transcript_title } else { agent_title };
    let stem = stem_of(file);
    let mt = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0);
    Some(json!({
        // Row ids are UI identities, so include the configured store. A live rollout and an
        // imported snapshot can legitimately share the same filename/thread id.
        "id": format!("codex:{}:{}", dir_id, stem),
        "file": file.to_string_lossy(),
        "source": "codex",
        "dirId": dir_id,
        "dirLabel": dir_label,
        "sessionId": n.thread_id.clone().or_else(|| n.session_id.clone()).unwrap_or_else(|| stem.clone()),
        "threadId": n.thread_id.clone().or_else(|| n.session_id.clone()).unwrap_or_else(|| stem.clone()),
        "canonicalThreadIdValid": n.thread_id.as_deref().is_some_and(is_canonical_thread_id),
        "rootSessionId": n.session_id.clone().or_else(|| n.thread_id.clone()).unwrap_or_else(|| stem.clone()),
        "parentThreadId": n.parent_thread_id.clone(),
        "forkedFromId": n.forked_from_id.clone(),
        "cwd": n.cwd.clone(),
        "project": n.cwd.as_deref().map(crate::history::base_name).unwrap_or_default(),
        "gitBranch": n.git_branch.clone(),
        "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
        "autoTitle": auto_title,
        "tags": cc_tags,
        "model": n.model,
        "isSubagent": n.is_subagent,
        "agentPath": n.agent_path.clone(),
        "agentNickname": n.agent_nickname.clone(),
        "agentRole": n.agent_role.clone(),
        "agentDepth": n.agent_depth,
        "imported": dir_id == "__imported__",
        "deleted": cc_deleted,
        "createdAt": crate::history::record_created_ms(recs, file),
        "lastActivity": mt,
        "sizeKB": (meta.len() as f64 / 1024.0).round() as i64,
    }))
}

/// Full-detail shape from already-parsed records (history.rs get_session routes here).
pub fn session_from_recs(file: &str, recs: &[Value]) -> Value {
    let path = Path::new(file);
    let n = normalize(recs);
    let import_meta = crate::history::read_import_meta(file);
    // Same sidecar-vs-in-file split as session_meta_from.
    let (cc_title, cc_tags, cc_deleted) = if import_meta.is_none() {
        sidecar_meta(path)
    } else {
        crate::history::read_ccbud(recs)
    };
    let mut transcript_title = crate::history::first_user_text(&n.messages);
    if transcript_title.is_empty() {
        transcript_title = first_event_user_title(recs);
    }
    let agent_title = subagent_title(&n);
    let auto_title = if agent_title.is_empty() { transcript_title } else { agent_title };
    let stem = stem_of(path);
    json!({
        "meta": {
            "id": format!("codex:{}", stem),
            "file": file,
            "source": "codex",
            "assistant": "Codex",
            "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
            "autoTitle": auto_title,
            "tags": cc_tags,
            "summary": Value::Null,
            "sessionId": n.thread_id.clone().or_else(|| n.session_id.clone()).unwrap_or_else(|| stem.clone()),
            "threadId": n.thread_id.clone().or_else(|| n.session_id.clone()).unwrap_or_else(|| stem.clone()),
            "canonicalThreadIdValid": n.thread_id.as_deref().is_some_and(is_canonical_thread_id),
            "rootSessionId": n.session_id.clone().or_else(|| n.thread_id.clone()).unwrap_or_else(|| stem.clone()),
            "parentThreadId": n.parent_thread_id.clone(),
            "forkedFromId": n.forked_from_id.clone(),
            "cwd": n.cwd.clone(),
            "project": n.cwd.as_deref().map(crate::history::base_name).unwrap_or_default(),
            "gitBranch": n.git_branch.clone(),
            "version": n.version.clone(),
            "isSubagent": n.is_subagent,
            "agentPath": n.agent_path.clone(),
            "agentNickname": n.agent_nickname.clone(),
            "agentRole": n.agent_role.clone(),
            "agentDepth": n.agent_depth,
            "deleted": cc_deleted,
            "imported": import_meta.is_some(),
            "importedFrom": import_meta.as_ref().and_then(|m| m.get("originalPath")).cloned().unwrap_or(Value::Null),
            "importedAt": import_meta.as_ref().and_then(|m| m.get("importedAt")).cloned().unwrap_or(Value::Null),
            "model": n.model,
            "totals": n.totals,
            "messages": n.messages.len(),
            "subagentCount": 0,
            "firstTs": n.first_ts,
            "lastTs": n.last_ts,
        },
        "messages": n.messages,
        "subagents": {},
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(ts: &str, ty: &str, payload: Value) -> String {
        serde_json::to_string(&json!({ "timestamp": ts, "type": ty, "payload": payload })).unwrap()
    }

    fn fixture() -> Vec<Value> {
        let lines = vec![
            line("2026-07-04T07:13:08.965Z", "session_meta", json!({
                "session_id": "019f-abc", "id": "019f-abc", "timestamp": "2026-07-04T07:13:07.386Z",
                "cwd": "/tmp/projx", "originator": "codex-tui", "cli_version": "0.142.5",
                "git": { "branch": "main" }
            })),
            line("2026-07-04T07:13:08.967Z", "turn_context", json!({ "cwd": "/tmp/projx", "model": "gpt-5.5" })),
            line("2026-07-04T07:13:08.967Z", "response_item", json!({
                "type": "message", "role": "user",
                "content": [{ "type": "input_text", "text": "<environment_context>\n<cwd>/tmp/projx</cwd>\n</environment_context>" }]
            })),
            line("2026-07-04T07:13:08.969Z", "response_item", json!({
                "type": "message", "role": "user", "content": [{ "type": "input_text", "text": "fix the bug please" }]
            })),
            line("2026-07-04T07:13:09.100Z", "event_msg", json!({ "type": "user_message", "message": "fix the bug please" })),
            line("2026-07-04T07:13:10.000Z", "response_item", json!({
                "type": "reasoning", "summary": [{ "type": "summary_text", "text": "Looking at the repo" }], "encrypted_content": "xxx"
            })),
            line("2026-07-04T07:13:11.000Z", "response_item", json!({
                "type": "function_call", "name": "exec_command",
                "arguments": "{\"cmd\": \"ls -la\", \"yield_time_ms\": 10000}", "call_id": "call_1"
            })),
            line("2026-07-04T07:13:12.000Z", "response_item", json!({
                "type": "function_call_output", "call_id": "call_1",
                "output": "Chunk ID: x\nWall time: 0.1 seconds\nProcess exited with code 0\nOutput:\n---\na.txt\nb.txt"
            })),
            line("2026-07-04T07:13:13.000Z", "response_item", json!({
                "type": "function_call", "name": "shell",
                "arguments": "{\"command\": [\"bash\", \"-lc\", \"cargo test\"], \"workdir\": \"/tmp/projx\"}", "call_id": "call_2"
            })),
            line("2026-07-04T07:13:14.000Z", "response_item", json!({
                "type": "function_call_output", "call_id": "call_2",
                "output": "{\"output\": \"error: it broke\", \"metadata\": {\"exit_code\": 101, \"duration_seconds\": 1.5}}"
            })),
            line("2026-07-04T07:13:15.000Z", "response_item", json!({
                "type": "function_call", "name": "update_plan",
                "arguments": "{\"plan\": [{\"step\": \"read code\", \"status\": \"completed\"}, {\"step\": \"fix bug\", \"status\": \"in_progress\"}]}",
                "call_id": "call_3"
            })),
            line("2026-07-04T07:13:16.000Z", "response_item", json!({
                "type": "custom_tool_call", "name": "apply_patch", "call_id": "call_4",
                "input": "*** Begin Patch\n*** Update File: src/a.rs\n@@\n-old\n+new\n*** End Patch"
            })),
            line("2026-07-04T07:13:17.000Z", "response_item", json!({
                "type": "message", "role": "assistant",
                "content": [{ "type": "output_text", "text": "Done — fixed." }], "phase": "final_answer"
            })),
            line("2026-07-04T07:13:17.500Z", "event_msg", json!({
                "type": "token_count",
                "info": {
                    "total_token_usage": { "input_tokens": 900, "cached_input_tokens": 600, "output_tokens": 80, "total_tokens": 980 },
                    "last_token_usage": { "input_tokens": 900, "cached_input_tokens": 600, "output_tokens": 80, "total_tokens": 980 },
                    "model_context_window": 258400
                }
            })),
        ];
        lines
            .iter()
            .map(|l| serde_json::from_str::<Value>(l).unwrap())
            .collect()
    }

    #[test]
    fn normalizes_rollout_into_renderer_model() {
        let recs = fixture();
        assert!(looks_codex(&recs));
        let n = normalize(&recs);

        assert_eq!(n.session_id.as_deref(), Some("019f-abc"));
        assert_eq!(n.cwd.as_deref(), Some("/tmp/projx"));
        assert_eq!(n.version.as_deref(), Some("0.142.5"));
        assert_eq!(n.git_branch.as_deref(), Some("main"));
        assert_eq!(n.model.as_deref(), Some("gpt-5.5"));

        // env-context user turn skipped; real prose, reasoning, 4 tool calls, 2 results, final text
        let roles: Vec<&str> = n.messages.iter().map(|m| m["role"].as_str().unwrap()).collect();
        assert_eq!(roles, vec!["user", "assistant", "assistant", "user", "assistant", "user", "assistant", "assistant", "assistant"]);

        let title = crate::history::first_user_text(&n.messages);
        assert_eq!(title, "fix the bug please");

        // exec_command → Bash card with the raw command
        let tu1 = &n.messages[2]["content"][0];
        assert_eq!(tu1["type"], "tool_use");
        assert_eq!(tu1["name"], "Bash");
        assert_eq!(tu1["input"]["command"], "ls -la");
        // its ok result pairs by call id and is not an error
        let tr1 = &n.messages[3]["content"][0];
        assert_eq!(tr1["tool_use_id"], "call_1");
        assert!(tr1.get("is_error").is_none());

        // shell argv ["bash","-lc","cargo test"] unwraps; exit_code 101 marks the result as error
        let tu2 = &n.messages[4]["content"][0];
        assert_eq!(tu2["input"]["command"], "cargo test");
        let tr2 = &n.messages[5]["content"][0];
        assert_eq!(tr2["is_error"], true);
        assert_eq!(tr2["content"], "error: it broke");

        // update_plan → TodoWrite todos
        let tu3 = &n.messages[6]["content"][0];
        assert_eq!(tu3["name"], "TodoWrite");
        assert_eq!(tu3["input"]["todos"][1]["status"], "in_progress");

        // apply_patch custom tool → ApplyPatch {patch}
        let tu4 = &n.messages[7]["content"][0];
        assert_eq!(tu4["name"], "ApplyPatch");
        assert!(tu4["input"]["patch"].as_str().unwrap().contains("*** Update File: src/a.rs"));

        // reasoning became a thinking block
        assert_eq!(n.messages[1]["content"][0]["type"], "thinking");

        // token_count landed on the final assistant text turn and rolled into totals
        let last = n.messages.last().unwrap();
        assert_eq!(last["usage"]["inputTokens"], 300); // input − cached
        assert_eq!(last["usage"]["cacheRead"], 600);
        assert_eq!(n.totals["out"], 80);
        assert_eq!(n.totals["turns"], 1);

        // timestamps span the emitted messages
        assert_eq!(n.first_ts.as_deref(), Some("2026-07-04T07:13:08.969Z"));
        assert_eq!(n.last_ts.as_deref(), Some("2026-07-04T07:13:17.000Z"));
    }

    // Machine-data smoke: run explicitly with `cargo test --lib -- --ignored` on a machine that
    // has real Codex sessions. Verifies every real rollout sniffs + normalizes + shapes.
    #[test]
    #[ignore]
    fn real_codex_sessions_smoke() {
        if !root_exists() {
            eprintln!("no ~/.codex/sessions — skipping");
            return;
        }
        let mut n = 0;
        let label = codex_label();
        walk_sessions(&sessions_root(), |p| {
            let raw = fs::read_to_string(&p).unwrap_or_default();
            let recs = crate::history::parse_lines(&raw);
            assert!(looks_codex(&recs), "not sniffed as codex: {:?}", p);
            let norm = normalize(&recs);
            assert!(norm.session_id.is_some() || norm.messages.is_empty(), "no session id: {:?}", p);
            let sess = session_from_recs(&p.to_string_lossy(), &recs);
            assert_eq!(sess["meta"]["assistant"], "Codex");
            let listed = session_meta_from(&p, &recs, &label, &label).unwrap();
            assert_eq!(listed["source"], "codex");
            n += 1;
        });
        eprintln!("smoke-checked {} real codex sessions", n);
    }

    #[test]
    fn claude_records_do_not_sniff_as_codex() {
        let recs = vec![
            json!({ "type": "user", "message": { "role": "user", "content": "hi" }, "cwd": "/x", "sessionId": "s1" }),
            json!({ "type": "assistant", "message": { "role": "assistant", "content": [{ "type": "text", "text": "hello" }] } }),
            json!({ "type": "summary", "summary": "greeting" }),
        ];
        assert!(!looks_codex(&recs));
    }

    #[test]
    fn old_envelope_less_rollout_still_parses() {
        let recs = vec![
            json!({ "id": "old-1", "timestamp": "2025-05-01T00:00:00Z", "instructions": "x", "cwd": "/tmp/old" }),
            json!({ "type": "message", "role": "user", "content": [{ "type": "input_text", "text": "hello old codex" }] }),
            json!({ "type": "message", "role": "assistant", "content": [{ "type": "output_text", "text": "hi" }] }),
        ];
        assert!(looks_codex(&recs));
        let n = normalize(&recs);
        assert_eq!(n.session_id.as_deref(), Some("old-1"));
        assert_eq!(n.cwd.as_deref(), Some("/tmp/old"));
        assert_eq!(n.messages.len(), 2);
        assert_eq!(crate::history::first_user_text(&n.messages), "hello old codex");
    }

    #[test]
    fn turn_aborted_and_web_search_render() {
        let recs: Vec<Value> = vec![
            serde_json::from_str(&line("2026-01-01T00:00:00Z", "response_item", json!({
                "type": "web_search_call", "id": "ws_1", "action": { "type": "search", "query": "rust serde" }
            }))).unwrap(),
            serde_json::from_str(&line("2026-01-01T00:00:01Z", "event_msg", json!({ "type": "turn_aborted", "reason": "interrupted" }))).unwrap(),
        ];
        let n = normalize(&recs);
        assert_eq!(n.messages[0]["content"][0]["name"], "WebSearch");
        assert_eq!(n.messages[0]["content"][0]["input"]["query"], "rust serde");
        assert!(n.messages[1]["content"][0]["text"].as_str().unwrap().starts_with("[Request interrupted"));
    }

    #[test]
    fn maps_code_mode_exec_scripts() {
        // canonical single exec_command + print plumbing → Bash card (command + workdir)
        let (n, i) = map_exec_script(
            "const r = await tools.exec_command({\"cmd\":\"ls -la\",\"workdir\":\"/tmp/p\",\"yield_time_ms\":10000,\"max_output_tokens\":30000});\ntext(r.output);",
        );
        assert_eq!(n, "Bash");
        assert_eq!(i["command"], "ls -la");
        assert_eq!(i["description"], "/tmp/p");
        // bare JS object keys (code-mode literal) parse via the quoting retry; braces/quotes
        // inside the command string stay opaque
        let (n, i) = map_exec_script(
            "const r = await tools.exec_command({cmd:\"awk '{print: $1}' a.txt\",workdir:\"/w\"});\ntext(JSON.stringify(r));",
        );
        assert_eq!(n, "Bash");
        assert_eq!(i["command"], "awk '{print: $1}' a.txt");
        // SESSION_ID echo tail is still plumbing
        let (n, _) = map_exec_script(
            "const r = await tools.exec_command({\"cmd\":\"sleep 1\"});\ntext(r.output);\nif (r.session_id) text(`SESSION_ID=${r.session_id}`);",
        );
        assert_eq!(n, "Bash");
        // write_stdin / multi-call orchestration keep the script verbatim
        let (n, i) = map_exec_script("const r = await tools.write_stdin({\"session_id\":40352,\"chars\":\"\"});\ntext(r.output);");
        assert_eq!(n, "Script");
        assert!(i["code"].as_str().unwrap().contains("write_stdin"));
        let (n, _) = map_exec_script(
            "const a = await Promise.all([tools.exec_command({\"cmd\":\"x\"}), tools.exec_command({\"cmd\":\"y\"})]);\ntext(a.map(r => r.output).join());",
        );
        assert_eq!(n, "Script");
    }

    #[test]
    fn shapes_code_mode_block_array_outputs() {
        let recs = vec![
            json!({ "type": "custom_tool_call", "name": "exec", "call_id": "c1",
                    "input": "const r = await tools.exec_command({\"cmd\":\"ls\"});\ntext(r.output);" }),
            json!({ "type": "custom_tool_call_output", "call_id": "c1", "output": [
                { "type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n" },
                { "type": "input_text", "text": "a.txt\n" },
                { "type": "input_image", "image_url": "data:image/png;base64,QUJD", "detail": "high" }
            ] }),
            json!({ "type": "custom_tool_call", "name": "exec", "call_id": "c2",
                    "input": "const r = await tools.exec_command({\"cmd\":\"boom\"});\ntext(r.output);" }),
            json!({ "type": "custom_tool_call_output", "call_id": "c2", "output": [
                { "type": "input_text", "text": "Script failed\nWall time 0.0 seconds\nOutput:\nerr" }
            ] }),
        ];
        let n = normalize(&recs);
        assert_eq!(n.messages.len(), 4);
        let tu = &n.messages[0]["content"][0];
        assert_eq!(tu["name"], "Bash");
        assert_eq!(tu["input"]["command"], "ls");
        // text chunks concatenate VERBATIM (no injected separators); screenshot rides along
        let tr = &n.messages[1]["content"][0];
        assert_eq!(tr["tool_use_id"], "c1");
        assert_eq!(tr["content"][0]["text"], "Script completed\nWall time 0.1 seconds\nOutput:\na.txt\n");
        assert_eq!(tr["content"][1]["type"], "image");
        assert_eq!(tr["content"][1]["source"]["data"], "QUJD");
        assert!(tr.get("is_error").is_none());
        // "Script failed" header marks the result as an error; plain-text output stays a string
        let tr2 = &n.messages[3]["content"][0];
        assert_eq!(tr2["content"].as_str().unwrap(), "Script failed\nWall time 0.0 seconds\nOutput:\nerr");
        assert_eq!(tr2["is_error"], true);
    }
}
