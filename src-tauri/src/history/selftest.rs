use serde_json::{json, Value};
use std::fs;
use std::path::Path;

use super::edit::set_ccbud;
use super::importpaths::{import_paths, remove_import};
use super::list::list_sessions;
use super::paths::imports_root;
use super::session::get_session;
use super::subagents::export_bundle;
use super::TRASH_ID;

/// Self-contained round-trip test of set_ccbud + get_session in a throwaway projects tree.
pub fn history_selftest(base_dir: &Path) -> Value {
    let proj = base_dir.join("test-claude").join("projects").join("-test-cwd");
    let _ = fs::create_dir_all(&proj);
    let file = proj.join("sess1.jsonl");
    let content = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello world from selfcheck\"},\"cwd\":\"/test/cwd\",\"sessionId\":\"sess1\",\"timestamp\":\"2025-01-01T10:00:00.000Z\"}\n";
    let _ = fs::write(&file, content);
    let config = json!({ "historyDirs": [ base_dir.join("test-claude").to_string_lossy() ] });
    let fpath = file.to_string_lossy().to_string();
    let set = set_ccbud(&fpath, &json!({ "title": "My Title", "tags": ["a", "b", "b"] }), &config);
    let sess = get_session(&fpath);
    let title = sess.get("meta").and_then(|m| m.get("title")).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let tags = sess.get("meta").and_then(|m| m.get("tags")).and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
    let auto = sess.get("meta").and_then(|m| m.get("autoTitle")).and_then(|v| v.as_str()).unwrap_or("").to_string();
    // Soft-delete round-trip: marked → hidden from "all" but present in trash → restored → back in "all".
    let _ = set_ccbud(&fpath, &json!({ "delete": true }), &config);
    let after_del = get_session(&fpath).get("meta").and_then(|m| m.get("deleted")).and_then(|v| v.as_bool()).unwrap_or(false);
    let hidden_in_all = !list_sessions(&config, "all", 50).iter().any(|s| s.get("file").and_then(|v| v.as_str()) == Some(fpath.as_str()));
    let shown_in_trash = list_sessions(&config, TRASH_ID, 50).iter().any(|s| s.get("file").and_then(|v| v.as_str()) == Some(fpath.as_str()));
    let _ = set_ccbud(&fpath, &json!({ "delete": false }), &config);
    let restored = !get_session(&fpath).get("meta").and_then(|m| m.get("deleted")).and_then(|v| v.as_bool()).unwrap_or(false);
    json!({
        "setOk": set.get("ok").and_then(|v| v.as_bool()).unwrap_or(false),
        "title": title,
        "tagCount": tags,
        "autoTitle": auto,
        "deletedAfterMark": after_del,
        "hiddenInAll": hidden_in_all,
        "shownInTrash": shown_in_trash,
        "restored": restored,
    })
}

/// Self-contained test of import → list-as-imported → re-import-skip → remove.
pub fn import_selftest(base_dir: &Path) -> Value {
    std::env::set_var("CCBUD_HOME", base_dir); // imports_root() honors CCBUD_HOME
    let src_dir = base_dir.join("import-src");
    let _ = fs::create_dir_all(&src_dir);
    let src = src_dir.join("foreign.jsonl");
    let _ = fs::write(&src, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"imported hello\"},\"cwd\":\"/imp/cwd\",\"sessionId\":\"impsess\",\"timestamp\":\"2025-01-01T10:00:00.000Z\"}\n");
    let srcs = vec![src.to_string_lossy().to_string()];
    let r = import_paths(&srcs);
    let r2 = import_paths(&srcs);
    let config = json!({ "historyDirs": ["~/.claude"] });
    let sessions = list_sessions(&config, "__imported__", 50);
    let found = sessions.iter().any(|s| {
        s.get("imported").and_then(|v| v.as_bool()).unwrap_or(false)
            && s.get("title").and_then(|v| v.as_str()) == Some("imported hello")
    });
    let dest = imports_root().join("projects").join("-imp-cwd").join("impsess.jsonl");
    let rm = remove_import(&dest.to_string_lossy());

    // ---- bundle round-trip: a session WITH subagents exports as a .zip and re-imports with its
    // subagent transcripts restored (the export → import path the 对话 view drives). ----
    let bproj = base_dir.join("bundle-src").join("projects").join("-bnd-cwd");
    let _ = fs::create_dir_all(&bproj);
    let bmain = bproj.join("bundsess.jsonl");
    let _ = fs::write(&bmain, "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"tu9\",\"name\":\"Task\",\"input\":{}}]},\"cwd\":\"/bnd/cwd\",\"sessionId\":\"bundsess\",\"timestamp\":\"2025-01-01T10:00:00.000Z\"}\n");
    let bsub = bproj.join("bundsess").join("subagents");
    let _ = fs::create_dir_all(&bsub);
    let _ = fs::write(bsub.join("agent-b1.jsonl"), "{\"type\":\"assistant\",\"isSidechain\":true,\"agentId\":\"b1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"sub done\"}]},\"sessionId\":\"bundsess\",\"timestamp\":\"2025-01-01T10:00:01.000Z\"}\n");
    let _ = fs::write(bsub.join("agent-b1.meta.json"), "{\"agentType\":\"general-purpose\",\"description\":\"d\",\"toolUseId\":\"tu9\"}");
    let zip = export_bundle(&bmain.to_string_lossy()).unwrap_or_default();
    let zip_is_zip = zip.starts_with(&[0x50, 0x4b, 0x03, 0x04]);
    let zip_path = base_dir.join("bundle-src").join("bundsess.zip");
    let _ = fs::write(&zip_path, &zip);
    let rb = import_paths(&[zip_path.to_string_lossy().to_string()]);
    let imp_dir = imports_root().join("projects").join("-bnd-cwd");
    let sub_restored = imp_dir.join("bundsess").join("subagents").join("agent-b1.jsonl").exists()
        && imp_dir.join("bundsess").join("subagents").join("agent-b1.meta.json").exists();
    let bundle_sess = get_session(&imp_dir.join("bundsess.jsonl").to_string_lossy());
    let bundle_sub_count = bundle_sess.get("meta").and_then(|m| m.get("subagentCount")).and_then(|v| v.as_i64()).unwrap_or(0);

    json!({
        "imported": r.get("imported"),
        "reskipped": r2.get("skipped"),
        "appearsImported": found,
        "removed": rm.get("ok"),
        "gone": !dest.exists(),
        "bundleZip": zip_is_zip,
        "bundleImported": rb.get("imported"),
        "bundleSubRestored": sub_restored,
        "bundleSubagentCount": bundle_sub_count,
    })
}
