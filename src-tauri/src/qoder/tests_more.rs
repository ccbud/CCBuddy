use super::*;
use super::guard::validated_qoder_data_path;
use super::prefetch::b64_decode;
use super::read::{helper_cache_get, helper_cache_put};
use serde_json::json;
use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;

fn test_dir(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("ccbud-qoder-{name}-{}", std::process::id()))
}

#[test]
fn decodes_batch_helper_base64() {
    assert_eq!(b64_decode("").unwrap(), b"");
    assert_eq!(b64_decode("aGVsbG8=").unwrap(), b"hello");
    assert_eq!(b64_decode("aGVsbG8h").unwrap(), b"hello!");
    assert_eq!(b64_decode("aA==").unwrap(), b"h");
    assert_eq!(b64_decode("5Lit5paH").unwrap(), "中文".as_bytes());
    assert!(b64_decode("not base64!").is_none());
    assert!(b64_decode("aGVsbG8").is_none()); // truncated group
}

#[test]
fn helper_cache_serves_only_fresh_stamps() {
    let path = test_dir("cache").join("t.jsonl");
    assert!(helper_cache_get(&path, 1.0, 10).is_none());
    helper_cache_put(&path, 1.0, 10, Arc::new(b"v1".to_vec()));
    assert_eq!(helper_cache_get(&path, 1.0, 10).unwrap(), b"v1");
    // a changed mtime or size means a new file version — the stale entry must not serve
    assert!(helper_cache_get(&path, 2.0, 10).is_none());
    assert!(helper_cache_get(&path, 1.0, 11).is_none());
    helper_cache_put(&path, 2.0, 10, Arc::new(b"v2".to_vec()));
    assert_eq!(helper_cache_get(&path, 2.0, 10).unwrap(), b"v2");
}

#[test]
fn sniffs_qoder_records_by_inline_vocabulary() {
    assert!(looks_qoder_records(&[json!({ "type": "ai-title", "aiTitle": "t" })]));
    assert!(looks_qoder_records(&[
        json!({ "type": "user", "message": { "content": "hi" } }),
        json!({ "type": "attachment", "attachment": { "type": "queued_command", "prompt": "p" } }),
    ]));
    // plain Claude / Codex shapes must not sniff as qoder
    assert!(!looks_qoder_records(&[
        json!({ "type": "user", "message": { "content": "hi" }, "cwd": "/x" }),
        json!({ "type": "assistant", "message": { "role": "assistant", "content": [] } }),
        json!({ "type": "attachment", "attachment": { "type": "file" } }),
        json!({ "type": "session_meta", "payload": {} }),
    ]));
}

#[test]
fn ordinary_reads_do_not_require_a_qoder_path() {
    let dir = test_dir("ordinary-read");
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let file = dir.join("ordinary.txt");
    fs::write(&file, "local UTF-8 文本").unwrap();

    assert_eq!(read_bytes(&file).unwrap(), "local UTF-8 文本".as_bytes());
    assert_eq!(read_text(&file).unwrap(), "local UTF-8 文本");

    fs::write(&file, [0xff, 0xfe]).unwrap();
    assert_eq!(
        read_text(&file).unwrap_err().kind(),
        io::ErrorKind::InvalidData
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn helper_target_is_limited_to_canonical_qoder_project_data() {
    let dir = test_dir("path-validation");
    let _ = fs::remove_dir_all(&dir);
    let projects = dir.join(".qoder").join("projects");
    let session = projects.join("-encoded-cwd").join("session-id");
    fs::create_dir_all(&session).unwrap();

    let transcript = projects.join("-encoded-cwd").join("session-id.jsonl");
    let state = session.join("state.json");
    let metadata = session.join("agent-worker.meta.json");
    fs::write(&transcript, "{}\n").unwrap();
    fs::write(&state, "{}").unwrap();
    fs::write(&metadata, "{}").unwrap();

    for file in [&transcript, &state, &metadata] {
        let (validated, root) = validated_qoder_data_path(file).unwrap();
        assert_eq!(validated, fs::canonicalize(file).unwrap());
        assert_eq!(root, fs::canonicalize(dir.join(".qoder")).unwrap());
    }

    let arbitrary = session.join("secret.txt");
    fs::write(&arbitrary, "not helper-readable").unwrap();
    assert_eq!(
        validated_qoder_data_path(&arbitrary).unwrap_err().kind(),
        io::ErrorKind::PermissionDenied
    );

    let outside = dir.join("outside.jsonl");
    fs::write(&outside, "{}\n").unwrap();
    assert_eq!(
        validated_qoder_data_path(&outside).unwrap_err().kind(),
        io::ErrorKind::PermissionDenied
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::symlink;
        let escaped = session.join("escaped.jsonl");
        symlink(&outside, &escaped).unwrap();
        assert_eq!(
            validated_qoder_data_path(&escaped).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
    }

    let _ = fs::remove_dir_all(&dir);
}
