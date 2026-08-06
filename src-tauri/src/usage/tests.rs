use super::build::build_data;
use super::model::Day;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;

pub(super) fn line(v: Value) -> String {
    format!("{}\n", v)
}
fn asst(id: &str, req: &str, model: &str, ts: &str, inp: i64, out: i64) -> String {
    line(json!({ "type": "assistant", "timestamp": ts, "requestId": req,
        "message": { "id": id, "model": model,
            "usage": { "input_tokens": inp, "output_tokens": out } } }))
}

pub(super) fn sum(days: &HashMap<String, Day>) -> (i64, i64, i64, i64, i64, HashMap<String, i64>) {
    let (mut tokens, mut input, mut output, mut cache_read, mut requests) = (0i64, 0i64, 0i64, 0i64, 0i64);
    let mut models: HashMap<String, i64> = HashMap::new();
    for d in days.values() {
        tokens += d.tokens;
        input += d.input;
        output += d.output;
        cache_read += d.cache_read;
        requests += d.requests;
        for (m, v) in &d.models {
            *models.entry(m.clone()).or_insert(0) += v;
        }
    }
    (tokens, input, output, cache_read, requests, models)
}

#[test]
fn claude_ccusage_semantics() {
    let base = std::env::temp_dir().join(format!("ccbud-usage-cl-{}", std::process::id()));
    let _ = fs::remove_dir_all(&base);
    let proj = base.join("projects").join("-p");
    // nested session dir + subagent transcript at arbitrary depth — recursive walk finds both
    let deep = proj.join("s1").join("subagents");
    fs::create_dir_all(&deep).unwrap();

    fs::write(
        proj.join("s1.jsonl"),
        // counted (110)
        asst("m1", "r1", "claude-x", "2026-07-01T10:00:00Z", 100, 10)
            // same (id, requestId) duplicate → collapsed
            + &asst("m1", "r1", "claude-x", "2026-07-01T10:00:00Z", 100, 10)
            // same id, DIFFERENT requestId, no sidechain → distinct entry (counted, 55)
            + &asst("m1", "r2", "claude-x", "2026-07-01T10:05:00Z", 50, 5)
            // undated → dropped
            + &line(json!({ "type": "assistant",
                "message": { "id": "m2", "model": "claude-x", "usage": { "input_tokens": 9, "output_tokens": 9 } } }))
            // zero usage → dropped
            + &asst("m3", "r3", "<synthetic>", "2026-07-01T10:06:00Z", 0, 0)
            // synthetic model with tokens → counted (7), no model attribution
            + &asst("m4", "r4", "<synthetic>", "2026-07-01T10:07:00Z", 5, 2)
            // no type field at all (ccusage has no type gate) → counted (13)
            + &line(json!({ "timestamp": "2026-07-01T10:08:00Z", "requestId": "r5",
                "message": { "id": "m5", "model": "claude-x",
                    "usage": { "input_tokens": 10, "output_tokens": 3 } } })),
    )
    .unwrap();
    // subagent transcript, nested cache_creation breakdown + fast speed suffix (counted, 3+4+6+7=20)
    fs::write(
        deep.join("agent-a.jsonl"),
        line(json!({ "timestamp": "2026-07-01T11:00:00Z", "requestId": "r6",
            "message": { "id": "m6", "model": "claude-x",
                "usage": { "input_tokens": 3, "output_tokens": 4, "speed": "fast",
                    "cache_read_input_tokens": 6,
                    "cache_creation_input_tokens": 999,
                    "cache_creation": { "ephemeral_5m_input_tokens": 5, "ephemeral_1h_input_tokens": 2 } } } })),
    )
    .unwrap();
    // sidechain replay: reuses m1 under a NEW requestId with isSidechain → collapses onto parent
    fs::write(
        proj.join("s2.jsonl"),
        line(json!({ "type": "assistant", "timestamp": "2026-07-01T10:00:01Z", "requestId": "r9",
            "isSidechain": true,
            "message": { "id": "m1", "model": "claude-x", "usage": { "input_tokens": 100, "output_tokens": 10 } } })),
    )
    .unwrap();

    let config = json!({ "historyDirs": [ base.to_string_lossy() ] });
    let days = build_data(&config, "all");
    let (tokens, input, output, cache_read, requests, models) = sum(&days);
    // m1(110) + m1/r2(55) + m4(7) + m5(13) + m6(20)
    assert_eq!(requests, 5);
    assert_eq!(input, 100 + 50 + 5 + 10 + 3);
    assert_eq!(output, 10 + 5 + 2 + 3 + 4);
    assert_eq!(cache_read, 6);
    assert_eq!(tokens, 110 + 55 + 7 + 13 + 20);
    // synthetic tokens counted but unattributed; fast suffix applied
    assert_eq!(models.get("claude-x").copied(), Some(110 + 55 + 13));
    assert_eq!(models.get("claude-x-fast").copied(), Some(20));
    assert!(models.get("<synthetic>").is_none());

    let _ = fs::remove_dir_all(&base);
}

