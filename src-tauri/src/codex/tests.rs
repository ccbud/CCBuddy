use super::*;
use serde_json::{json, Value};
use std::fs;

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
