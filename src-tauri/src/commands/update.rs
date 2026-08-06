// In-app update commands and their shared state, moved verbatim from lib.rs.

use serde_json::{json, Value};
use tauri::Emitter;

use crate::store;

// ---- in-app updates ----
// In-app update state, mapped to the shape the renderer's about/update pane expects
// (runningVersion / latestVersion / mode / pending). Tauri's updater is in-app full → mode "hot".
pub(super) static UPDATE_LATEST: std::sync::Mutex<Option<(String, Option<String>)>> =
    std::sync::Mutex::new(None);
pub(super) static UPDATE_CHECKED: std::sync::Mutex<bool> = std::sync::Mutex::new(false);
pub(super) static UPDATE_STAGED: std::sync::Mutex<bool> = std::sync::Mutex::new(false);
// A download is in flight (manual or auto) — second caller gets "busy" instead of a duplicate.
pub(super) static UPDATE_DOWNLOADING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Clears an in-flight flag on drop, so a panic/unwind or an early return can never leave
/// UPDATE_DOWNLOADING / AUTO_UPDATE_RUNNING stuck true for the rest of the process.
pub(super) struct FlagGuard(pub(super) &'static std::sync::atomic::AtomicBool);
impl Drop for FlagGuard {
    fn drop(&mut self) {
        self.0.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

pub(super) fn build_update_state(app: &tauri::AppHandle) -> Value {
    let cfg = store::read_config();
    let current = app.package_info().version.to_string();
    let latest = UPDATE_LATEST.lock().ok().and_then(|g| g.clone());
    let checked = UPDATE_CHECKED.lock().map(|g| *g).unwrap_or(false);
    let staged = UPDATE_STAGED.lock().map(|g| *g).unwrap_or(false);
    let (latest_v, notes, mode) = match (&latest, checked) {
        (Some((v, n)), _) => (json!(v), n.clone().map(Value::String).unwrap_or(Value::Null), "hot"),
        (None, true) => (Value::Null, Value::Null, "none"),
        (None, false) => (Value::Null, Value::Null, "unknown"),
    };
    json!({
        "ok": true,
        "runningVersion": current,
        "shellVersion": current,
        "latestVersion": latest_v,
        "mode": mode,
        "notes": notes,
        "pending": if staged {
            json!({ "staged": true, "version": latest.as_ref().map(|(v, _)| v.clone()) })
        } else {
            Value::Null
        },
        "installMethod": "tauri",
        "autoUpdate": cfg.get("autoUpdate").cloned().unwrap_or(json!({ "check": true, "autoDownload": true })),
    })
}
#[tauri::command]
pub(crate) fn update_state(app: tauri::AppHandle) -> Value {
    build_update_state(&app)
}
/// Hit the updater endpoint and sync UPDATE_CHECKED/UPDATE_LATEST + the renderer's
/// update:state. Shared by the manual update_check command and the daily auto check.
pub(super) async fn run_update_check(app: &tauri::AppHandle) -> Result<Option<tauri_plugin_updater::Update>, String> {
    use tauri_plugin_updater::UpdaterExt;
    *UPDATE_CHECKED.lock().unwrap() = true;
    let result = match app.updater() {
        Ok(updater) => updater.check().await,
        Err(e) => Err(e),
    };
    match result {
        Ok(found) => {
            *UPDATE_LATEST.lock().unwrap() =
                found.as_ref().map(|u| (u.version.clone(), u.body.clone()));
            let _ = app.emit("update:state", build_update_state(app));
            Ok(found)
        }
        Err(e) => Err(e.to_string()),
    }
}
#[tauri::command]
pub(crate) async fn update_check(app: tauri::AppHandle) -> Result<Value, String> {
    match run_update_check(&app).await {
        Ok(_) => Ok(build_update_state(&app)),
        Err(e) => Ok(json!({
            "ok": false,
            "error": e,
            "runningVersion": app.package_info().version.to_string(),
        })),
    }
}
/// Download + stage the available update (restart applies it). Shared by the manual
/// update_download command and the daily auto flow; UPDATE_DOWNLOADING dedupes the two.
pub(super) async fn run_update_download(app: &tauri::AppHandle) -> Result<Value, String> {
    use tauri_plugin_updater::UpdaterExt;
    if UPDATE_DOWNLOADING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return Err("busy".to_string());
    }
    let _busy = FlagGuard(&UPDATE_DOWNLOADING);
    let updater = app.updater().map_err(|e| e.to_string())?;
    match updater.check().await.map_err(|e| e.to_string())? {
        Some(u) => {
            u.download_and_install(|_chunk, _total| {}, || {}).await.map_err(|e| e.to_string())?;
            *UPDATE_STAGED.lock().unwrap() = true;
            let st = build_update_state(app);
            let _ = app.emit("update:staged", st.clone());
            let _ = app.emit("update:state", st.clone());
            Ok(st)
        }
        None => Ok(json!({ "ok": true, "mode": "none" })),
    }
}
#[tauri::command]
pub(crate) async fn update_download(app: tauri::AppHandle) -> Result<Value, String> {
    run_update_download(&app).await
}
#[tauri::command]
pub(crate) fn update_apply(app: tauri::AppHandle) -> Value {
    app.restart();
}
#[tauri::command]
pub(crate) fn update_set_auto(patch: Value) -> Value {
    let mut cfg = store::read_config();
    let mut au = cfg.get("autoUpdate").cloned().unwrap_or(json!({ "check": true, "autoDownload": true }));
    if let Some(o) = au.as_object_mut() {
        if let Some(c) = patch.get("check") {
            o.insert("check".into(), c.clone());
        }
        if let Some(d) = patch.get("autoDownload") {
            o.insert("autoDownload".into(), d.clone());
        }
    }
    cfg["autoUpdate"] = au.clone();
    store::write_config(cfg);
    au
}
