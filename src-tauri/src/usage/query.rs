// Range selection, streaks, heatmap and the stats payload the renderer consumes. Moved verbatim
// from usage.rs.

use chrono::{Datelike, Local, TimeZone};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

use super::model::Day;
use super::roots::{key_of, ms_of_key, start_of_day, DAY_MS, HEATMAP_WEEKS};

fn range_keys(days: &HashMap<String, Day>, range: &str, now: i64) -> Vec<String> {
    let mut all: Vec<String> = days.keys().cloned().collect();
    all.sort();
    if range == "all" {
        return all;
    }
    let n = match range {
        "1d" => 1,
        "30d" => 30,
        _ => 7,
    };
    let cut = start_of_day(now - (n - 1) * DAY_MS);
    all.into_iter().filter(|k| ms_of_key(k) >= cut).collect()
}

fn top_key(map: &HashMap<String, i64>) -> Option<String> {
    map.iter().max_by_key(|(_, v)| **v).map(|(k, _)| k.clone())
}

fn streaks(days: &HashMap<String, Day>, now: i64) -> (i64, i64) {
    let mut active: Vec<i64> = days
        .iter()
        .filter(|(_, d)| d.requests > 0)
        .map(|(k, _)| ms_of_key(k))
        .collect();
    active.sort();
    let set: HashSet<i64> = active.iter().cloned().collect();
    let (mut longest, mut run, mut prev): (i64, i64, Option<i64>) = (0, 0, None);
    for t in &active {
        run = if prev.map(|p| t - p == DAY_MS).unwrap_or(false) { run + 1 } else { 1 };
        prev = Some(*t);
        if run > longest {
            longest = run;
        }
    }
    let mut cur = 0;
    let mut t = start_of_day(now);
    if !set.contains(&t) {
        t -= DAY_MS;
    }
    while set.contains(&t) {
        cur += 1;
        t -= DAY_MS;
    }
    (cur, longest)
}

fn build_heatmap(days: &HashMap<String, Day>, weeks: i64, now: i64) -> Vec<Value> {
    let today = start_of_day(now);
    let span = weeks * 7;
    let mut start = today - (span - 1) * DAY_MS;
    let dow = Local.timestamp_millis_opt(start).single().map(|d| d.weekday().num_days_from_sunday() as i64).unwrap_or(0);
    start -= dow * DAY_MS;
    let mut cells: Vec<(String, i64)> = vec![];
    let mut max = 1i64;
    let mut t = start;
    while t <= today {
        let k = key_of(t);
        let tok = days.get(&k).map(|d| d.tokens).unwrap_or(0);
        if tok > max {
            max = tok;
        }
        cells.push((k, tok));
        t += DAY_MS;
    }
    cells
        .into_iter()
        .map(|(date, tokens)| {
            let r = tokens as f64 / max as f64;
            let level = if tokens == 0 {
                0
            } else if r > 0.66 {
                4
            } else if r > 0.33 {
                3
            } else if r > 0.1 {
                2
            } else {
                1
            };
            json!({ "date": date, "tokens": tokens, "level": level })
        })
        .collect()
}

pub(super) fn query(days: &HashMap<String, Day>, range: &str, now: i64) -> Value {
    let keys = range_keys(days, range, now);
    let (mut tokens, mut input, mut output, mut cache_read, mut cache_creation, mut requests) = (0i64, 0i64, 0i64, 0i64, 0i64, 0i64);
    let mut models: HashMap<String, i64> = HashMap::new();
    let mut providers: HashMap<String, i64> = HashMap::new();
    let mut hours: HashMap<u32, i64> = HashMap::new();
    let mut active_days = 0;
    for k in &keys {
        if let Some(d) = days.get(k) {
            tokens += d.tokens;
            input += d.input;
            output += d.output;
            cache_read += d.cache_read;
            cache_creation += d.cache_creation;
            requests += d.requests;
            if d.requests > 0 {
                active_days += 1;
            }
            for (m, v) in &d.models {
                *models.entry(m.clone()).or_insert(0) += v;
            }
            for (p, v) in &d.providers {
                *providers.entry(p.clone()).or_insert(0) += v;
            }
            for (h, v) in &d.hours {
                *hours.entry(*h).or_insert(0) += v;
            }
        }
    }
    let mut by_model: Vec<Value> = models
        .iter()
        .map(|(m, t)| json!({ "model": m, "tokens": t, "pct": if tokens > 0 { *t as f64 / tokens as f64 } else { 0.0 } }))
        .collect();
    by_model.sort_by(|a, b| b["tokens"].as_i64().unwrap_or(0).cmp(&a["tokens"].as_i64().unwrap_or(0)));
    let mut by_provider: Vec<Value> = providers
        .iter()
        .map(|(p, t)| json!({ "provider": p, "tokens": t, "pct": if tokens > 0 { *t as f64 / tokens as f64 } else { 0.0 } }))
        .collect();
    by_provider.sort_by(|a, b| b["tokens"].as_i64().unwrap_or(0).cmp(&a["tokens"].as_i64().unwrap_or(0)));
    let peak_hour = hours.iter().max_by_key(|(_, v)| **v).map(|(h, _)| *h as i64);
    let (cur, longest) = streaks(days, now);

    json!({
        "range": range,
        "tokens": tokens, "input": input, "output": output, "cacheRead": cache_read, "cacheCreation": cache_creation,
        "requests": requests, "activeDays": active_days,
        "peakHour": peak_hour,
        "favoriteModel": top_key(&models),
        "favoriteProvider": top_key(&providers),
        "byModel": by_model,
        "byProvider": by_provider,
        "currentStreak": cur,
        "longestStreak": longest,
        "heatmap": build_heatmap(days, HEATMAP_WEEKS, now),
    })
}
