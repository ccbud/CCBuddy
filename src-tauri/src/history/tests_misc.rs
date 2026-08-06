use serde_json::{json, Value};
use std::fs;

use super::edit::{delete_session_file, set_ccbud};
use super::jsonl::session_read_error;
use super::list::list_sessions;
use super::session::get_session;
use super::subagents::{export_bundle, session_has_subagents, subagent_transcript_paths};

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
