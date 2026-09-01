use super::model::SyncConflictDto;
use super::target_tx::TargetSwap;
use std::path::Path;

#[cfg(test)]
pub use super::target_prepare_hooks::change_target_during_prepare;

#[derive(Debug)]
pub enum PrepareError {
    Changed,
    Failed(String),
}

#[derive(Clone, Debug)]
pub enum Expectation {
    Unchecked,
    Missing,
    Authorized(SyncConflictDto),
}

pub fn prepare(
    source: &Path,
    root: &Path,
    target: &Path,
    mode: &str,
    expectation: &Expectation,
) -> Result<TargetSwap, PrepareError> {
    if target.parent() != Some(root) {
        return Err(PrepareError::Failed(format!(
            "target is outside {}",
            root.display()
        )));
    }
    let stage = super::transfer::unique_hidden(root, "sync-stage");
    let backup = super::transfer::unique_hidden(root, "sync-backup");
    let actual_mode = super::target_stage::create(source, &stage, mode).map_err(|error| {
        let _ = super::paths::remove_direct_child(root, &stage);
        PrepareError::Failed(error)
    })?;
    let authorization = match expectation {
        Expectation::Authorized(expected) => Some(expected),
        _ => None,
    };
    let staged_guard = super::target_fingerprint::capture_state(target, &stage)
        .map_err(|error| clean_stage(root, &stage, error))?;
    super::target_prepare_hooks::inject_change(1, target);
    super::target_prepare_hooks::inject_change(3, target);
    let had_target = match std::fs::symlink_metadata(target) {
        Ok(_) if matches!(expectation, Expectation::Missing) => {
            return Err(clean_changed(root, &stage));
        }
        Ok(_) => true,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(error) => return Err(clean_stage(root, &stage, error.to_string())),
    };
    let backup_guard = match (expectation, had_target) {
        (Expectation::Authorized(expected), true) => Some(expected.clone()),
        (Expectation::Unchecked, true) => Some(
            super::target_fingerprint::capture_state(target, target)
                .map_err(|error| clean_stage(root, &stage, error))?,
        ),
        _ => None,
    };
    if let Some(expected) = authorization {
        validate(expected, target, target).map_err(|error| {
            let _ = super::paths::remove_direct_child(root, &stage);
            error
        })?;
    }
    if had_target {
        super::target_stage::install_noreplace(target, &backup).map_err(|error| {
            clean_stage(
                root,
                &stage,
                format!("backup target {}: {error}", target.display()),
            )
        })?;
        let backup_identity = std::fs::symlink_metadata(&backup)
            .map(|metadata| super::target_identity::stable(&metadata))
            .map_err(|error| clean_stage(root, &stage, error.to_string()))?;
        super::target_prepare_hooks::inject_change(2, &backup);
        if let Some(expected) = backup_guard.as_ref() {
            if let Err(error) = validate(expected, target, &backup) {
                return Err(restore_guard_failure(
                    root,
                    target,
                    &backup,
                    &stage,
                    &backup_identity,
                    expected,
                    if authorization.is_some() {
                        error
                    } else {
                        PrepareError::Failed(format!(
                            "managed target changed during synchronization: {}",
                            target.display()
                        ))
                    },
                ));
            }
        }
    }
    if matches!(expectation, Expectation::Missing) && std::fs::symlink_metadata(target).is_ok() {
        return Err(clean_changed(root, &stage));
    }
    super::target_prepare_hooks::inject_change(4, target);
    if let Err(error) = super::target_stage::install_noreplace(&stage, target) {
        let _ = super::paths::remove_direct_child(root, &stage);
        if error.kind() == std::io::ErrorKind::AlreadyExists {
            return Err(if had_target {
                PrepareError::Failed(format!(
                    "target reappeared; overwrite backup preserved: {}",
                    backup.display()
                ))
            } else {
                PrepareError::Changed
            });
        }
        let restore = had_target.then(|| super::target_stage::install_noreplace(&backup, target));
        return Err(PrepareError::Failed(match restore {
            Some(Err(restore)) => format!(
                "replace target {}: {error}; restore failed: {restore}",
                target.display()
            ),
            _ => format!("replace target {}: {error}", target.display()),
        }));
    }
    if !super::target_fingerprint::matches_confirmation(&staged_guard, target, target)
        .map_err(PrepareError::Failed)?
    {
        return Err(PrepareError::Failed(format!(
            "installed target changed; backup preserved: {}",
            target.display()
        )));
    }
    Ok(TargetSwap {
        root: root.to_path_buf(),
        target: target.to_path_buf(),
        backup: had_target.then_some(backup),
        backup_guard,
        current_guard: super::target_tx::TargetStateGuard::Present(staged_guard),
        remove_current: true,
        rolled_back: false,
        actual_mode,
    })
}

fn validate(
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

fn clean_stage(root: &Path, stage: &Path, message: String) -> PrepareError {
    let _ = super::paths::remove_direct_child(root, stage);
    PrepareError::Failed(message)
}

fn clean_changed(root: &Path, stage: &Path) -> PrepareError {
    let _ = super::paths::remove_direct_child(root, stage);
    PrepareError::Changed
}

fn restore_guard_failure(
    root: &Path,
    target: &Path,
    backup: &Path,
    stage: &Path,
    moved_identity: &[u8],
    expected: &SyncConflictDto,
    error: PrepareError,
) -> PrepareError {
    let _ = super::paths::remove_direct_child(root, stage);
    if std::fs::symlink_metadata(target).is_ok() {
        return PrepareError::Failed("target reappeared; overwrite backup preserved".into());
    }
    let metadata = match std::fs::symlink_metadata(backup) {
        Ok(metadata) if super::target_identity::stable(&metadata) == moved_identity => metadata,
        _ => return PrepareError::Failed("overwrite backup identity changed".into()),
    };
    let _ = metadata;
    let moved_guard =
        match super::target_fingerprint::retoken_confirmation(expected, target, backup) {
            Ok(guard) => guard,
            Err(message) => return PrepareError::Failed(message),
        };
    if let Err(restore) = super::target_stage::install_noreplace(backup, target) {
        return PrepareError::Failed(format!("restore {} failed: {restore}", target.display()));
    }
    match super::target_fingerprint::matches_confirmation(&moved_guard, target, target) {
        Ok(true) => error,
        _ => PrepareError::Failed("restored overwrite target failed validation".into()),
    }
}
