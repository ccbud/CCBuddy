// Conversation-history commands, moved verbatim from lib.rs.

use serde_json::{json, Value};
use tauri::Emitter;

use crate::{history, store};

// ---- conversation history ----
#[tauri::command]
pub(crate) fn history_projects() -> Value {
    let cfg = store::read_config();
    let active = cfg.get("historyActive").and_then(|v| v.as_str()).unwrap_or("all").to_string();
    json!(history::list_projects(&cfg, &active))
}
#[tauri::command]
pub(crate) fn history_list() -> Value {
    let cfg = store::read_config();
    let active = cfg.get("historyActive").and_then(|v| v.as_str()).unwrap_or("all").to_string();
    json!(history::list_sessions(&cfg, &active, 400))
}
#[tauri::command]
pub(crate) fn history_get(file: String) -> Value {
    history::get_session(&file)
}
#[tauri::command]
pub(crate) async fn history_search(query: String) -> Result<Value, String> {
    let cfg = store::read_config();
    let active = cfg.get("historyActive").and_then(|v| v.as_str()).unwrap_or("all").to_string();
    // Content scan is read/parse heavy — keep it off the IPC thread so the UI stays responsive.
    tauri::async_runtime::spawn_blocking(move || json!(history::search_sessions(&cfg, &active, &query, 120)))
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub(crate) fn history_dirs() -> Value {
    let cfg = store::read_config();
    let active = cfg.get("historyActive").and_then(|v| v.as_str()).unwrap_or("all").to_string();
    json!({ "dirs": history::dir_stats(&cfg), "active": active })
}
#[tauri::command]
pub(crate) async fn history_pick_dir() -> Result<Value, String> {
    let folder = rfd::AsyncFileDialog::new().set_title("选择工作目录").pick_folder().await;
    match folder {
        // Return the picked path (home-collapsed to `~/…`) and let the renderer persist it
        // via saveConfig, matching the renderer contract.
        Some(f) => {
            let mut picked = f.path().to_path_buf();
            // If the user drilled into a data subdir (projects/ = Claude, sessions/ = Codex),
            // store its parent (the work dir) so both trees are probed correctly.
            let name = picked.file_name().and_then(|n| n.to_str()).map(|s| s.to_string());
            if matches!(name.as_deref(), Some("projects") | Some("sessions"))
                && !picked.join(name.as_deref().unwrap()).is_dir()
            {
                if let Some(parent) = picked.parent() {
                    picked = parent.to_path_buf();
                }
            }
            let path = store::collapse_home(&picked.to_string_lossy());
            Ok(json!({ "ok": true, "path": path }))
        }
        None => Ok(json!({ "ok": false, "canceled": true })),
    }
}
#[tauri::command]
pub(crate) fn history_set_active(app: tauri::AppHandle, id: String) -> Value {
    let mut cfg = store::read_config();
    cfg["historyActive"] = json!(if id.is_empty() { "all".to_string() } else { id });
    let saved = store::write_config(cfg);
    let _ = app.emit(
        "history:changed",
        json!({ "files": [], "active": saved.get("historyActive").cloned().unwrap_or(json!("all")) }),
    );
    saved
}
#[tauri::command]
pub(crate) async fn history_import(app: tauri::AppHandle) -> Result<Value, String> {
    match rfd::AsyncFileDialog::new().add_filter("对话记录 (.jsonl / .zip)", &["jsonl", "zip"]).set_title("导入对话记录").pick_files().await {
        Some(files) => {
            let paths: Vec<String> = files.iter().map(|f| f.path().to_string_lossy().to_string()).collect();
            let r = history::import_paths(&paths);
            let _ = app.emit("history:changed", json!({ "files": [] }));
            Ok(r)
        }
        None => Ok(json!({ "canceled": true })),
    }
}
#[tauri::command]
pub(crate) fn history_import_paths(app: tauri::AppHandle, paths: Value) -> Value {
    let list: Vec<String> = paths
        .as_array()
        .map(|a| a.iter().filter_map(|p| p.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default();
    let r = history::import_paths(&list);
    let _ = app.emit("history:changed", json!({ "files": [] }));
    r
}
#[tauri::command]
pub(crate) fn history_remove_import(app: tauri::AppHandle, file: String) -> Value {
    let r = history::remove_import(&file);
    if r.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
        let _ = app.emit("history:changed", json!({ "files": [] }));
    }
    r
}
#[tauri::command]
pub(crate) fn history_set_meta(app: tauri::AppHandle, file: String, patch: Value) -> Value {
    let cfg = store::read_config();
    let r = history::set_ccbud(&file, &patch, &cfg);
    if r.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
        let _ = app.emit("history:changed", json!({ "files": [file] }));
    }
    r
}
#[tauri::command]
pub(crate) fn history_delete_forever(app: tauri::AppHandle, file: String) -> Value {
    let cfg = store::read_config();
    let r = history::delete_session_file(&file, &cfg);
    if r.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
        let _ = app.emit("history:changed", json!({ "files": [] }));
    }
    r
}
