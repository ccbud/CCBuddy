use super::target_tx::TargetSwap;
use std::path::Path;

pub(super) fn remove_guarded(
    root: &Path,
    logical_target: &Path,
    path: &Path,
    guard: &super::model::SyncConflictDto,
    label: &str,
) -> Result<(), String> {
    super::target_prepare_hooks::inject_change(7, path);
    super::target_tx::validate_guard(guard, logical_target, path, label)?;
    super::paths::remove_direct_child(root, path)?;
    super::target_fingerprint::revoke_confirmation(guard);
    Ok(())
}

impl TargetSwap {
    pub(super) fn release_guards(&self) {
        if let Some(guard) = &self.backup_guard {
            super::target_fingerprint::revoke_confirmation(guard);
        }
        if let super::target_tx::TargetStateGuard::Present(guard) = &self.current_guard {
            super::target_fingerprint::revoke_confirmation(guard);
        }
    }

    pub(super) fn restore_commit_cleanup(
        &mut self,
        original: &Path,
        seed: &super::model::SyncConflictDto,
    ) {
        let Some(cleanup) = self.backup.clone() else {
            return;
        };
        let Ok(cleanup_guard) =
            super::target_fingerprint::retoken_confirmation(seed, &self.target, &cleanup)
        else {
            return;
        };
        if std::fs::symlink_metadata(original).is_err() {
            if let Ok(restored) = super::target_fingerprint::relocate_noreplace(
                &cleanup_guard,
                &self.target,
                &cleanup,
                original,
            ) {
                self.backup = Some(original.to_path_buf());
                self.backup_guard = Some(restored);
                return;
            }
        }
        if std::fs::symlink_metadata(original).is_ok() {
            if let Ok(restored) =
                super::target_fingerprint::retoken_confirmation(seed, &self.target, original)
            {
                self.backup = Some(original.to_path_buf());
                self.backup_guard = Some(restored);
                return;
            }
        }
        self.backup = Some(cleanup);
        self.backup_guard = Some(cleanup_guard);
    }
}
