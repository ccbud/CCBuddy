use super::build::build_data;
use super::tests::{line, sum};
use serde_json::json;
use std::fs;

fn tc(ts: &str, last: Option<(i64, i64, i64)>, total: Option<(i64, i64, i64)>) -> String {
    let mut info = json!({});
    if let Some((i, c, o)) = last {
        info["last_token_usage"] = json!({ "input_tokens": i, "cached_input_tokens": c, "output_tokens": o,
            "total_tokens": i + o });
    }
    if let Some((i, c, o)) = total {
        info["total_token_usage"] = json!({ "input_tokens": i, "cached_input_tokens": c, "output_tokens": o,
            "total_tokens": i + o });
    }
    line(json!({ "timestamp": ts, "type": "event_msg", "payload": { "type": "token_count", "info": info } }))
}

#[test]
fn codex_ccusage_semantics() {
    let base = std::env::temp_dir().join(format!("ccbud-usage-cx-{}", std::process::id()));
    let _ = fs::remove_dir_all(&base);
    let day = base.join("sessions").join("2026").join("07").join("01");
    fs::create_dir_all(&day).unwrap();

    // main session: model from turn_context; one last_token_usage turn; one turn WITHOUT
    // last (only cumulative total) → counted as the diff from the baseline.
    fs::write(
        day.join("rollout-a.jsonl"),
        line(json!({ "timestamp": "2026-07-01T12:00:00Z", "type": "session_meta", "payload": { "id": "a" } }))
            + &line(json!({ "timestamp": "2026-07-01T12:00:01Z", "type": "turn_context", "payload": { "model": "gpt-5.5" } }))
            + &tc("2026-07-01T12:00:02Z", Some((900, 600, 80)), Some((900, 600, 80)))
            + &tc("2026-07-01T12:00:03Z", None, Some((1400, 900, 130))) // diff: 500/300/50
            + &tc("2026-07-01T12:00:04Z", None, None), // info without usage → skipped
    )
    .unwrap();
    // resumed copy of the same session: identical events must de-dup, a new turn counts.
    fs::write(
        day.join("rollout-b.jsonl"),
        line(json!({ "timestamp": "2026-07-01T12:10:00Z", "type": "turn_context", "payload": { "model": "gpt-5.5" } }))
            + &tc("2026-07-01T12:00:02Z", Some((900, 600, 80)), None) // duplicate of a's turn 1
            + &tc("2026-07-01T12:10:01Z", Some((10, 0, 5)), None), // new turn (15)
    )
    .unwrap();
    // archived copy of rollout-a (same relative path) → file-level de-dup, never read twice.
    let arch = base.join("archived_sessions").join("2026").join("07").join("01");
    fs::create_dir_all(&arch).unwrap();
    fs::write(arch.join("rollout-a.jsonl"), tc("2026-07-01T12:00:02Z", Some((900, 600, 80)), None)).unwrap();
    // thread_spawn subagent: leading replay burst (same second) skipped, own turn counted,
    // and the baseline carried from the replayed cumulative total.
    fs::write(
        day.join("rollout-sub.jsonl"),
        line(json!({ "timestamp": "2026-07-01T13:00:00Z", "type": "session_meta",
            "payload": { "id": "sub", "source": { "type": "thread_spawn" } } }))
            + &tc("2026-07-01T13:00:01Z", Some((900, 600, 80)), Some((900, 600, 80)))
            + &tc("2026-07-01T13:00:01Z", Some((500, 300, 50)), Some((1400, 900, 130)))
            + &tc("2026-07-01T13:00:05Z", None, Some((1600, 900, 160))), // own turn: diff 200/0/30
    )
    .unwrap();

    let config = json!({ "historyDirs": [ base.to_string_lossy() ] });
    let days = build_data(&config, "all");
    let (tokens, input, output, cache_read, requests, models) = sum(&days);
    // a#1: in 900 (cached 600) out 80 → input 300, cacheRead 600, out 80  (980)
    // a#2 (diff): in 500 (cached 300) out 50 → input 200, cacheRead 300, out 50 (550)
    // b#2: 10/0/5 (15)
    // sub own turn: 200/0/30 (230)
    assert_eq!(requests, 4);
    assert_eq!(input, 300 + 200 + 10 + 200);
    assert_eq!(cache_read, 600 + 300);
    assert_eq!(output, 80 + 50 + 5 + 30);
    assert_eq!(tokens, 980 + 550 + 15 + 230);
    assert_eq!(models.get("gpt-5.5").copied(), Some(980 + 550 + 15));
    // subagent file had no turn_context → fallback model
    assert_eq!(models.get("gpt-5").copied(), Some(230));

    let _ = fs::remove_dir_all(&base);
}
