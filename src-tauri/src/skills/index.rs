use super::model::SkillsIndex;
use std::io::Write;
use std::path::Path;
use std::sync::{Mutex, MutexGuard, OnceLock};

#[cfg(test)]
thread_local! {
    static FAIL_NEXT_SAVE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

const INDEX_NAME: &str = ".ccbud-index.json";
const BACKUP_NAME: &str = ".ccbud-index.bak";

pub fn operation_lock() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub fn load(root: &Path) -> Result<SkillsIndex, String> {
    let path = root.join(INDEX_NAME);
    recover_backup(root)?;
    if let Ok(meta) = std::fs::symlink_metadata(&path) {
        if meta.file_type().is_symlink() || !meta.is_file() {
            return Err("skills index is not a regular file".into());
        }
    }
    let raw = match std::fs::read(&path) {
        Ok(value) => value,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(SkillsIndex::default()),
        Err(e) => return Err(format!("read skills index {}: {e}", path.display())),
    };
    if raw.len() > 8 * 1024 * 1024 {
        return Err("skills index is unexpectedly large".into());
    }
    let mut index: SkillsIndex = serde_json::from_slice(&raw)
        .map_err(|e| format!("parse skills index {}: {e}", path.display()))?;
    if index.version == 0 {
        index.version = 1;
    }
    if index.version != 1 {
        return Err(format!(
            "unsupported skills index version: {}",
            index.version
        ));
    }
    Ok(index)
}

pub fn save(root: &Path, index: &SkillsIndex) -> Result<(), String> {
    let bytes =
        serde_json::to_vec_pretty(index).map_err(|e| format!("encode skills index: {e}"))?;
    let temp = root.join(".ccbud-index.tmp");
    let dest = root.join(INDEX_NAME);
    let backup = root.join(BACKUP_NAME);
    recover_backup(root)?;
    super::paths::remove_direct_child(root, &temp)?;
    if let Err(error) = write_temp(&temp, &bytes) {
        let _ = super::paths::remove_direct_child(root, &temp);
        return Err(error);
    }
    if take_save_failure() {
        let _ = super::paths::remove_direct_child(root, &temp);
        return Err("injected skills index save failure".into());
    }
    let had_dest = regular_exists(&dest, "skills index")?;
    if had_dest {
        super::paths::remove_direct_child(root, &backup)?;
        std::fs::rename(&dest, &backup).map_err(|e| format!("backup skills index: {e}"))?;
    }
    if let Err(error) = std::fs::rename(&temp, &dest) {
        let _ = std::fs::remove_file(&temp);
        if had_dest {
            let _ = std::fs::rename(&backup, &dest);
        }
        return Err(format!("replace skills index: {error}"));
    }
    sync_directory(root);
    if had_dest {
        let _ = super::paths::remove_direct_child(root, &backup);
        sync_directory(root);
    }
    Ok(())
}

fn recover_backup(root: &Path) -> Result<(), String> {
    let dest = root.join(INDEX_NAME);
    let backup = root.join(BACKUP_NAME);
    match std::fs::symlink_metadata(&dest) {
        Ok(_) => return Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(format!("inspect skills index: {error}")),
    }
    if regular_exists(&backup, "skills index backup")? {
        std::fs::rename(&backup, &dest).map_err(|e| format!("recover skills index: {e}"))?;
        sync_directory(root);
    }
    Ok(())
}

fn write_temp(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("create skills index temp: {e}"))?;
    set_private(path);
    file.write_all(bytes)
        .map_err(|e| format!("write skills index: {e}"))?;
    file.sync_all()
        .map_err(|e| format!("sync skills index: {e}"))
}

fn regular_exists(path: &Path, label: &str) -> Result<bool, String> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.is_file() && !meta.file_type().is_symlink() => Ok(true),
        Ok(_) => Err(format!("{label} is not a regular file")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("inspect {label}: {error}")),
    }
}

#[cfg(test)]
pub fn fail_next_save() {
    FAIL_NEXT_SAVE.with(|value| value.set(true));
}

#[cfg(test)]
fn take_save_failure() -> bool {
    FAIL_NEXT_SAVE.with(|value| value.replace(false))
}

#[cfg(not(test))]
fn take_save_failure() -> bool {
    false
}

#[cfg(unix)]
fn sync_directory(path: &Path) {
    let _ = std::fs::File::open(path).and_then(|directory| directory.sync_all());
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) {}

#[cfg(unix)]
fn set_private(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
}

#[cfg(not(unix))]
fn set_private(_path: &Path) {}
