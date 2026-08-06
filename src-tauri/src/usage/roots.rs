// Active work-dir resolution and the local-timezone day-key math every aggregation stage keys
// on. Moved verbatim from usage.rs.

use chrono::{Datelike, Local, TimeZone, Timelike};
use serde_json::Value;
use std::path::PathBuf;

pub(super) const DAY_MS: i64 = 86_400_000;
pub(super) const HEATMAP_WEEKS: i64 = 26;

fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}
pub(super) fn expand_tilde(p: &str) -> PathBuf {
    if let Some(rest) = p.strip_prefix("~/") {
        home().join(rest)
    } else if p == "~" {
        home()
    } else {
        PathBuf::from(p)
    }
}

/// Active work dirs (honors the directory switcher). A selector that matches no configured dir —
/// the synthetic recycle-bin / imported-bundle views ("__trash__", "__imported__"), or a stale
/// value from an older config — falls back to ALL dirs: a filter must never zero the stats.
pub(super) fn active_roots(config: &Value, active: &str) -> Vec<PathBuf> {
    let mut all = vec![];
    let mut selected = vec![];
    if let Some(arr) = config.get("historyDirs").and_then(|v| v.as_array()) {
        for d in arr {
            if let Some(s) = d.as_str() {
                all.push(expand_tilde(s));
                if active == s {
                    selected.push(expand_tilde(s));
                }
            }
        }
    }
    if active != "all" && !selected.is_empty() {
        selected
    } else {
        all
    }
}

pub(super) fn parse_ts(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp_millis())
}
pub(super) fn key_of(ms: i64) -> String {
    match Local.timestamp_millis_opt(ms).single() {
        Some(d) => format!("{:04}-{:02}-{:02}", d.year(), d.month(), d.day()),
        None => "1970-01-01".to_string(),
    }
}
pub(super) fn start_of_day(ms: i64) -> i64 {
    match Local.timestamp_millis_opt(ms).single() {
        Some(d) => {
            let day = d.date_naive().and_hms_opt(0, 0, 0).unwrap();
            Local.from_local_datetime(&day).single().map(|x| x.timestamp_millis()).unwrap_or(ms)
        }
        None => ms,
    }
}
pub(super) fn ms_of_key(k: &str) -> i64 {
    let parts: Vec<i64> = k.split('-').filter_map(|x| x.parse().ok()).collect();
    if parts.len() != 3 {
        return 0;
    }
    let nd = chrono::NaiveDate::from_ymd_opt(parts[0] as i32, parts[1] as u32, parts[2] as u32);
    match nd.and_then(|d| d.and_hms_opt(0, 0, 0)) {
        Some(dt) => Local.from_local_datetime(&dt).single().map(|x| x.timestamp_millis()).unwrap_or(0),
        None => 0,
    }
}
pub(super) fn hour_of(ms: i64) -> u32 {
    Local.timestamp_millis_opt(ms).single().map(|d| d.hour()).unwrap_or(0)
}
