use std::path::{Path, PathBuf};

pub struct SyncTransaction {
    swaps: Vec<TargetSwap>,
    finished: bool,
}

pub struct CommitFailure {
    transaction: SyncTransaction,
    message: String,
}

impl CommitFailure {
    pub fn into_parts(self) -> (SyncTransaction, String) {
        (self.transaction, self.message)
    }
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

    pub fn append(&mut self, mut other: SyncTransaction) {
        self.swaps.append(&mut other.swaps);
        other.finished = true;
    }

    pub fn validate_for_commit(&self) -> Result<(), String> {
        for swap in &self.swaps {
            swap.validate_for_commit()?;
        }
        Ok(())
    }

    pub fn commit(mut self) -> Result<(), CommitFailure> {
        if let Err(message) = self.validate_for_commit() {
            return Err(CommitFailure {
                transaction: self,
                message,
            });
        }
        for swap in &mut self.swaps {
            swap.commit();
        }
        for swap in &self.swaps {
            swap.release_guards();
        }
        self.finished = true;
        Ok(())
    }

    pub fn rollback(mut self) -> Result<(), String> {
        let result = self.rollback_inner();
        self.finished = result.is_ok();
        result
    }

    fn rollback_inner(&mut self) -> Result<(), String> {
        for swap in self.swaps.iter().rev() {
            swap.validate_for_rollback()?;
        }
        let mut errors = Vec::new();
        for swap in self.swaps.iter_mut().rev() {
            if let Err(error) = swap.rollback() {
                errors.push(error);
            }
        }
        if errors.is_empty() {
            for swap in &self.swaps {
                swap.release_guards();
            }
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
            for swap in &self.swaps {
                swap.release_guards();
            }
        }
    }
}

pub struct TargetSwap {
    pub(super) root: PathBuf,
    pub(super) target: PathBuf,
    pub(super) backup: Option<PathBuf>,
    pub(super) backup_guard: Option<super::model::SyncConflictDto>,
    pub(super) current_guard: TargetStateGuard,
    pub(super) remove_current: bool,
    pub(super) rolled_back: bool,
    pub actual_mode: String,
}

pub(super) enum TargetStateGuard {
    Missing,
    Present(super::model::SyncConflictDto),
}

pub(super) fn validate_guard(
    expected: &super::model::SyncConflictDto,
    logical_target: &Path,
    state_path: &Path,
    label: &str,
) -> Result<(), String> {
    match super::target_fingerprint::matches_confirmation(expected, logical_target, state_path)? {
        true => Ok(()),
        false => Err(format!("{label} changed during synchronization")),
    }
}

pub fn prepare(
    source: &Path,
    root: &Path,
    target: &Path,
    mode: &str,
) -> Result<TargetSwap, String> {
    super::target_prepare::prepare(
        source,
        root,
        target,
        mode,
        &super::target_prepare::Expectation::Unchecked,
    )
    .map_err(|error| match error {
        super::target_prepare::PrepareError::Changed => {
            format!(
                "target changed during synchronization: {}",
                target.display()
            )
        }
        super::target_prepare::PrepareError::Failed(message) => message,
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
    let backup_guard = super::target_fingerprint::capture_state(target, target)?;
    let backup = super::transfer::unique_hidden(root, "remove-backup");
    let backup_guard =
        super::target_fingerprint::relocate_noreplace(&backup_guard, target, target, &backup)?;
    Ok(Some(TargetSwap {
        root: root.to_path_buf(),
        target: target.to_path_buf(),
        backup: Some(backup),
        backup_guard: Some(backup_guard),
        current_guard: TargetStateGuard::Missing,
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

pub fn commit_after_index_save(
    transaction: SyncTransaction,
    root: &Path,
    previous_index: &super::model::SkillsIndex,
) -> Result<(), String> {
    match transaction.commit() {
        Ok(()) => Ok(()),
        Err(failure) => {
            let (transaction, message) = failure.into_parts();
            let mut failures = vec![message];
            if let Err(error) = transaction.rollback() {
                failures.push(format!("rollback failed: {error}"));
            }
            if let Err(error) = super::index::save(root, previous_index) {
                failures.push(format!("restore skills index failed: {error}"));
            }
            Err(failures.join("; "))
        }
    }
}
