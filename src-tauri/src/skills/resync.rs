use super::model::TargetMeta;
use std::collections::HashMap;
use std::path::Path;

pub fn all(
    source: &Path,
    id: &str,
    home: &Path,
    targets: &mut [TargetMeta],
) -> super::target_tx::SyncTransaction {
    let mut outcomes: HashMap<String, Result<String, String>> = HashMap::new();
    let mut transaction = super::target_tx::SyncTransaction::new();
    for target in targets {
        if !outcomes.contains_key(&target.path) {
            let result = prepare_recorded(source, id, target, home).map(|swap| {
                let mode = swap.actual_mode.clone();
                transaction.push(swap);
                mode
            });
            outcomes.insert(target.path.clone(), result);
        }
        match outcomes.get(&target.path).expect("inserted above") {
            Ok(mode) => {
                target.sync_mode = mode.clone();
                target.status = "ok".into();
            }
            Err(_) => target.status = "error".into(),
        }
    }
    transaction
}

fn prepare_recorded(
    source: &Path,
    id: &str,
    target: &TargetMeta,
    home: &Path,
) -> Result<super::target_tx::TargetSwap, String> {
    let mut root = super::sync::checked_target_root(id, target, home)?;
    std::fs::create_dir_all(&root)
        .map_err(|e| format!("create tool skills directory {}: {e}", root.display()))?;
    root = root
        .canonicalize()
        .map_err(|e| format!("resolve tool skills directory: {e}"))?;
    let path = root.join(id);
    if Path::new(&target.path) != path {
        return Err(format!("refusing unsafe recorded target: {}", target.path));
    }
    super::target_tx::prepare(
        source,
        &root,
        &path,
        super::sync::effective_mode(
            &target.key,
            super::sync::normalize_mode(&target.sync_mode).unwrap_or("auto"),
        ),
    )
}
