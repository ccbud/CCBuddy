// The per-day bucket, the counted usage event both trees produce, and the two file-walking
// primitives they share. Moved verbatim from usage.rs.

use std::collections::HashMap;
use std::io::BufRead;
use std::path::{Path, PathBuf};

use super::roots::{hour_of, key_of};

#[derive(Default, Clone)]
pub(super) struct Day {
    pub(super) tokens: i64,
    pub(super) input: i64,
    pub(super) output: i64,
    pub(super) cache_read: i64,
    pub(super) cache_creation: i64,
    pub(super) requests: i64,
    pub(super) models: HashMap<String, i64>,
    pub(super) providers: HashMap<String, i64>,
    pub(super) hours: HashMap<u32, i64>,
}

/// One counted usage event, whichever tree it came from.
pub(super) struct UsageRec {
    pub(super) ts: i64,
    pub(super) model: Option<String>,
    pub(super) input: i64,
    pub(super) output: i64,
    pub(super) cache_read: i64,
    pub(super) cache_creation: i64,
}

impl UsageRec {
    pub(super) fn total(&self) -> i64 {
        self.input + self.output + self.cache_read + self.cache_creation
    }
}

pub(super) fn bump(days: &mut HashMap<String, Day>, rec: &UsageRec) {
    let day = days.entry(key_of(rec.ts)).or_default();
    day.requests += 1;
    day.tokens += rec.total();
    day.input += rec.input;
    day.output += rec.output;
    day.cache_read += rec.cache_read;
    day.cache_creation += rec.cache_creation;
    if let Some(m) = &rec.model {
        *day.models.entry(m.clone()).or_insert(0) += rec.total();
    }
    *day.hours.entry(hour_of(rec.ts)).or_insert(0) += rec.total();
}

/// Recursively collect `*.jsonl` under `dir`, any depth (ccusage walks the whole tree — nested
/// session dirs and subagent transcripts are picked up by construction). Depth-capped as a
/// symlink-loop guard.
pub(super) fn collect_jsonl(dir: &Path, depth: u32, out: &mut Vec<PathBuf>) {
    if depth > 8 {
        return;
    }
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for ent in entries.flatten() {
        let p = ent.path();
        if p.is_dir() {
            collect_jsonl(&p, depth + 1, out);
        } else if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            out.push(p);
        }
    }
}

/// Byte-based lossy line reader. History files can embed invalid UTF-8 inside tool output —
/// a strict `BufRead::lines` errors there and would silently discard the REST of the file
/// (ccusage reads raw bytes for the same reason).
pub(super) struct LossyLines {
    reader: std::io::BufReader<std::fs::File>,
    buf: Vec<u8>,
}

impl LossyLines {
    pub(super) fn open(file: &Path) -> Option<Self> {
        std::fs::File::open(file)
            .ok()
            .map(|f| Self { reader: std::io::BufReader::new(f), buf: Vec::with_capacity(64 * 1024) })
    }
    pub(super) fn next_line(&mut self) -> Option<String> {
        self.buf.clear();
        match self.reader.read_until(b'\n', &mut self.buf) {
            Ok(0) | Err(_) => None,
            Ok(_) => Some(String::from_utf8_lossy(&self.buf).into_owned()),
        }
    }
}
