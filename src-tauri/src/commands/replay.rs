// Desktop / ChatGPT deep-link replay commands, moved verbatim from lib.rs.

use serde_json::{json, Value};

use crate::history;

fn pct(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{:02X}", b),
        })
        .collect()
}
#[tauri::command]
pub(crate) fn desktop_replay(file: String, prompt: Option<String>) -> Value {
    if file.is_empty() {
        return json!({ "ok": false, "reason": "noFile" });
    }
    if !cfg!(target_os = "macos") {
        return json!({ "ok": false, "reason": "unsupported" });
    }
    // The full review prompt comes from the renderer's i18n (desktop.replayPrompt) so it stays
    // localized; fall back to a minimal default only if the renderer didn't supply one.
    let prompt = prompt
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| "请基于这些对话记录在 Claude 桌面版里继续。".to_string());
    // Attach the main session AND every subagent transcript (they live in a separate subagents/ dir),
    // each as its own `file=` — the Cowork deep link honors repeated `file=` — so the analysis covers
    // subagent runs, not just the main thread.
    let mut url = format!("claude://cowork/new?q={}&file={}", pct(&prompt), pct(&file));
    for sub in history::subagent_transcript_paths(&file) {
        url.push_str("&file=");
        url.push_str(&pct(&sub));
    }
    #[cfg(target_os = "macos")]
    {
        let ok = std::process::Command::new("/usr/bin/open").arg(&url).spawn().is_ok();
        json!({ "ok": ok })
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = url;
        json!({ "ok": false, "reason": "unsupported" })
    }
}
#[tauri::command]
pub(crate) fn chatgpt_replay(file: String, prompt: Option<String>) -> Value {
    if file.is_empty() {
        return json!({ "ok": false, "reason": "noFile" });
    }
    if !cfg!(target_os = "macos") {
        return json!({ "ok": false, "reason": "unsupported" });
    }
    // The ChatGPT desktop app (Codex era) keeps the codex:// scheme: codex://new takes
    // `prompt` (initial composer text) and `path` (workspace dir). It has no file-attach
    // param, so the workspace is pointed at the transcripts' directory and the prompt
    // lists the absolute JSONL paths — main session plus every subagent (they live under
    // `<dir>/<session>/subagents/`, inside the same workspace) — for the task to read.
    let prompt = prompt
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| "请读取下列 Coding CLI 会话的 JSONL 记录并帮我复盘。".to_string());
    let mut text = prompt;
    text.push_str("\n\nTranscripts:\n");
    text.push_str(&file);
    for sub in history::subagent_transcript_paths(&file) {
        text.push('\n');
        text.push_str(&sub);
    }
    let mut url = format!("codex://new?prompt={}", pct(&text));
    if let Some(dir) = std::path::Path::new(&file).parent() {
        url.push_str("&path=");
        url.push_str(&pct(&dir.to_string_lossy()));
    }
    #[cfg(target_os = "macos")]
    {
        // `open` exits non-zero when nothing handles the scheme → app not installed.
        match std::process::Command::new("/usr/bin/open").arg(&url).status() {
            Ok(s) if s.success() => json!({ "ok": true }),
            Ok(_) => json!({ "ok": false, "reason": "notInstalled" }),
            Err(_) => json!({ "ok": false, "reason": "failed" }),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = url;
        json!({ "ok": false, "reason": "unsupported" })
    }
}
