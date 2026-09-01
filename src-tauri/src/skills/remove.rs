use std::path::Path;

pub fn delete(root: &Path, home: &Path, id: &str) -> Result<bool, String> {
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let mut index = super::index::load(&root)?;
    super::catalog::reconcile(&root, &mut index)?;
    super::paths::validate_id(id)?;
    let path = root.join(id);
    let existed = std::fs::symlink_metadata(&path).is_ok() || index.skills.contains_key(id);
    let targets = index
        .skills
        .get(id)
        .map(|meta| meta.targets.clone())
        .unwrap_or_default();
    let mut transaction = super::sync::cleanup_all(id, home, &targets)?;
    match super::target_tx::prepare_remove(&root, &path) {
        Ok(Some(swap)) => transaction.push(swap),
        Ok(None) => {}
        Err(error) => {
            return Err(super::target_tx::rollback_error(transaction, error));
        }
    }
    index.skills.remove(id);
    if let Err(error) = super::index::save(&root, &index) {
        return Err(super::target_tx::rollback_error(transaction, error));
    }
    transaction.commit();
    Ok(existed)
}
