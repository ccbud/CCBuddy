use super::model::SyncConflictDto;
use super::target_prepare::PrepareError;
use std::path::Path;

pub(super) fn validate(
    expected: &SyncConflictDto,
    logical_target: &Path,
    state_path: &Path,
) -> Result<(), PrepareError> {
    match super::target_fingerprint::matches_confirmation(expected, logical_target, state_path) {
        Ok(true) => Ok(()),
        Ok(false) => Err(PrepareError::Changed),
        Err(error) if error.contains("changed") || error.contains("No such file") => {
            Err(PrepareError::Changed)
        }
        Err(error) => Err(PrepareError::Failed(error)),
    }
}

pub(super) fn clean_stage(root: &Path, stage: &Path, message: String) -> PrepareError {
    let _ = super::paths::remove_direct_child(root, stage);
    PrepareError::Failed(message)
}

pub(super) fn clean_changed(root: &Path, stage: &Path) -> PrepareError {
    let _ = super::paths::remove_direct_child(root, stage);
    PrepareError::Changed
}

pub(super) fn recover_stage_failure(
    root: &Path,
    target: &Path,
    backup: &Path,
    stage: &Path,
    had_target: bool,
    backup_guard: Option<&SyncConflictDto>,
    staged_guard: &SyncConflictDto,
    error: String,
) -> PrepareError {
    match std::fs::symlink_metadata(target) {
        Ok(_) => {
            clean_guarded_stage(root, target, stage, staged_guard);
            if let Some(guard) = backup_guard {
                super::target_fingerprint::revoke_confirmation(guard);
            }
            return if had_target {
                PrepareError::Failed(format!(
                    "target reappeared; overwrite backup preserved: {}",
                    backup.display()
                ))
            } else {
                PrepareError::Changed
            };
        }
        Err(inspect) if inspect.kind() == std::io::ErrorKind::NotFound => {}
        Err(inspect) => {
            if let Some(guard) = backup_guard {
                super::target_fingerprint::revoke_confirmation(guard);
            }
            return PrepareError::Failed(format!(
                "inspect failed sync target {}: {inspect}; {error}",
                target.display()
            ));
        }
    }
    let restore = backup_guard
        .map(|guard| super::target_fingerprint::relocate_noreplace(guard, target, backup, target));
    let stage_preserved = clean_guarded_stage(root, target, stage, staged_guard);
    let mut message = format!("install sync target {}: {error}", target.display());
    match restore {
        Some(Ok(ref guard)) => super::target_fingerprint::revoke_confirmation(guard),
        Some(Err(ref restore)) => {
            if let Some(guard) = backup_guard {
                super::target_fingerprint::revoke_confirmation(guard);
            }
            message.push_str(&format!("; restore failed: {restore}"));
        }
        None => {}
    }
    if stage_preserved {
        message.push_str(&format!("; changed stage preserved: {}", stage.display()));
    }
    PrepareError::Failed(message)
}

fn clean_guarded_stage(
    root: &Path,
    logical_target: &Path,
    stage: &Path,
    guard: &SyncConflictDto,
) -> bool {
    if !matches!(
        super::target_fingerprint::matches_confirmation(guard, logical_target, stage),
        Ok(true)
    ) {
        return std::fs::symlink_metadata(stage).is_ok();
    }
    if super::paths::remove_direct_child(root, stage).is_err() {
        return true;
    }
    super::target_fingerprint::revoke_confirmation(guard);
    false
}

pub(super) fn restore_guard_failure(
    root: &Path,
    target: &Path,
    backup: &Path,
    stage: &Path,
    expected: &SyncConflictDto,
    error: PrepareError,
) -> PrepareError {
    let _ = super::paths::remove_direct_child(root, stage);
    if std::fs::symlink_metadata(target).is_ok() {
        super::target_fingerprint::revoke_confirmation(expected);
        return PrepareError::Failed("target reappeared; overwrite backup preserved".into());
    }
    let moved_guard =
        match super::target_fingerprint::retoken_confirmation(expected, target, backup) {
            Ok(guard) => guard,
            Err(message) => {
                super::target_fingerprint::revoke_confirmation(expected);
                return PrepareError::Failed(message);
            }
        };
    match super::target_fingerprint::relocate_noreplace(&moved_guard, target, backup, target) {
        Ok(restored) => super::target_fingerprint::revoke_confirmation(&restored),
        Err(restore) => {
            super::target_fingerprint::revoke_confirmation(&moved_guard);
            return PrepareError::Failed(format!("restore {} failed: {restore}", target.display()));
        }
    }
    error
}
