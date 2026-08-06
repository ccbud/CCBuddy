use serde_json::json;
use std::fs;

use super::search::search_sessions;
use super::searchfmt::strip_injected;

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
