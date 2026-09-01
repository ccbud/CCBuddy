use super::target_tx::{validate_guard, TargetStateGuard, TargetSwap};
use std::path::{Path, PathBuf};

impl TargetSwap {
    pub(super) fn commit(&mut self) {
        let Some(backup) = self.backup.clone() else {
            return;
        };
        if self.validate_backup().is_err() {
            return;
        }
        let Some(previous_guard) = self.backup_guard.clone() else {
            return;
        };
        let cleanup = super::transfer::unique_hidden(&self.root, "commit-backup");
        match super::target_fingerprint::relocate_noreplace(
            &previous_guard,
            &self.target,
            &backup,
            &cleanup,
        ) {
            Ok(refreshed) => {
                self.backup = Some(cleanup.clone());
                self.backup_guard = Some(refreshed);
            }
            Err(_) => {
                if std::fs::symlink_metadata(&cleanup).is_ok() {
                    self.backup = Some(cleanup);
                    self.restore_commit_cleanup(&backup, &previous_guard);
                }
                return;
            }
        }
        let Some(cleanup_guard) = self.backup_guard.clone() else {
            self.restore_commit_cleanup(&backup, &previous_guard);
            return;
        };
        match super::target_commit_cleanup::remove_guarded(
            &self.root,
            &self.target,
            &cleanup,
            &cleanup_guard,
            "commit backup",
        ) {
            Ok(()) => self.backup = None,
            Err(_) => self.restore_commit_cleanup(&backup, &previous_guard),
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
        if let Some(backup) = self.backup.clone() {
            if let Err(error) = self.validate_backup() {
                let restored = self.restore_displaced(displaced.as_deref());
                return Err(with_restore_error(error, restored));
            }
            if std::fs::symlink_metadata(&self.target).is_ok() {
                let error = format!(
                    "target reappeared during restore: {}",
                    self.target.display()
                );
                let restored = self.restore_displaced(displaced.as_deref());
                return Err(with_restore_error(error, restored));
            }
            let Some(expected) = self.backup_guard.clone() else {
                return Err("overwrite backup guard is missing".into());
            };
            if let Err(error) = super::target_fingerprint::relocate_noreplace(
                &expected,
                &self.target,
                &backup,
                &self.target,
            ) {
                let restored = self.restore_displaced(displaced.as_deref());
                return Err(with_restore_error(
                    format!("restore target {}: {error}", self.target.display()),
                    restored,
                ));
            }
            self.backup = None;
        }
        if let Some(displaced) = displaced {
            let guard = match &self.current_guard {
                TargetStateGuard::Present(guard) => guard.clone(),
                TargetStateGuard::Missing => {
                    return Err("rollback cleanup guard is missing".into());
                }
            };
            super::target_commit_cleanup::remove_guarded(
                &self.root,
                &self.target,
                &displaced,
                &guard,
                "rollback target",
            )?;
        }
        self.rolled_back = true;
        Ok(())
    }

    fn displace_current(&mut self) -> Result<PathBuf, String> {
        self.validate_current()?;
        let expected = match &self.current_guard {
            TargetStateGuard::Present(expected) => expected.clone(),
            TargetStateGuard::Missing => return Err("cannot displace a missing target".into()),
        };
        let displaced = super::transfer::unique_hidden(&self.root, "rollback-current");
        match super::target_fingerprint::relocate_noreplace(
            &expected,
            &self.target,
            &self.target,
            &displaced,
        ) {
            Ok(refreshed) => {
                self.current_guard = TargetStateGuard::Present(refreshed);
            }
            Err(error) => return Err(error),
        }
        Ok(displaced)
    }

    fn restore_displaced(&mut self, displaced: Option<&Path>) -> Result<(), String> {
        let Some(displaced) = displaced else {
            return Ok(());
        };
        self.validate_current_at(displaced)?;
        let expected = match &self.current_guard {
            TargetStateGuard::Present(expected) => expected.clone(),
            TargetStateGuard::Missing => return Err("cannot restore a missing target".into()),
        };
        if std::fs::symlink_metadata(&self.target).is_ok() {
            return Err(format!("target reappeared: {}", self.target.display()));
        }
        self.current_guard =
            TargetStateGuard::Present(super::target_fingerprint::relocate_noreplace(
                &expected,
                &self.target,
                displaced,
                &self.target,
            )?);
        Ok(())
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

fn with_restore_error(error: String, restored: Result<(), String>) -> String {
    match restored {
        Ok(()) => error,
        Err(restore) => format!("{error}; restore failed: {restore}"),
    }
}
