use super::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "ccbud-skills-commit-{}-{}-{sequence}",
            std::process::id(),
            paths::now_ms()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn make_skill(path: &Path, body: &str) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(
        path.join("SKILL.md"),
        "---\nname: Commit Guard\ndescription: test\n---\n",
    )
    .unwrap();
    std::fs::write(path.join("value.txt"), body).unwrap();
}

fn fixture() -> (TempDir, PathBuf, PathBuf, String) {
    let temp = TempDir::new();
    let root = temp.0.join("central");
    let home = temp.0.join("home");
    let source = temp.0.join("source");
    make_skill(&source, "managed");
    let id = install::import_local(&root, &source).unwrap().id;
    (temp, root, home, id)
}

fn target(home: &Path, id: &str) -> PathBuf {
    home.join(".config/agents/skills").join(id)
}

#[test]
fn commit_rechecks_current_and_restores_the_previous_index() {
    for replace_current in [false, true] {
        let (_temp, root, home, id) = fixture();
        let requested_target = target(&home, &id);
        make_skill(&requested_target, "user-owned");
        let authorization = ops::sync_conflicts(&root, &home, &id, vec!["amp".into()]).unwrap();
        let target = PathBuf::from(&authorization[0].path);
        let previous_index = index::load(&root).unwrap();
        let previous_bytes = std::fs::read(root.join(".ccbud-index.json")).unwrap();
        let expectation =
            target_prepare::Expectation::Authorized(authorization.first().cloned().unwrap());
        let swap = target_prepare::prepare(
            &root.join(&id),
            target.parent().unwrap(),
            &target,
            "copy",
            &expectation,
        )
        .unwrap();
        let backup = swap.backup.clone().unwrap();
        let mut transaction = target_tx::SyncTransaction::new();
        transaction.push(swap);
        let mut updated_index = previous_index.clone();
        updated_index.skills.get_mut(&id).unwrap().targets = vec![model::TargetMeta {
            key: "amp".into(),
            path: target.to_string_lossy().to_string(),
            sync_mode: "copy".into(),
            status: "ok".into(),
        }];
        index::save(&root, &updated_index).unwrap();

        if replace_current {
            std::fs::remove_dir_all(&target).unwrap();
            make_skill(&target, "external-replacement");
        } else {
            std::fs::write(target.join("value.txt"), "external-edit").unwrap();
        }
        let expected = if replace_current {
            "external-replacement"
        } else {
            "external-edit"
        };
        let error =
            target_tx::commit_after_index_save(transaction, &root, &previous_index).unwrap_err();

        assert!(error.contains("sync target changed"));
        assert_eq!(
            std::fs::read(root.join(".ccbud-index.json")).unwrap(),
            previous_bytes
        );
        assert_eq!(
            std::fs::read_to_string(target.join("value.txt")).unwrap(),
            expected
        );
        assert_eq!(
            std::fs::read_to_string(backup.join("value.txt")).unwrap(),
            "user-owned"
        );
    }
}

#[test]
fn unchecked_replacement_and_removal_have_commit_guards() {
    let (_temp, root, home, id) = fixture();
    let target = target(&home, &id);
    make_skill(&target, "previous-managed");
    let swap =
        target_tx::prepare(&root.join(&id), target.parent().unwrap(), &target, "copy").unwrap();
    let replacement_backup = swap.backup.clone().unwrap();
    let mut replacement = target_tx::SyncTransaction::new();
    replacement.push(swap);
    std::fs::write(target.join("value.txt"), "external-edit").unwrap();
    assert!(replacement.commit().is_err());
    assert_eq!(
        std::fs::read_to_string(replacement_backup.join("value.txt")).unwrap(),
        "previous-managed"
    );

    let removal_target = home.join("removal-target");
    make_skill(&removal_target, "before-removal");
    let swap = target_tx::prepare_remove(&home, &removal_target)
        .unwrap()
        .unwrap();
    let removal_backup = swap.backup.clone().unwrap();
    let mut removal = target_tx::SyncTransaction::new();
    removal.push(swap);
    make_skill(&removal_target, "external-replacement");
    assert!(removal.commit().is_err());
    assert_eq!(
        std::fs::read_to_string(removal_target.join("value.txt")).unwrap(),
        "external-replacement"
    );
    assert_eq!(
        std::fs::read_to_string(removal_backup.join("value.txt")).unwrap(),
        "before-removal"
    );
}

#[test]
fn commit_validates_every_swap_before_deleting_any_backup() {
    let (_temp, root, home, id) = fixture();
    let cursor = home.join(".cursor/skills").join(&id);
    let amp = target(&home, &id);
    make_skill(&cursor, "cursor-user-owned");
    make_skill(&amp, "amp-user-owned");
    let conflicts =
        ops::sync_conflicts(&root, &home, &id, vec!["cursor".into(), "amp".into()]).unwrap();
    let mut transaction = target_tx::SyncTransaction::new();
    let mut backups = Vec::new();
    for conflict in conflicts {
        let target = PathBuf::from(&conflict.path);
        let swap = target_prepare::prepare(
            &root.join(&id),
            target.parent().unwrap(),
            &target,
            "copy",
            &target_prepare::Expectation::Authorized(conflict),
        )
        .unwrap();
        backups.push(swap.backup.clone().unwrap());
        transaction.push(swap);
    }
    std::fs::write(backups.last().unwrap().join("value.txt"), "tampered").unwrap();

    assert!(transaction.commit().is_err());
    assert!(backups.iter().all(|backup| backup.exists()));
}

#[test]
fn commit_cleanup_does_not_delete_a_replaced_backup_path() {
    let (_temp, root, home, id) = fixture();
    let requested_target = target(&home, &id);
    make_skill(&requested_target, "user-owned");
    let conflicts = ops::sync_conflicts(&root, &home, &id, vec!["amp".into()]).unwrap();
    let target = PathBuf::from(&conflicts[0].path);
    let mut swap = target_prepare::prepare(
        &root.join(&id),
        target.parent().unwrap(),
        &target,
        "copy",
        &target_prepare::Expectation::Authorized(conflicts[0].clone()),
    )
    .unwrap();
    let backup = swap.backup.clone().unwrap();
    swap.validate_for_commit().unwrap();
    std::fs::remove_dir_all(&backup).unwrap();
    make_skill(&backup, "racing-replacement");

    swap.commit();

    assert_eq!(
        std::fs::read_to_string(backup.join("value.txt")).unwrap(),
        "racing-replacement"
    );
    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "managed"
    );
}
