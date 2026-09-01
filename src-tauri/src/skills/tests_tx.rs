use super::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "ccbud-skills-tx-{label}-{}-{}-{id}",
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
        if name.starts_with("ccbud-skills-tx-") {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

fn make_skill(path: &Path, name: &str) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(
        path.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: test\n---\n"),
    )
    .unwrap();
    std::fs::write(path.join("value.txt"), "value").unwrap();
}

fn has_staging(root: &Path) -> bool {
    root.read_dir()
        .into_iter()
        .flatten()
        .flatten()
        .any(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".ccbud-sync-")
        })
}

#[cfg(unix)]
#[test]
fn failed_copy_cleans_stage_and_can_be_retried() {
    let temp = TempDir::new("copy-retry");
    let root = temp.0.join("central");
    let home = temp.0.join("home");
    let source = temp.0.join("source");
    make_skill(&source, "Retry");
    let skill = install::import_local(&root, &source).unwrap();
    let managed = root.join(&skill.id);
    std::os::unix::fs::symlink(source.join("value.txt"), managed.join("bad-link")).unwrap();

    assert!(ops::sync(
        &root,
        &home,
        &skill.id,
        vec!["amp".into()],
        Some("copy"),
        vec![],
    )
    .is_err());
    let target_root = home.join(".config/agents/skills");
    assert!(!target_root.join(&skill.id).exists());
    assert!(!has_staging(&target_root));

    std::fs::remove_file(managed.join("bad-link")).unwrap();
    let retried = ops::sync(
        &root,
        &home,
        &skill.id,
        vec!["amp".into()],
        Some("copy"),
        vec![],
    )
    .unwrap();
    assert_eq!(retried.targets[0].sync_mode, "copy");
}

#[cfg(unix)]
#[test]
fn later_target_failure_rolls_back_an_earlier_target() {
    use std::os::unix::fs::PermissionsExt;

    let temp = TempDir::new("multi-rollback");
    let root = temp.0.join("central");
    let home = temp.0.join("home");
    let source = temp.0.join("source");
    make_skill(&source, "Rollback");
    let skill = install::import_local(&root, &source).unwrap();
    let blocked = home.join(".config/agents/skills");
    std::fs::create_dir_all(&blocked).unwrap();
    std::fs::set_permissions(&blocked, std::fs::Permissions::from_mode(0o500)).unwrap();

    let result = ops::sync(
        &root,
        &home,
        &skill.id,
        vec!["cursor".into(), "amp".into()],
        Some("copy"),
        vec![],
    );
    std::fs::set_permissions(&blocked, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(result.is_err());
    assert!(!home.join(".cursor/skills").join(&skill.id).exists());
    assert!(!blocked.join(&skill.id).exists());
    assert!(!has_staging(&home.join(".cursor/skills")));
    assert!(!has_staging(&blocked));
}

#[test]
fn cursor_always_uses_a_real_copy() {
    let temp = TempDir::new("cursor-copy");
    let root = temp.0.join("central");
    let home = temp.0.join("home");
    let source = temp.0.join("source");
    make_skill(&source, "Cursor Copy");
    let skill = install::import_local(&root, &source).unwrap();
    let synced = ops::sync(
        &root,
        &home,
        &skill.id,
        vec!["cursor".into()],
        Some("symlink"),
        vec![],
    )
    .unwrap();
    let target = home.join(".cursor/skills").join(&skill.id);
    assert_eq!(synced.targets[0].sync_mode, "copy");
    assert!(!std::fs::symlink_metadata(target)
        .unwrap()
        .file_type()
        .is_symlink());
}

#[test]
fn rollback_restores_the_previous_managed_target() {
    let temp = TempDir::new("restore-existing");
    let source = temp.0.join("source");
    let target_root = temp.0.join("targets");
    let target = target_root.join("skill");
    make_skill(&source, "New");
    make_skill(&target, "Old");
    std::fs::write(source.join("value.txt"), "new").unwrap();
    std::fs::write(target.join("value.txt"), "old").unwrap();

    let swap = target_tx::prepare(&source, &target_root, &target, "copy").unwrap();
    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "new"
    );
    let mut transaction = target_tx::SyncTransaction::new();
    transaction.push(swap);
    transaction.rollback().unwrap();

    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "old"
    );
    assert!(!has_staging(&target_root));
}
