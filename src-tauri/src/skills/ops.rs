use super::model::SkillDto;
use std::path::Path;

pub fn sync(
    root: &Path,
    home: &Path,
    id: &str,
    keys: Vec<String>,
    mode: Option<&str>,
) -> Result<SkillDto, String> {
    if keys.is_empty() {
        return Err("select at least one target tool".into());
    }
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let source = super::paths::existing_skill_dir(&root, id)?;
    let mut index = super::index::load(&root)?;
    super::catalog::reconcile(&root, &mut index)?;
    let meta = index
        .skills
        .get_mut(id)
        .ok_or_else(|| format!("skill not found: {id}"))?;
    let transaction = super::sync::sync_targets(&source, id, &keys, mode, home, &mut meta.targets)?;
    if let Err(error) = super::index::save(&root, &index) {
        return Err(super::target_tx::rollback_error(transaction, error));
    }
    transaction.commit();
    super::catalog::dto_by_id(&root, &index, id)
}

pub fn unsync(root: &Path, home: &Path, id: &str, keys: Vec<String>) -> Result<SkillDto, String> {
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let mut index = super::index::load(&root)?;
    super::catalog::reconcile(&root, &mut index)?;
    let meta = index
        .skills
        .get_mut(id)
        .ok_or_else(|| format!("skill not found: {id}"))?;
    let transaction = super::sync::unsync_targets(id, &keys, home, &mut meta.targets)?;
    if let Err(error) = super::index::save(&root, &index) {
        return Err(super::target_tx::rollback_error(transaction, error));
    }
    transaction.commit();
    super::catalog::dto_by_id(&root, &index, id)
}