// History written through OLD ccbud gateway builds: every streamed response carries the
// constant id "msg_ccbud" (and often no requestId — the gateway didn't forward the header).
// Those ids must never act as de-dup keys, or weeks of history collapse into one turn.
#[test]
fn degenerate_gateway_ids_never_dedup() {
    let base = std::env::temp_dir().join(format!("ccbud-usage-degen-{}", std::process::id()));
    let _ = fs::remove_dir_all(&base);
    let proj = base.join("projects").join("-p");
    fs::create_dir_all(&proj).unwrap();
    let no_req = |ts: &str, inp: i64| {
        line(json!({ "type": "assistant", "timestamp": ts,
            "message": { "id": "msg_ccbud", "model": "glm-4.7",
                "usage": { "input_tokens": inp, "output_tokens": 1 } } }))
    };
    fs::write(
        proj.join("old-era.jsonl"),
        no_req("2026-06-20T10:00:00Z", 100)
            + &no_req("2026-06-21T10:00:00Z", 200)
            + &no_req("2026-06-22T10:00:00Z", 300)
            + &line(json!({ "type": "assistant", "timestamp": "2026-06-23T10:00:00Z", "requestId": "r1",
                "message": { "id": "chatcmpl-ccbud", "model": "glm-4.7",
                    "usage": { "input_tokens": 400, "output_tokens": 1 } } })),
    )
    .unwrap();
    let config = json!({ "historyDirs": [ base.to_string_lossy() ] });
    let days = build_data(&config, "all");
    let (_, input, _, _, requests, _) = sum(&days);
    // all four turns count — four distinct days survive
    assert_eq!(requests, 4);
    assert_eq!(input, 100 + 200 + 300 + 400);
    assert_eq!(days.len(), 4);
    let _ = fs::remove_dir_all(&base);
}

// The 对话 page's dir switcher persists synthetic views (recycle bin, imported bundles) into
// historyActive — those match no configured dir and previously zeroed every usage number.
#[test]
fn synthetic_or_stale_active_falls_back_to_all_dirs() {
    let base = std::env::temp_dir().join(format!("ccbud-usage-active-{}", std::process::id()));
    let _ = fs::remove_dir_all(&base);
    let proj = base.join("projects").join("-p");
    fs::create_dir_all(&proj).unwrap();
    fs::write(proj.join("s.jsonl"), asst("a1", "r1", "m", "2026-07-01T10:00:00Z", 10, 1)).unwrap();
    let config = json!({ "historyDirs": [ base.to_string_lossy() ] });
    for active in ["all", "__trash__", "__imported__", "/no/such/dir"] {
        let days = build_data(&config, active);
        let (tokens, ..) = sum(&days);
        assert_eq!(tokens, 11, "active={} must not zero the stats", active);
    }
    // a VALID selector still filters
    let days = build_data(&config, base.to_string_lossy().as_ref());
    let (tokens, ..) = sum(&days);
    assert_eq!(tokens, 11);
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn invalid_utf8_does_not_truncate_a_file() {
    let base = std::env::temp_dir().join(format!("ccbud-usage-u8-{}", std::process::id()));
    let _ = fs::remove_dir_all(&base);
    let proj = base.join("projects").join("-p");
    fs::create_dir_all(&proj).unwrap();
    let mut bytes = asst("u1", "r1", "m", "2026-07-01T10:00:00Z", 10, 1).into_bytes();
    bytes.extend_from_slice(b"{\"garbage\": \"\xff\xfe binary tool output\"}\n");
    bytes.extend_from_slice(asst("u2", "r2", "m", "2026-07-02T10:00:00Z", 20, 2).as_bytes());
    fs::write(proj.join("s.jsonl"), bytes).unwrap();

    let config = json!({ "historyDirs": [ base.to_string_lossy() ] });
    let days = build_data(&config, "all");
    let (_, input, _, _, requests, _) = sum(&days);
    // the record AFTER the invalid-UTF-8 line still counts
    assert_eq!(requests, 2);
    assert_eq!(input, 30);
    let _ = fs::remove_dir_all(&base);
}
