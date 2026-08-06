// Conversation export commands (raw .jsonl/.db/.zip and the standalone HTML viewer), moved
// verbatim from lib.rs.

use serde_json::{json, Value};

use crate::{exporthtml, history};

use super::util::open_path_native;

#[tauri::command]
pub(crate) async fn history_export_raw(file: String) -> Result<Value, String> {
    let base = exporthtml::export_base_name(&file);
    // Antigravity sessions are SQLite DBs (not text) — export the raw bytes as .db so the
    // original conversation remains intact. Other foreign sources and Claude/Codex stay
    // verbatim text (.jsonl); sessions with subagents keep the existing zip bundle.
    let path = std::path::Path::new(&file);
    if matches!(
        history::foreign_kind(path),
        Some(history::Foreign::Antigravity)
    ) {
        let bytes = std::fs::read(&file).map_err(|e| e.to_string())?;
        return match rfd::AsyncFileDialog::new()
            .add_filter("SQLite", &["db"])
            .set_file_name(format!("{}.db", base))
            .save_file()
            .await
        {
            Some(d) => {
                let p = d.path().to_path_buf();
                std::fs::write(&p, bytes).map_err(|e| e.to_string())?;
                Ok(json!({ "canceled": false, "path": p.to_string_lossy(), "bundled": false }))
            }
            None => Ok(json!({ "canceled": true })),
        };
    }
    // A session with subagents exports as a .zip bundle (main .jsonl at the top level + subagents/);
    // a plain session stays a verbatim .jsonl. import_paths accepts either.
    if history::session_has_subagents(&file) {
        let bytes = history::export_bundle(&file).map_err(|e| e.to_string())?;
        match rfd::AsyncFileDialog::new()
            .add_filter("ZIP", &["zip"])
            .set_file_name(format!("{}.zip", base))
            .save_file()
            .await
        {
            Some(d) => {
                let p = d.path().to_path_buf();
                std::fs::write(&p, bytes).map_err(|e| e.to_string())?;
                Ok(json!({ "canceled": false, "path": p.to_string_lossy(), "bundled": true }))
            }
            None => Ok(json!({ "canceled": true })),
        }
    } else {
        let data = history::raw_session_bytes(&file).map_err(|e| e.to_string())?;
        match rfd::AsyncFileDialog::new()
            .add_filter("JSONL", &["jsonl"])
            .set_file_name(format!("{}.jsonl", base))
            .save_file()
            .await
        {
            Some(d) => {
                let p = d.path().to_path_buf();
                std::fs::write(&p, data).map_err(|e| e.to_string())?;
                Ok(json!({ "canceled": false, "path": p.to_string_lossy(), "bundled": false }))
            }
            None => Ok(json!({ "canceled": true })),
        }
    }
}
#[tauri::command]
pub(crate) async fn history_export_html(payload: Value) -> Result<Value, String> {
    let file = payload
        .get("file")
        .and_then(|v| v.as_str())
        .or_else(|| payload.as_str())
        .ok_or("no file")?
        .to_string();
    // Build the export data once, then reuse it for both the HTML body and the filename.
    let data = exporthtml::build_data(&file);
    // An unreadable main transcript surfaces as a command error (renderer reports it) instead of
    // silently saving an empty viewer page.
    if let Some(error) = data.get("error") {
        return Err(error
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("session read failed")
            .to_string());
    }
    let html = exporthtml::html_from_data(&data);
    let base = exporthtml::export_base_name_from_data(&data);
    match rfd::AsyncFileDialog::new().set_file_name(format!("{}.html", base)).save_file().await {
        Some(d) => {
            let p = d.path().to_path_buf();
            std::fs::write(&p, html).map_err(|e| e.to_string())?;
            // Open the freshly-exported viewer in the user's default browser (issue #7).
            open_path_native(&p);
            Ok(json!({ "canceled": false, "path": p.to_string_lossy() }))
        }
        None => Ok(json!({ "canceled": true })),
    }
}
