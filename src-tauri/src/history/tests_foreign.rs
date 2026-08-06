use serde_json::json;
use std::fs;
use std::path::Path;

use super::edit::delete_session_file;
use super::list::list_sessions;
use super::search::search_sessions;
use super::session::get_session;

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
