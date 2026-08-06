use super::bundle::split_bundle;
use super::read::read;
use super::write::{build, crc32, Entry};

#[test]
fn crc32_check_value() {
    // Standard CRC-32 check value for "123456789".
    assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
}

#[test]
fn round_trips_store_and_deflate() {
    let big = b"{\"type\":\"assistant\"}\n".repeat(4000); // very compressible → DEFLATE
    let bin = vec![0u8, 1, 2, 3, 255, 254, 10, 13, 0, 42];
    let entries = vec![
        Entry { name: "main.jsonl".into(), data: b"hi\n".to_vec() },
        Entry { name: "subagents/agent-aaa.jsonl".into(), data: big.clone() },
        Entry { name: "subagents/agent-aaa.meta.json".into(), data: b"{\"toolUseId\":\"tu1\"}".to_vec() },
        Entry { name: "blob.bin".into(), data: bin.clone() },
    ];
    let zip = build(&entries);
    assert_eq!(u32::from_le_bytes([zip[0], zip[1], zip[2], zip[3]]), 0x0403_4b50);
    assert!(zip.len() < big.len(), "deflate should shrink: zip={} raw={}", zip.len(), big.len());

    let read_back = read(&zip);
    assert_eq!(read_back.len(), entries.len());
    for src in &entries {
        let got = read_back.iter().find(|r| r.name == src.name).expect("entry present");
        assert_eq!(got.data, src.data, "payload mismatch for {}", src.name);
    }
}

#[test]
fn split_bundle_recovers_main_and_subagents() {
    let entries = vec![
        Entry { name: "main.jsonl".into(), data: b"m".to_vec() },
        Entry { name: "subagents/agent-aaa.jsonl".into(), data: b"a".to_vec() },
        Entry { name: "subagents/agent-aaa.meta.json".into(), data: b"{}".to_vec() },
        Entry { name: "blob.bin".into(), data: b"x".to_vec() },
    ];
    let (main, subs) = split_bundle(entries);
    assert_eq!(main.as_ref().map(|(n, _)| n.as_str()), Some("main.jsonl"));
    assert_eq!(subs.len(), 2);
    assert!(subs.iter().all(|(n, _)| !n.contains('/')));
    assert!(subs.iter().any(|(n, _)| n == "agent-aaa.meta.json"));
}

#[test]
fn split_bundle_tolerates_wrapping_folder() {
    let entries = vec![
        Entry { name: "bundle/sess.jsonl".into(), data: b"m".to_vec() },
        Entry { name: "bundle/subagents/agent-x.jsonl".into(), data: b"a".to_vec() },
    ];
    let (main, subs) = split_bundle(entries);
    assert_eq!(main.as_ref().map(|(n, _)| n.as_str()), Some("sess.jsonl"));
    assert_eq!(subs.len(), 1);
}

#[test]
fn read_tolerates_garbage() {
    assert_eq!(read(b"not a zip at all").len(), 0);
    assert_eq!(read(&[]).len(), 0);
}
