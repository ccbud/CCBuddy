use super::*;
use super::exec::map_exec_script;
use serde_json::json;

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
