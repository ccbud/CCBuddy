// Daily auto-update flow (first time the app becomes visible each day), moved verbatim from
// lib.rs. The AUTO_UPDATE_* bookkeeping statics travel with it.

use serde_json::{json, Value};

use crate::popover::now_ms;
use crate::store;
use crate::tray::config_lang;

use super::update::{
    run_update_check, run_update_download, FlagGuard, UPDATE_LATEST, UPDATE_STAGED,
};

// Daily auto-check bookkeeping: the day (local YYYY-MM-DD) whose auto check already completed
// (in-memory mirror of the on-disk stamp), an in-flight guard, and the last attempt time so a
// failed attempt (offline) is retried on a later visibility change instead of on every focus.
static AUTO_UPDATE_DONE_DAY: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
static AUTO_UPDATE_RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static AUTO_UPDATE_LAST_TRY_MS: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);
const AUTO_UPDATE_RETRY_MS: i64 = 10 * 60 * 1000;

// ---- daily auto update (first time the app becomes visible each day) ----
// The stamp lives in its own tiny file (NOT config.json) so the daily writer never races the
// renderer's whole-config round-trips through config_save.
fn auto_update_stamp_file() -> std::path::PathBuf {
    store::ccbud_home().join("update-check.json")
}
fn today_local() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}
fn last_auto_update_day() -> String {
    std::fs::read_to_string(auto_update_stamp_file())
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.get("lastAutoCheckDay").and_then(|d| d.as_str()).map(|s| s.to_string()))
        .unwrap_or_default()
}
fn mark_auto_update_day(day: &str) {
    if let Ok(mut g) = AUTO_UPDATE_DONE_DAY.lock() {
        *g = Some(day.to_string());
    }
    let _ = std::fs::create_dir_all(store::ccbud_home());
    let _ = std::fs::write(
        auto_update_stamp_file(),
        serde_json::to_vec(&json!({ "lastAutoCheckDay": day })).unwrap_or_default(),
    );
}

// Native restart prompt after an auto-downloaded update (localized like tray_labels — the main
// window may be hidden when the popover triggered the check, so this can't live in the renderer).
struct UpdatePromptLabels {
    title: &'static str,
    body: &'static str, // {v} → new version
    restart: &'static str,
    later: &'static str,
}
fn update_prompt_labels(lang: &str) -> UpdatePromptLabels {
    match lang {
        "zh" | "zh-CN" => UpdatePromptLabels { title: "更新已就绪", body: "新版本 {v} 已自动下载完成。是否立即重启以应用新版本？", restart: "立即重启", later: "稍后" },
        "zh-TW" => UpdatePromptLabels { title: "更新已就緒", body: "新版本 {v} 已自動下載完成。要立即重新啟動以套用新版本嗎？", restart: "立即重啟", later: "稍後" },
        "ja" => UpdatePromptLabels { title: "アップデートの準備ができました", body: "新しいバージョン {v} のダウンロードが完了しました。今すぐ再起動して適用しますか？", restart: "今すぐ再起動", later: "後で" },
        "ko" => UpdatePromptLabels { title: "업데이트 준비 완료", body: "새 버전 {v} 다운로드가 완료되었습니다. 지금 다시 시작하여 적용할까요?", restart: "지금 다시 시작", later: "나중에" },
        _ => UpdatePromptLabels { title: "Update ready", body: "Version {v} has been downloaded. Restart now to switch to the new version?", restart: "Restart now", later: "Later" },
    }
}
async fn prompt_restart_to_apply(app: &tauri::AppHandle) {
    let version = UPDATE_LATEST
        .lock()
        .ok()
        .and_then(|g| g.as_ref().map(|(v, _)| v.clone()))
        .unwrap_or_default();
    let l = update_prompt_labels(&config_lang(&store::read_config()));
    // On Linux this shells out to zenity; without it rfd logs an error and returns Cancel,
    // degrading to the staged update applying on the next launch (About pane shows "restart").
    let res = rfd::AsyncMessageDialog::new()
        .set_level(rfd::MessageLevel::Info)
        .set_title(l.title)
        .set_description(l.body.replace("{v}", &version))
        .set_buttons(rfd::MessageButtons::OkCancelCustom(l.restart.to_string(), l.later.to_string()))
        .show()
        .await;
    if matches!(&res, rfd::MessageDialogResult::Custom(s) if s == l.restart) {
        app.restart();
    }
}

/// Called from every "app became visible" site (main window focus, popover show, launch).
/// The first such moment each day — with autoUpdate.check on — runs one update check; when an
/// update exists and autoUpdate.autoDownload is on it's downloaded, then the user is asked
/// whether to restart into the new version (declining leaves it staged for the next launch).
/// The day is stamped only after a flow that reached the network succeeds, so an offline
/// launch doesn't burn the day's only attempt — the next visibility (≥10 min later) retries.
pub(crate) fn auto_update_on_visible(app: &tauri::AppHandle) {
    let today = today_local();
    if AUTO_UPDATE_DONE_DAY
        .lock()
        .map(|g| g.as_deref() == Some(today.as_str()))
        .unwrap_or(false)
    {
        return;
    }
    if last_auto_update_day() == today {
        // Stamped by a previous run of this process instance or a crashed one — mirror it.
        if let Ok(mut g) = AUTO_UPDATE_DONE_DAY.lock() {
            *g = Some(today);
        }
        return;
    }
    if now_ms() - AUTO_UPDATE_LAST_TRY_MS.load(std::sync::atomic::Ordering::Relaxed) < AUTO_UPDATE_RETRY_MS {
        return;
    }
    if AUTO_UPDATE_RUNNING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    let running = FlagGuard(&AUTO_UPDATE_RUNNING);
    let au = store::read_config().get("autoUpdate").cloned().unwrap_or_else(|| json!({}));
    if !au.get("check").and_then(|v| v.as_bool()).unwrap_or(true) {
        return; // `running` drops here and clears the flag
    }
    AUTO_UPDATE_LAST_TRY_MS.store(now_ms(), std::sync::atomic::Ordering::Relaxed);
    let auto_dl = au.get("autoDownload").and_then(|v| v.as_bool()).unwrap_or(true);
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let _running = running; // held until the task ends (cleared even on panic/unwind)
        match run_update_check(&app).await {
            Ok(None) => mark_auto_update_day(&today),
            Ok(Some(_)) => {
                let staged = UPDATE_STAGED.lock().map(|g| *g).unwrap_or(false);
                if staged {
                    // Downloaded on an earlier day but never restarted — just re-ask.
                    mark_auto_update_day(&today);
                    prompt_restart_to_apply(&app).await;
                } else if !auto_dl {
                    mark_auto_update_day(&today); // surfaced in the About pane only
                } else {
                    match run_update_download(&app).await {
                        Ok(_) => {
                            mark_auto_update_day(&today);
                            if UPDATE_STAGED.lock().map(|g| *g).unwrap_or(false) {
                                prompt_restart_to_apply(&app).await;
                            }
                        }
                        // A manual download is already in flight — the user took over today's
                        // update (the About pane drives the rest), so the day is done.
                        Err(e) if e == "busy" => mark_auto_update_day(&today),
                        Err(_) => {} // download failed → day left unstamped so a later visibility retries
                    }
                }
            }
            Err(_) => {} // check failed (offline?) → retry on a later visibility
        }
    });
}
