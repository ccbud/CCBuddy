use crate::skills::{
    LocalCandidateDto, SkillDetailDto, SkillDto, SkillsStatusDto, SkillsSyncErrorDto,
    SyncConflictDto, ToolDto,
};

#[tauri::command]
pub(crate) async fn skills_list() -> Result<Vec<SkillDto>, String> {
    tauri::async_runtime::spawn_blocking(crate::skills::list)
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn skills_status() -> Result<SkillsStatusDto, String> {
    tauri::async_runtime::spawn_blocking(crate::skills::status)
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn skills_detail(id: String) -> Result<SkillDetailDto, String> {
    tauri::async_runtime::spawn_blocking(move || crate::skills::detail(&id))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
#[allow(non_snake_case)]
pub(crate) async fn skills_read_file(id: String, filePath: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || crate::skills::read_file(&id, &filePath))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn skills_tools() -> Result<Vec<ToolDto>, String> {
    tauri::async_runtime::spawn_blocking(crate::skills::tools)
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn skills_pick_local() -> Result<Option<String>, String> {
    Ok(rfd::AsyncFileDialog::new()
        .set_title("Select a folder containing SKILL.md")
        .pick_folder()
        .await
        .map(|folder| folder.path().to_string_lossy().to_string()))
}

#[tauri::command]
pub(crate) async fn skills_scan_local(path: String) -> Result<Vec<LocalCandidateDto>, String> {
    tauri::async_runtime::spawn_blocking(move || crate::skills::scan_local(&path))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn skills_import_local(path: String) -> Result<SkillDto, String> {
    tauri::async_runtime::spawn_blocking(move || crate::skills::import_local(&path))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn skills_import_git(url: String) -> Result<Vec<SkillDto>, String> {
    tauri::async_runtime::spawn_blocking(move || crate::skills::import_git(&url))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn skills_refresh(id: Option<String>) -> Result<Vec<SkillDto>, String> {
    tauri::async_runtime::spawn_blocking(move || crate::skills::refresh(id.as_deref()))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn skills_update(id: String) -> Result<SkillDto, String> {
    tauri::async_runtime::spawn_blocking(move || crate::skills::update(&id))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn skills_delete(id: String) -> Result<bool, String> {
    tauri::async_runtime::spawn_blocking(move || crate::skills::delete(&id))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
#[allow(non_snake_case)]
pub(crate) async fn skills_sync_conflicts(
    id: String,
    targetKeys: Vec<String>,
) -> Result<Vec<SyncConflictDto>, String> {
    tauri::async_runtime::spawn_blocking(move || crate::skills::sync_conflicts(&id, targetKeys))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
#[allow(non_snake_case)]
pub(crate) async fn skills_sync(
    id: String,
    targetKeys: Vec<String>,
    mode: Option<String>,
    authorizing: Vec<SyncConflictDto>,
) -> Result<SkillDto, SkillsSyncErrorDto> {
    tauri::async_runtime::spawn_blocking(move || {
        crate::skills::sync(&id, targetKeys, mode.as_deref(), authorizing)
    })
    .await
    .map_err(|error| SkillsSyncErrorDto::from(error.to_string()))?
}

#[tauri::command]
#[allow(non_snake_case)]
pub(crate) async fn skills_unsync(id: String, targetKeys: Vec<String>) -> Result<SkillDto, String> {
    tauri::async_runtime::spawn_blocking(move || crate::skills::unsync(&id, targetKeys))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn skills_set_tags(id: String, tags: Vec<String>) -> Result<SkillDto, String> {
    tauri::async_runtime::spawn_blocking(move || crate::skills::set_tags(&id, tags))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) fn skills_open_root() -> bool {
    let Ok(root) = crate::skills::root() else {
        return false;
    };
    if std::fs::create_dir_all(&root).is_err() {
        return false;
    }
    #[cfg(target_os = "macos")]
    let command = std::process::Command::new("open").arg(&root).spawn();
    #[cfg(target_os = "windows")]
    let command = std::process::Command::new("explorer").arg(&root).spawn();
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let command = std::process::Command::new("xdg-open").arg(&root).spawn();
    command.is_ok()
}
