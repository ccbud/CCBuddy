// Plugin (sidecar coding-agent backend) commands, moved verbatim from lib.rs.

use serde_json::{json, Value};

use crate::plugin;

// ---- plugins (sidecar coding-agent backends, see plugin.rs) ----
pub(super) type PluginState<'a> = tauri::State<'a, std::sync::Arc<plugin::PluginManager>>;

/// List discovered plugins with running + auth status.
#[tauri::command]
pub(crate) async fn plugin_list(pm: PluginState<'_>) -> Result<Value, String> {
    Ok(pm.list().await)
}
/// Single plugin status snapshot.
#[tauri::command]
pub(crate) async fn plugin_status(pm: PluginState<'_>, id: String) -> Result<Value, String> {
    Ok(pm.status(&id).await)
}
/// Enable (spawn + health-gate + register provider) or disable (stop the process; the service stays until uninstalled) a plugin.
#[tauri::command]
pub(crate) async fn plugin_set_enabled(pm: PluginState<'_>, id: String, enabled: bool) -> Result<Value, String> {
    if enabled {
        pm.start(&id).await?;
    } else {
        pm.stop(&id)?;
    }
    Ok(pm.status(&id).await)
}
/// Run a plugin-declared UI action: forward form `values` to its control plane.
#[tauri::command]
pub(crate) async fn plugin_action(pm: PluginState<'_>, id: String, action: String, values: Value) -> Result<Value, String> {
    pm.action(&id, &action, values).await
}
/// Prefill a plugin action form with the plugin's current values.
#[tauri::command]
pub(crate) async fn plugin_action_load(pm: PluginState<'_>, id: String, action: String) -> Result<Value, String> {
    pm.action_load(&id, &action).await
}
/// Add a plugin: pick a local folder containing plugin.json and install it.
/// `title` is the localized folder-picker title (supplied by the renderer).
#[tauri::command]
pub(crate) async fn plugin_install(pm: PluginState<'_>, title: Option<String>) -> Result<Value, String> {
    let title = title.filter(|t| !t.trim().is_empty()).unwrap_or_else(|| "Select the plugin folder".into());
    let picked = rfd::AsyncFileDialog::new()
        .set_title(&title)
        .pick_folder()
        .await;
    let dir = match picked {
        Some(f) => f.path().to_path_buf(),
        None => return Ok(json!({ "canceled": true })),
    };
    let id = pm.install(&dir)?;
    Ok(json!({ "ok": true, "id": id }))
}
/// Remove a plugin (the renderer confirms first): stop it, drop its service, delete its files.
#[tauri::command]
pub(crate) async fn plugin_uninstall(pm: PluginState<'_>, id: String) -> Result<Value, String> {
    // The confirmation is shown by the renderer (localized confirmDialog) before
    // this is called, so we just do the work here.
    pm.uninstall(&id)?;
    Ok(json!({ "ok": true }))
}
/// Open the plugins folder in the OS file browser.
#[tauri::command]
pub(crate) fn plugin_open_dir() -> bool {
    let dir = plugin::plugins_root();
    let _ = std::fs::create_dir_all(&dir);
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open").arg(&dir).spawn().is_ok()
    }
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer").arg(&dir).spawn().is_ok()
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        std::process::Command::new("xdg-open").arg(&dir).spawn().is_ok()
    }
}
/// Install a plugin from a git repository (clone + build + install). Runs the
/// blocking git/build work off the async runtime.
#[tauri::command]
pub(crate) async fn plugin_install_git(pm: PluginState<'_>, url: String) -> Result<Value, String> {
    let mgr = pm.inner().clone();
    let id = tokio::task::spawn_blocking(move || mgr.install_from_git(&url))
        .await
        .map_err(|e| e.to_string())??;
    Ok(json!({ "ok": true, "id": id }))
}
/// Check whether a plugin's git source has a newer version.
#[tauri::command]
pub(crate) async fn plugin_check_update(pm: PluginState<'_>, id: String) -> Result<Value, String> {
    Ok(pm.check_update(&id).await)
}
/// Update a plugin from its recorded git source (re-clone + build + replace).
#[tauri::command]
pub(crate) async fn plugin_update(pm: PluginState<'_>, id: String) -> Result<Value, String> {
    let mgr = pm.inner().clone();
    let id = tokio::task::spawn_blocking(move || mgr.update(&id))
        .await
        .map_err(|e| e.to_string())??;
    Ok(json!({ "ok": true, "id": id }))
}
