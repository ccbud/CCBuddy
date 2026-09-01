use super::model::{SkillDto, SkillMeta};
use std::path::{Component, Path, PathBuf};

pub fn import_local(root: &Path, source: &Path) -> Result<SkillDto, String> {
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let source = source
        .canonicalize()
        .map_err(|e| format!("resolve local skill {}: {e}", source.display()))?;
    super::transfer::validate_source(&source)?;
    let mut index = super::index::load(&root)?;
    super::catalog::reconcile(&root, &mut index)?;
    let source_ref = source.to_string_lossy().to_string();
    if let Some((id, _)) = index.skills.iter().find(|(id, meta)| {
        meta.source_type == "local" && meta.source_ref == source_ref && root.join(id).is_dir()
    }) {
        return super::catalog::dto_by_id(&root, &index, id);
    }
    let (name, _) = super::scan::manifest_summary(&source)?;
    let id = super::transfer::available_id(&root, &name);
    let destination = super::transfer::install_copy(&root, &source, &id)?;
    index.skills.insert(
        id.clone(),
        SkillMeta {
            source_type: "local".into(),
            source_ref,
            updated_at: super::scan::modified_ms(&destination.join("SKILL.md")),
            ..SkillMeta::default()
        },
    );
    if let Err(error) = super::index::save(&root, &index) {
        let _ = super::paths::remove_direct_child(&root, &destination);
        return Err(error);
    }
    super::catalog::dto_by_id(&root, &index, &id)
}

pub fn import_git(root: &Path, url: &str) -> Result<Vec<SkillDto>, String> {
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let url = super::git::validate_url(url)?;
    let checkout = super::git::clone_shallow(&root, &url)?;
    let candidates = super::scan::local_candidates(&checkout.dir)?;
    if candidates.is_empty() {
        return Err("git repository does not contain SKILL.md".into());
    }
    let mut index = super::index::load(&root)?;
    super::catalog::reconcile(&root, &mut index)?;
    let mut ids = Vec::new();
    let mut installed = Vec::new();
    for candidate in candidates {
        let source = PathBuf::from(&candidate.path);
        let subdir = relative_subdir(&checkout.dir, &source)?;
        if let Some((id, _)) = index.skills.iter().find(|(id, meta)| {
            meta.source_type == "git"
                && meta.source_ref == url
                && meta.source_subdir == subdir
                && root.join(id).is_dir()
        }) {
            ids.push(id.clone());
            continue;
        }
        let id = super::transfer::available_id(&root, &candidate.name);
        match super::transfer::install_copy(&root, &source, &id) {
            Ok(destination) => {
                index.skills.insert(
                    id.clone(),
                    SkillMeta {
                        source_type: "git".into(),
                        source_ref: url.clone(),
                        source_subdir: subdir,
                        source_revision: Some(checkout.revision.clone()),
                        updated_at: super::scan::modified_ms(&destination.join("SKILL.md")),
                        ..SkillMeta::default()
                    },
                );
                installed.push((id.clone(), destination));
                ids.push(id);
            }
            Err(error) => {
                rollback(&root, &mut index, &installed);
                return Err(error);
            }
        }
    }
    if let Err(error) = super::index::save(&root, &index) {
        rollback(&root, &mut index, &installed);
        return Err(error);
    }
    ids.iter()
        .map(|id| super::catalog::dto_by_id(&root, &index, id))
        .collect()
}

pub fn update_source(root: &Path, home: &Path, id: &str) -> Result<SkillDto, String> {
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let mut index = super::index::load(&root)?;
    let previous_index = index.clone();
    super::catalog::reconcile(&root, &mut index)?;
    let original = index
        .skills
        .get(id)
        .cloned()
        .ok_or_else(|| format!("skill not found: {id}"))?;
    let checkout = match original.source_type.as_str() {
        "git" => Some(super::git::clone_shallow(&root, &original.source_ref)?),
        "local" => None,
        other => return Err(format!("unsupported source_type: {other}")),
    };
    let source = if let Some(checkout) = &checkout {
        checkout_path(&checkout.dir, &original.source_subdir)?
    } else {
        if original.source_ref.trim().is_empty() {
            return Err("local source_ref is empty".into());
        }
        let source = PathBuf::from(&original.source_ref);
        if !source.is_absolute() {
            return Err("local source_ref must be an absolute path".into());
        }
        let source = source
            .canonicalize()
            .map_err(|e| format!("resolve local skill source: {e}"))?;
        if source.starts_with(&root) {
            return Err("managed copy has no external local source to update from".into());
        }
        source
    };
    super::transfer::validate_source(&source)?;
    let (destination, central_swap) = super::transfer::prepare_replace(&root, &source, id)?;
    let mut central_transaction = super::target_tx::SyncTransaction::new();
    central_transaction.push(central_swap);
    let meta = index.skills.get_mut(id).expect("checked above");
    if let Some(checkout) = &checkout {
        meta.source_revision = Some(checkout.revision.clone());
    }
    meta.updated_at = super::scan::modified_ms(&destination.join("SKILL.md"));
    meta.status = "ok".into();
    let transaction = super::resync::all(&destination, id, home, &mut meta.targets);
    central_transaction.append(transaction);
    if let Err(error) = central_transaction.validate_for_commit() {
        return Err(super::target_tx::rollback_error(central_transaction, error));
    }
    if let Err(error) = super::index::save(&root, &index) {
        return Err(super::target_tx::rollback_error(central_transaction, error));
    }
    super::target_tx::commit_after_index_save(central_transaction, &root, &previous_index)?;
    super::catalog::dto_by_id(&root, &index, id)
}

fn relative_subdir(root: &Path, source: &Path) -> Result<String, String> {
    let relative = source
        .strip_prefix(root)
        .map_err(|_| "git skill escaped checkout directory".to_string())?;
    if relative
        .components()
        .any(|part| !matches!(part, Component::Normal(_)))
    {
        return Ok(String::new());
    }
    Ok(relative.to_string_lossy().replace('\\', "/"))
}

fn checkout_path(root: &Path, subdir: &str) -> Result<PathBuf, String> {
    if Path::new(subdir)
        .components()
        .any(|part| !matches!(part, Component::Normal(_)))
    {
        return if subdir.is_empty() {
            Ok(root.to_path_buf())
        } else {
            Err("invalid git skill subdirectory".into())
        };
    }
    Ok(root.join(subdir))
}

fn rollback(root: &Path, index: &mut super::model::SkillsIndex, installed: &[(String, PathBuf)]) {
    for (id, path) in installed {
        let _ = super::paths::remove_direct_child(root, path);
        index.skills.remove(id);
    }
}
