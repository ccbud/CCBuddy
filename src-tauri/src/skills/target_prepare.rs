use super::model::SyncConflictDto;
use super::target_prepare_restore::{
    clean_changed, clean_stage, recover_stage_failure, restore_guard_failure, validate,
};
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
    let mut backup_guard = match (expectation, had_target) {
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
        if let Some(expected) = backup_guard.as_ref() {
            validate(expected, target, target).map_err(|error| {
                let _ = super::paths::remove_direct_child(root, &stage);
                error
            })?;
        }
        let expected = backup_guard
            .clone()
            .ok_or_else(|| clean_stage(root, &stage, "overwrite backup guard is missing".into()))?;
        let refreshed =
            super::target_fingerprint::relocate_noreplace(&expected, target, target, &backup)
                .map_err(|error| {
                    clean_stage(
                        root,
                        &stage,
                        format!("backup target {}: {error}", target.display()),
                    )
                })?;
        backup_guard = Some(refreshed.clone());
        super::target_prepare_hooks::inject_change(2, &backup);
        if let Err(error) = validate(&refreshed, target, &backup) {
            return Err(restore_guard_failure(
                root,
                target,
                &backup,
                &stage,
                &refreshed,
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
    if matches!(expectation, Expectation::Missing) && std::fs::symlink_metadata(target).is_ok() {
        return Err(clean_changed(root, &stage));
    }
    super::target_prepare_hooks::inject_change(4, target);
    let current_guard = match super::target_fingerprint::relocate_noreplace(
        &staged_guard,
        target,
        &stage,
        target,
    ) {
        Ok(guard) => guard,
        Err(error) => {
            return Err(recover_stage_failure(
                root,
                target,
                &backup,
                &stage,
                had_target,
                backup_guard.as_ref(),
                &staged_guard,
                error,
            ));
        }
    };
    Ok(TargetSwap {
        root: root.to_path_buf(),
        target: target.to_path_buf(),
        backup: had_target.then_some(backup),
        backup_guard,
        current_guard: super::target_tx::TargetStateGuard::Present(current_guard),
        remove_current: true,
        rolled_back: false,
        actual_mode,
    })
}
