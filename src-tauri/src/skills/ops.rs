use super::model::{SkillDto, SkillsSyncErrorDto, SyncConflictDto, TargetMeta};
use std::path::Path;

pub fn sync(
    root: &Path,
    home: &Path,
    id: &str,
    keys: Vec<String>,
    mode: Option<&str>,
    authorizing: Vec<SyncConflictDto>,
) -> Result<SkillDto, SkillsSyncErrorDto> {
    if keys.is_empty() {
        return Err(SkillsSyncErrorDto::from("select at least one target tool"));
    }
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let source = super::paths::existing_skill_dir(&root, id)?;
    let mut index = super::index::load(&root)?;
    let previous_index = index.clone();
    super::catalog::reconcile(&root, &mut index)?;
    let meta = index
        .skills
        .get_mut(id)
        .ok_or_else(|| format!("skill not found: {id}"))?;
    let transaction = super::sync::sync_targets(
        &source,
        id,
        &keys,
        mode,
        home,
        &mut meta.targets,
        &authorizing,
    )?;
    if let Err(error) = transaction.validate_for_commit() {
        return Err(super::target_tx::rollback_error(transaction, error).into());
    }
    if let Err(error) = super::index::save(&root, &index) {
        return Err(super::target_tx::rollback_error(transaction, error).into());
    }
    super::target_tx::commit_after_index_save(transaction, &root, &previous_index)
        .map_err(SkillsSyncErrorDto::from)?;
    Ok(super::catalog::dto_by_id(&root, &index, id)?)
}

pub fn sync_conflicts(
    root: &Path,
    home: &Path,
    id: &str,
    keys: Vec<String>,
) -> Result<Vec<SyncConflictDto>, String> {
    if keys.is_empty() {
        return Err("select at least one target tool".into());
    }
    let _guard = super::index::operation_lock();
    let root = root
        .canonicalize()
        .map_err(|_| format!("skill not found: {id}"))?;
    super::paths::existing_skill_dir_readonly(&root, id)?;
    let index = super::index::load_readonly(&root)?;
    let targets: Vec<TargetMeta> = index
        .skills
        .get(id)
        .map(|meta| {
            meta.targets
                .iter()
                .filter(|target| super::tools::find(&target.key).is_some())
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    super::sync_plan::sync_conflicts(id, &keys, home, &targets)
}

pub fn unsync(root: &Path, home: &Path, id: &str, keys: Vec<String>) -> Result<SkillDto, String> {
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let mut index = super::index::load(&root)?;
    let previous_index = index.clone();
    super::catalog::reconcile(&root, &mut index)?;
    let meta = index
        .skills
        .get_mut(id)
        .ok_or_else(|| format!("skill not found: {id}"))?;
    let transaction = super::sync::unsync_targets(id, &keys, home, &mut meta.targets)?;
    if let Err(error) = transaction.validate_for_commit() {
        return Err(super::target_tx::rollback_error(transaction, error));
    }
    if let Err(error) = super::index::save(&root, &index) {
        return Err(super::target_tx::rollback_error(transaction, error));
    }
    super::target_tx::commit_after_index_save(transaction, &root, &previous_index)?;
    super::catalog::dto_by_id(&root, &index, id)
}
