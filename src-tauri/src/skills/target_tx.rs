use std::path::{Path, PathBuf};

pub struct SyncTransaction {
    swaps: Vec<TargetSwap>,
    finished: bool,
}

impl SyncTransaction {
    pub fn new() -> Self {
        Self {
            swaps: Vec::new(),
            finished: false,
        }
    }

    pub fn push(&mut self, swap: TargetSwap) {
        self.swaps.push(swap);
    }

    pub fn commit(mut self) {
        for swap in &mut self.swaps {
            swap.commit();
        }
        self.finished = true;
    }

    pub fn rollback(mut self) -> Result<(), String> {
        let result = self.rollback_inner();
        self.finished = result.is_ok();
        result
    }

    fn rollback_inner(&mut self) -> Result<(), String> {
        let mut errors = Vec::new();
        for swap in self.swaps.iter_mut().rev() {
            if let Err(error) = swap.rollback() {
                errors.push(error);
            }
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("; "))
        }
    }
}

impl Drop for SyncTransaction {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.rollback_inner();
        }
    }
}

pub struct TargetSwap {
    root: PathBuf,
    target: PathBuf,
    backup: Option<PathBuf>,
    remove_current: bool,
    rolled_back: bool,
    pub actual_mode: String,
}

impl TargetSwap {
    fn commit(&mut self) {
        if let Some(backup) = self.backup.take() {
            let _ = super::paths::remove_direct_child(&self.root, &backup);
        }
    }

    fn rollback(&mut self) -> Result<(), String> {
        if self.rolled_back {
            return Ok(());
        }
        if self.remove_current {
            super::paths::remove_direct_child(&self.root, &self.target)?;
        } else if std::fs::symlink_metadata(&self.target).is_ok() {
            return Err(format!(
                "target reappeared during rollback: {}",
                self.target.display()
            ));
        }
        if let Some(backup) = &self.backup {
            std::fs::rename(backup, &self.target)
                .map_err(|e| format!("restore target {}: {e}", self.target.display()))?;
            self.backup = None;
        }
        self.rolled_back = true;
        Ok(())
    }
}

pub fn prepare(
    source: &Path,
    root: &Path,
    target: &Path,
    mode: &str,
) -> Result<TargetSwap, String> {
    if target.parent() != Some(root) {
        return Err(format!("target is outside {}", root.display()));
    }
    let stage = super::transfer::unique_hidden(root, "sync-stage");
    let backup = super::transfer::unique_hidden(root, "sync-backup");
    let actual_mode = match create_staged(source, &stage, mode) {
        Ok(actual) => actual,
        Err(error) => {
            let _ = super::paths::remove_direct_child(root, &stage);
            return Err(error);
        }
    };
    let had_target = match std::fs::symlink_metadata(target) {
        Ok(_) => true,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(error) => {
            let _ = super::paths::remove_direct_child(root, &stage);
            return Err(format!("inspect target {}: {error}", target.display()));
        }
    };
    if had_target {
        if let Err(error) = std::fs::rename(target, &backup) {
            let _ = super::paths::remove_direct_child(root, &stage);
            return Err(format!("backup target {}: {error}", target.display()));
        }
    }
    if let Err(error) = std::fs::rename(&stage, target) {
        let restore = had_target.then(|| std::fs::rename(&backup, target));
        let _ = super::paths::remove_direct_child(root, &stage);
        return match restore {
            Some(Err(restore)) => Err(format!(
                "replace target {}: {error}; restore failed: {restore}",
                target.display()
            )),
            _ => Err(format!("replace target {}: {error}", target.display())),
        };
    }
    Ok(TargetSwap {
        root: root.to_path_buf(),
        target: target.to_path_buf(),
        backup: had_target.then_some(backup),
        remove_current: true,
        rolled_back: false,
        actual_mode,
    })
}

pub fn prepare_remove(root: &Path, target: &Path) -> Result<Option<TargetSwap>, String> {
    if target.parent() != Some(root) {
        return Err(format!("target is outside {}", root.display()));
    }
    match std::fs::symlink_metadata(target) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("inspect target {}: {error}", target.display())),
        Ok(_) => {}
    }
    let backup = super::transfer::unique_hidden(root, "remove-backup");
    std::fs::rename(target, &backup)
        .map_err(|e| format!("stage removal {}: {e}", target.display()))?;
    Ok(Some(TargetSwap {
        root: root.to_path_buf(),
        target: target.to_path_buf(),
        backup: Some(backup),
        remove_current: false,
        rolled_back: false,
        actual_mode: String::new(),
    }))
}

pub fn rollback_error(transaction: SyncTransaction, error: String) -> String {
    match transaction.rollback() {
        Ok(()) => error,
        Err(rollback) => format!("{error}; rollback failed: {rollback}"),
    }
}

fn create_staged(source: &Path, stage: &Path, mode: &str) -> Result<String, String> {
    if mode == "copy" {
        super::transfer::copy_directory(source, stage)?;
        return Ok("copy".into());
    }
    match create_symlink(source, stage) {
        Ok(()) => Ok("symlink".into()),
        Err(error) if mode == "auto" => {
            if let Some(root) = stage.parent() {
                let _ = super::paths::remove_direct_child(root, stage);
            }
            super::transfer::copy_directory(source, stage)
                .map_err(|copy| format!("symlink failed ({error}); copy failed ({copy})"))?;
            Ok("copy".into())
        }
        Err(error) => Err(error),
    }
}

#[cfg(unix)]
fn create_symlink(source: &Path, target: &Path) -> Result<(), String> {
    std::os::unix::fs::symlink(source, target)
        .map_err(|e| format!("create symlink {}: {e}", target.display()))
}

#[cfg(windows)]
fn create_symlink(source: &Path, target: &Path) -> Result<(), String> {
    std::os::windows::fs::symlink_dir(source, target)
        .map_err(|e| format!("create directory link {}: {e}", target.display()))
}
