use super::target_tx::{validate_guard, TargetStateGuard, TargetSwap};
use std::path::{Path, PathBuf};

impl TargetSwap {
    pub(super) fn commit(&mut self) {
        let Some(backup) = self.backup.clone() else {
            return;
        };
        let cleanup = super::transfer::unique_hidden(&self.root, "commit-backup");
        if super::target_stage::install_noreplace(&backup, &cleanup).is_err() {
            return;
        }
        self.backup = Some(cleanup.clone());
        if self.validate_backup().is_err() {
            if std::fs::symlink_metadata(&backup).is_err()
                && super::target_stage::install_noreplace(&cleanup, &backup).is_ok()
            {
                self.backup = Some(backup);
            }
            return;
        }
        if super::paths::remove_direct_child(&self.root, &cleanup).is_ok() {
            self.backup = None;
        }
    }

    pub(super) fn validate_for_commit(&self) -> Result<(), String> {
        self.validate_backup()?;
        self.validate_current()
    }

    pub(super) fn validate_for_rollback(&self) -> Result<(), String> {
        self.validate_backup()?;
        self.validate_current()
    }

    pub(super) fn rollback(&mut self) -> Result<(), String> {
        if self.rolled_back {
            return Ok(());
        }
        self.validate_backup()?;
        let displaced = if self.remove_current {
            Some(self.displace_current()?)
        } else {
            self.validate_current()?;
            None
        };
        if let Some(backup) = &self.backup {
            if let Err(error) = self.validate_backup() {
                self.restore_displaced(displaced.as_deref());
                return Err(error);
            }
            if std::fs::symlink_metadata(&self.target).is_ok() {
                self.restore_displaced(displaced.as_deref());
                return Err(format!(
                    "target reappeared during restore: {}",
                    self.target.display()
                ));
            }
            if let Err(error) = super::target_stage::install_noreplace(backup, &self.target) {
                self.restore_displaced(displaced.as_deref());
                return Err(format!("restore target {}: {error}", self.target.display()));
            }
            if let Some(expected) = &self.backup_guard {
                if let Err(error) = validate_guard(
                    expected,
                    &self.target,
                    &self.target,
                    "restored overwrite target",
                ) {
                    return Err(error);
                }
            }
            self.backup = None;
        }
        if let Some(displaced) = displaced {
            self.validate_current_at(&displaced)?;
            super::paths::remove_direct_child(&self.root, &displaced)?;
        }
        self.rolled_back = true;
        Ok(())
    }

    fn displace_current(&self) -> Result<PathBuf, String> {
        let displaced = super::transfer::unique_hidden(&self.root, "rollback-current");
        super::target_stage::install_noreplace(&self.target, &displaced)
            .map_err(|error| format!("stage rollback target {}: {error}", self.target.display()))?;
        if let Err(error) = self.validate_current_at(&displaced) {
            self.restore_displaced(Some(&displaced));
            return Err(error);
        }
        Ok(displaced)
    }

    fn restore_displaced(&self, displaced: Option<&Path>) {
        let Some(displaced) = displaced else { return };
        if std::fs::symlink_metadata(&self.target).is_err() {
            let _ = super::target_stage::install_noreplace(displaced, &self.target);
        }
    }

    pub(super) fn validate_backup(&self) -> Result<(), String> {
        match (&self.backup_guard, &self.backup) {
            (None, _) => Ok(()),
            (Some(expected), Some(backup)) => {
                validate_guard(expected, &self.target, backup, "overwrite backup")
            }
            (Some(_), None) => Err("authorized overwrite backup is missing".into()),
        }
    }

    fn validate_current(&self) -> Result<(), String> {
        self.validate_current_at(&self.target)
    }

    fn validate_current_at(&self, state_path: &Path) -> Result<(), String> {
        match &self.current_guard {
            TargetStateGuard::Missing => match std::fs::symlink_metadata(state_path) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(format!(
                    "inspect rollback target {}: {error}",
                    state_path.display()
                )),
                Ok(_) => Err(format!(
                    "target reappeared during synchronization: {}",
                    self.target.display()
                )),
            },
            TargetStateGuard::Present(expected) => {
                validate_guard(expected, &self.target, state_path, "sync target")
            }
        }
    }
}
