use super::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "ccbud-skills-guards-{label}-{}-{}-{sequence}",
            std::process::id(),
            paths::now_ms()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        if self
            .0
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .starts_with("ccbud-skills-")
        {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

fn make_skill(path: &Path, body: &str) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(
        path.join("SKILL.md"),
        "---\nname: Guard\ndescription: test\n---\n",
    )
    .unwrap();
    std::fs::write(path.join("value.txt"), body).unwrap();
}

fn fixture(label: &str) -> (TempDir, PathBuf, PathBuf, String) {
    let temp = TempDir::new(label);
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
fn conflict_fingerprint_rejects_excessive_depth() {
    let (_temp, root, home, id) = fixture("depth-limit");
    let target = target(&home, &id);
    make_skill(&target, "user-owned");
    let mut nested = target.clone();
    for _ in 0..65 {
        nested.push("nested");
        std::fs::create_dir(&nested).unwrap();
    }
    let error = ops::sync_conflicts(&root, &home, &id, vec!["amp".into()]).unwrap_err();
    assert!(error.contains("exceeds maximum depth"));
}

#[test]
fn authorized_prepare_rechecks_after_staging_and_backup_move() {
    for point in [1, 2] {
        let (_temp, root, home, id) = fixture("prepare-race");
        let target = target(&home, &id);
        make_skill(&target, "user-owned");
        let authorizing = ops::sync_conflicts(&root, &home, &id, vec!["amp".into()]).unwrap();
        target_prepare::change_target_during_prepare(point);

        let error = ops::sync(
            &root,
            &home,
            &id,
            vec!["amp".into()],
            Some("copy"),
            authorizing,
        )
        .unwrap_err();

        let conflicts = match error {
            model::SkillsSyncErrorDto::ConfirmationRequired { conflicts } => conflicts,
            other => panic!("unexpected error: {other:?}"),
        };
        assert_eq!(conflicts.len(), 1);
        assert_eq!(
            std::fs::read_to_string(target.join("value.txt")).unwrap(),
            format!("changed-at-{point}")
        );
        assert!(index::load(&root).unwrap().skills[&id].targets.is_empty());
    }
}

#[test]
fn target_appearing_during_staging_requires_confirmation() {
    for point in [3, 4] {
        let (_temp, root, home, id) = fixture("missing-race");
        let target = target(&home, &id);
        target_prepare::change_target_during_prepare(point);
        let error =
            ops::sync(&root, &home, &id, vec!["amp".into()], Some("copy"), vec![]).unwrap_err();
        assert!(matches!(
            error,
            model::SkillsSyncErrorDto::ConfirmationRequired { .. }
        ));
        assert_eq!(
            std::fs::read_to_string(target.join("value.txt")).unwrap(),
            format!("changed-at-{point}")
        );
    }
}

#[test]
fn target_reappearing_after_backup_is_not_overwritten() {
    let (_temp, root, home, id) = fixture("authorized-reappear");
    let target = target(&home, &id);
    make_skill(&target, "user-owned");
    let authorizing = ops::sync_conflicts(&root, &home, &id, vec!["amp".into()]).unwrap();
    target_prepare::change_target_during_prepare(4);

    let error = ops::sync(
        &root,
        &home,
        &id,
        vec!["amp".into()],
        Some("copy"),
        authorizing,
    )
    .unwrap_err();

    assert!(matches!(error, model::SkillsSyncErrorDto::Failed { .. }));
    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "changed-at-4"
    );
    let backup = target
        .parent()
        .unwrap()
        .read_dir()
        .unwrap()
        .flatten()
        .find(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".ccbud-sync-backup-")
        });
    assert_eq!(
        std::fs::read_to_string(backup.unwrap().path().join("value.txt")).unwrap(),
        "user-owned"
    );
}

#[test]
fn tampered_overwrite_backup_is_neither_deleted_nor_restored() {
    for rollback in [false, true] {
        let (_temp, root, home, id) = fixture("backup-guard");
        let target = target(&home, &id);
        make_skill(&target, "user-owned");
        let authorization = ops::sync_conflicts(&root, &home, &id, vec!["amp".into()]).unwrap();
        let target = PathBuf::from(&authorization[0].path);
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
        std::fs::write(backup.join("value.txt"), "tampered-backup").unwrap();
        let mut transaction = target_tx::SyncTransaction::new();
        transaction.push(swap);

        let failed = if rollback {
            transaction.rollback().is_err()
        } else {
            transaction.commit().is_err()
        };
        assert!(failed);
        assert_eq!(
            std::fs::read_to_string(target.join("value.txt")).unwrap(),
            "managed"
        );
        assert_eq!(
            std::fs::read_to_string(backup.join("value.txt")).unwrap(),
            "tampered-backup"
        );
    }
}
