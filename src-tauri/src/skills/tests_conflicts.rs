use super::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "ccbud-skills-conflicts-{label}-{}-{}-{id}",
            std::process::id(),
            paths::now_ms()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let name = self
            .0
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        if name.starts_with("ccbud-skills-conflicts-") {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

fn make_skill(path: &Path, body: &str) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(
        path.join("SKILL.md"),
        "---\nname: Conflict\ndescription: test\n---\n",
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

fn shared_target(home: &Path, id: &str) -> PathBuf {
    home.join(".config/agents/skills").join(id)
}

#[test]
fn unmanaged_target_is_rejected_without_overwrite() {
    let (_temp, root, home, id) = fixture("default-reject");
    let target = shared_target(&home, &id);
    make_skill(&target, "user-owned");

    let error = ops::sync(&root, &home, &id, vec!["amp".into()], Some("copy"), vec![]).unwrap_err();

    let conflicts = match error {
        model::SkillsSyncErrorDto::ConfirmationRequired { conflicts } => conflicts,
        other => panic!("unexpected sync error: {other:?}"),
    };
    assert_eq!(conflicts.len(), 1);
    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "user-owned"
    );
    assert!(index::load(&root).unwrap().skills[&id].targets.is_empty());
}

#[test]
fn explicit_overwrite_replaces_unmanaged_target() {
    let (_temp, root, home, id) = fixture("explicit-overwrite");
    let target = shared_target(&home, &id);
    make_skill(&target, "user-owned");
    let authorizing = ops::sync_conflicts(&root, &home, &id, vec!["amp".into()]).unwrap();

    let synced = ops::sync(
        &root,
        &home,
        &id,
        vec!["amp".into()],
        Some("copy"),
        authorizing,
    )
    .unwrap();

    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "managed"
    );
    assert_eq!(synced.targets.len(), 1);
    assert_eq!(synced.targets[0].key, "amp");
}

#[test]
fn conflicts_deduplicate_shared_physical_target_without_writes() {
    let (_temp, root, home, id) = fixture("shared-path");
    let target = shared_target(&home, &id);
    make_skill(&target, "user-owned");
    let index_path = root.join(".ccbud-index.json");
    let index_before = std::fs::read(&index_path).unwrap();

    let conflicts = ops::sync_conflicts(
        &root,
        &home,
        &id,
        vec![
            "kimi_cli".into(),
            "amp".into(),
            "kimi_cli".into(),
            "cursor".into(),
        ],
    )
    .unwrap();

    assert_eq!(conflicts.len(), 1);
    assert_eq!(conflicts[0].skill_id, id);
    assert_eq!(conflicts[0].keys, vec!["amp", "kimi_cli"]);
    assert!(conflicts[0].fingerprint_token.starts_with("v1:"));
    let expected = target.parent().unwrap().canonicalize().unwrap().join(&id);
    assert_eq!(Path::new(&conflicts[0].path), expected);
    assert_eq!(std::fs::read(&index_path).unwrap(), index_before);
    assert!(!home.join(".cursor/skills").exists());
}

#[test]
fn overwrite_rolls_back_unmanaged_target_when_index_save_fails() {
    let (_temp, root, home, id) = fixture("overwrite-rollback");
    let target = shared_target(&home, &id);
    make_skill(&target, "user-owned");
    let authorizing = ops::sync_conflicts(&root, &home, &id, vec!["amp".into()]).unwrap();

    index::fail_next_save();
    assert!(ops::sync(
        &root,
        &home,
        &id,
        vec!["amp".into()],
        Some("copy"),
        authorizing,
    )
    .is_err());

    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "user-owned"
    );
    assert!(index::load(&root).unwrap().skills[&id].targets.is_empty());
    assert!(!target
        .parent()
        .unwrap()
        .read_dir()
        .unwrap()
        .flatten()
        .any(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".ccbud-sync-")
        }));
}

#[test]
fn stale_authorization_rejects_content_edits_and_replacements() {
    for replace_target in [false, true] {
        let (_temp, root, home, id) = fixture("stale-token");
        let target = shared_target(&home, &id);
        make_skill(&target, "user-owned");
        let authorizing = ops::sync_conflicts(&root, &home, &id, vec!["amp".into()]).unwrap();

        if replace_target {
            std::fs::remove_dir_all(&target).unwrap();
            make_skill(&target, "user-owned");
        } else {
            std::fs::write(target.join("value.txt"), "edited-in-place").unwrap();
        }
        let expected = if replace_target {
            "user-owned"
        } else {
            "edited-in-place"
        };
        let error = ops::sync(
            &root,
            &home,
            &id,
            vec!["amp".into()],
            Some("copy"),
            authorizing,
        )
        .unwrap_err();

        assert!(matches!(
            error,
            model::SkillsSyncErrorDto::ConfirmationRequired { .. }
        ));
        assert_eq!(
            std::fs::read_to_string(target.join("value.txt")).unwrap(),
            expected
        );
    }
}
