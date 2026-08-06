use super::content::b64_encode;
use super::roots::looks_agy_path;
use super::steps::push_step;
use crate::history::Norm;
use std::path::Path;

// hand-rolled wire encoding helpers (tests only)
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
fn tag(field: u32, wt: u8, out: &mut Vec<u8>) {
    enc_varint(((field as u64) << 3) | wt as u64, out);
}
fn put_varint(field: u32, v: u64, out: &mut Vec<u8>) {
    tag(field, 0, out);
    enc_varint(v, out);
}
fn put_bytes(field: u32, data: &[u8], out: &mut Vec<u8>) {
    tag(field, 2, out);
    enc_varint(data.len() as u64, out);
    out.extend_from_slice(data);
}
fn put_str(field: u32, s: &str, out: &mut Vec<u8>) {
    put_bytes(field, s.as_bytes(), out);
}
fn ts_msg(secs: u64) -> Vec<u8> {
    let mut m = vec![];
    put_varint(1, secs, &mut m);
    put_varint(2, 500_000_000, &mut m);
    m
}

fn user_step(text: &str) -> Vec<u8> {
    let mut meta5 = vec![];
    put_bytes(1, &ts_msg(1_783_811_237), &mut meta5);
    let mut u19 = vec![];
    put_str(2, text, &mut u19);
    let mut att = vec![];
    put_str(1, "image/png", &mut att);
    put_bytes(2, b"ABC", &mut att);
    put_str(5, "/tmp/x.png", &mut att);
    put_bytes(9, &att, &mut u19);
    let mut step = vec![];
    put_varint(1, 14, &mut step);
    put_varint(4, 3, &mut step);
    put_bytes(5, &meta5, &mut step);
    put_bytes(19, &u19, &mut step);
    step
}

fn tool_step() -> Vec<u8> {
    let mut call = vec![];
    put_str(1, "call-9", &mut call);
    put_str(2, "run_command", &mut call);
    put_str(3, "{\"CommandLine\":\"ls -la\",\"Cwd\":\"/tmp\",\"toolSummary\":\"Run\"}", &mut call);
    let mut meta5 = vec![];
    put_bytes(1, &ts_msg(1_783_811_240), &mut meta5);
    put_bytes(4, &call, &mut meta5);
    let mut step = vec![];
    put_varint(1, 21, &mut step);
    put_varint(4, 3, &mut step);
    put_bytes(5, &meta5, &mut step);
    step
}

fn gen_step(text: &str) -> Vec<u8> {
    let mut stats = vec![];
    put_varint(1, 1132, &mut stats);
    put_varint(2, 20245, &mut stats);
    put_varint(3, 346, &mut stats);
    let mut meta5 = vec![];
    put_bytes(1, &ts_msg(1_783_811_242), &mut meta5);
    put_bytes(9, &stats, &mut meta5);
    let mut t20 = vec![];
    put_str(1, text, &mut t20);
    let mut step = vec![];
    put_varint(1, 15, &mut step);
    put_varint(4, 3, &mut step);
    put_bytes(5, &meta5, &mut step);
    put_bytes(20, &t20, &mut step);
    step
}

#[test]
fn decodes_steps() {
    let mut n = Norm::default();
    push_step(&mut n, &user_step("修复登录"));
    push_step(&mut n, &tool_step());
    push_step(&mut n, &gen_step("已修复。"));
    assert_eq!(n.messages.len(), 3);
    assert_eq!(n.messages[0]["role"], "user");
    assert_eq!(n.messages[0]["content"][0]["text"], "修复登录");
    assert_eq!(n.messages[0]["content"][1]["type"], "image");
    assert_eq!(n.messages[0]["content"][1]["source"]["data"], "QUJD");
    let tool = &n.messages[1]["content"][0];
    assert_eq!(tool["name"], "Bash");
    assert_eq!(tool["input"]["command"], "ls -la");
    assert_eq!(tool["id"], "call-9");
    assert_eq!(n.messages[2]["content"][0]["text"], "已修复。");
    assert_eq!(n.messages[2]["usage"]["inputTokens"], 20245);
    assert_eq!(n.messages[2]["usage"]["outputTokens"], 346);
    assert_eq!(n.totals["in"], 20245);
    assert_eq!(n.totals["turns"], 1);
    assert!(n.messages[0]["ts"].as_str().unwrap().starts_with("2026-"));
}

#[test]
fn garbage_payload_is_skipped() {
    let mut n = Norm::default();
    push_step(&mut n, &[0xff, 0x00, 0x13, 0x37]);
    push_step(&mut n, b"");
    assert!(n.messages.is_empty());
}

#[test]
fn b64_matches_reference() {
    assert_eq!(b64_encode(b"ABC"), "QUJD");
    assert_eq!(b64_encode(b"AB"), "QUI=");
    assert_eq!(b64_encode(b"A"), "QQ==");
    assert_eq!(b64_encode(b""), "");
}

#[test]
fn detects_paths() {
    assert!(looks_agy_path(Path::new("/x/antigravity-cli/conversations/ab-1.db")));
    assert!(!looks_agy_path(Path::new("/x/antigravity-cli/conversation_summaries.db")));
    assert!(!looks_agy_path(Path::new("/x/conversations/notes.txt")));
}
