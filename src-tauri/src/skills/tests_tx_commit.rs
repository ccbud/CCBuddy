use super::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "ccbud-skills-commit-{label}-{}-{}-{id}",
            std::process::id(),
            paths::now_ms()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let name = self.0.file_name().and_then(|v| v.to_str()).unwrap_or("");
        if name.starts_with("ccbud-skills-commit-") {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

fn make_skill(path: &Path, body: &str) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(
        path.join("SKILL.md"),
        "---\nname: Transaction\ndescription: test\n---\n",
    )
    .unwrap();
    std::fs::write(path.join("value.txt"), body).unwrap();
}

fn read_value(path: &Path) -> String {
    std::fs::read_to_string(path.join("value.txt")).unwrap()
}

fn has_transaction_artifact(root: &Path) -> bool {
    root.read_dir()
        .into_iter()
        .flatten()
        .flatten()
        .any(|entry| {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            name.starts_with(".ccbud-sync-") || name.starts_with(".ccbud-remove-backup-")
        })
}

fn fixture(label: &str) -> (TempDir, PathBuf, PathBuf, PathBuf, String) {
    let temp = TempDir::new(label);
    let root = temp.0.join("central");
    let home = temp.0.join("home");
    let source = temp.0.join("source");
    make_skill(&source, "before");
    let id = install::import_local(&root, &source).unwrap().id;
    (temp, root, home, source, id)
}

#[test]
fn update_save_failure_restores_targets_and_central() {
    let (_temp, root, home, source, id) = fixture("update-rollback");
    ops::sync(&root, &home, &id, vec!["cursor".into()], Some("copy")).unwrap();
    let target = home.join(".cursor/skills").join(&id);
    make_skill(&source, "after");

    index::fail_next_save();
    assert!(install::update_source(&root, &home, &id).is_err());

    assert_eq!(read_value(&root.join(&id)), "before");
    assert_eq!(read_value(&target), "before");
    assert_eq!(index::load(&root).unwrap().skills[&id].targets.len(), 1);
    assert!(!has_transaction_artifact(&root));
    assert!(!has_transaction_artifact(target.parent().unwrap()));
}

#[test]
fn missing_central_update_rolls_back_and_can_recover() {
    let (_temp, root, home, source, id) = fixture("missing-update");
    ops::sync(&root, &home, &id, vec!["cursor".into()], Some("copy")).unwrap();
    let target = home.join(".cursor/skills").join(&id);
    paths::remove_direct_child(&root, &root.join(&id)).unwrap();
    make_skill(&source, "after");

    index::fail_next_save();
    assert!(install::update_source(&root, &home, &id).is_err());
    assert!(!root.join(&id).exists());
    assert_eq!(read_value(&target), "before");

    install::update_source(&root, &home, &id).unwrap();
    assert_eq!(read_value(&root.join(&id)), "after");
    assert_eq!(read_value(&target), "after");
    assert!(!has_transaction_artifact(&root));
    assert!(!has_transaction_artifact(target.parent().unwrap()));
}

#[cfg(unix)]
#[test]
fn update_replaces_a_central_link_without_following_it() {
    let (temp, root, home, source, id) = fixture("central-link");
    let central = root.join(&id);
    let outside = temp.0.join("outside");
    make_skill(&outside, "outside");
    paths::remove_direct_child(&root, &central).unwrap();
    std::os::unix::fs::symlink(&outside, &central).unwrap();
    make_skill(&source, "after");

    install::update_source(&root, &home, &id).unwrap();

    assert_eq!(read_value(&central), "after");
    assert!(!std::fs::symlink_metadata(&central)
        .unwrap()
        .file_type()
        .is_symlink());
    assert_eq!(read_value(&outside), "outside");
    assert!(!has_transaction_artifact(&root));
}

#[test]
fn unsync_save_failure_rolls_back_and_success_commits() {
    let (_temp, root, home, _source, id) = fixture("unsync");
    ops::sync(
        &root,
        &home,
        &id,
        vec!["cursor".into(), "amp".into()],
        Some("copy"),
    )
    .unwrap();
    let cursor = home.join(".cursor/skills").join(&id);
    let amp = home.join(".config/agents/skills").join(&id);

    index::fail_next_save();
    assert!(ops::unsync(&root, &home, &id, vec!["cursor".into(), "amp".into()]).is_err());
    assert!(cursor.exists() && amp.exists());
    assert_eq!(index::load(&root).unwrap().skills[&id].targets.len(), 2);

    ops::unsync(&root, &home, &id, vec!["cursor".into(), "amp".into()]).unwrap();
    assert!(!cursor.exists() && !amp.exists());
    assert!(index::load(&root).unwrap().skills[&id].targets.is_empty());
    assert!(!has_transaction_artifact(cursor.parent().unwrap()));
    assert!(!has_transaction_artifact(amp.parent().unwrap()));
}

#[test]
fn delete_save_failure_rolls_back_and_success_commits() {
    let (_temp, root, home, _source, id) = fixture("delete");
    ops::sync(&root, &home, &id, vec!["amp".into()], Some("copy")).unwrap();
    let central = root.join(&id);
    let target = home.join(".config/agents/skills").join(&id);

    index::fail_next_save();
    assert!(remove::delete(&root, &home, &id).is_err());
    assert!(central.exists() && target.exists());
    assert!(index::load(&root).unwrap().skills.contains_key(&id));

    assert!(remove::delete(&root, &home, &id).unwrap());
    assert!(!central.exists() && !target.exists());
    assert!(!index::load(&root).unwrap().skills.contains_key(&id));
    assert!(!has_transaction_artifact(&root));
    assert!(!has_transaction_artifact(target.parent().unwrap()));
}
