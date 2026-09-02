use super::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "ccbud-skills-confirmation-{}-{}-{}",
            std::process::id(),
            paths::now_ms(),
            NEXT.fetch_add(1, Ordering::Relaxed)
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

fn make_skill(path: &Path, value: &str) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(path.join("SKILL.md"), "---\nname: Guard\n---\n").unwrap();
    std::fs::write(path.join("value.txt"), value).unwrap();
}

#[test]
fn external_confirmation_rejects_identical_recreated_target() {
    let temp = TempDir::new();
    let target = temp.0.join("target");
    make_skill(&target, "identical");
    let keys = vec!["amp".into()];
    let stale = model::SyncConflictDto {
        skill_id: "guard".into(),
        path: target.to_string_lossy().into_owned(),
        keys: keys.clone(),
        fingerprint_token: target_fingerprint::confirmation_token("guard", &target, &keys).unwrap(),
    };

    std::fs::remove_dir_all(&target).unwrap();
    make_skill(&target, "identical");

    assert!(!target_fingerprint::matches_confirmation(&stale, &target, &target).unwrap());
    let refreshed = target_fingerprint::confirmation_token("guard", &target, &keys).unwrap();
    assert_ne!(stale.fingerprint_token, refreshed);
}

#[test]
fn pin_issuance_rejects_replacement_during_snapshot() {
    let temp = TempDir::new();
    let target = temp.0.join("target");
    make_skill(&target, "identical");
    let pending = target_pin::begin(&target).unwrap();

    std::fs::remove_dir_all(&target).unwrap();
    make_skill(&target, "identical");

    let error = pending.finish(&target, "same-snapshot", false).unwrap_err();
    assert!(error.contains("changed while pinning"));
}

#[test]
fn internal_v2_guard_cannot_authorize_an_external_overwrite() {
    let temp = TempDir::new();
    let root = temp.0.join("central");
    let home = temp.0.join("home");
    let source = temp.0.join("source");
    make_skill(&source, "managed");
    let id = install::import_local(&root, &source).unwrap().id;
    let target = home.join(".config/agents/skills").join(&id);
    make_skill(&target, "user-owned");
    let mut authorizing = ops::sync_conflicts(&root, &home, &id, vec!["amp".into()]).unwrap();
    authorizing[0].fingerprint_token = authorizing[0]
        .fingerprint_token
        .strip_prefix("v3:")
        .and_then(|value| value.split_once(':'))
        .map(|(_, inner)| inner.to_string())
        .unwrap();

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
        "user-owned"
    );
}

#[test]
fn failed_post_move_validation_restores_changed_entry() {
    let temp = TempDir::new();
    let target = temp.0.join("target");
    let backup = temp.0.join("backup");
    make_skill(&target, "user-owned");
    let guard = target_fingerprint::capture_state(&target, &target).unwrap();
    target_prepare::change_target_during_prepare(5);

    let error =
        target_fingerprint::relocate_noreplace(&guard, &target, &target, &backup).unwrap_err();

    assert!(error.contains("changed while relocating"));
    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "changed-at-5"
    );
    assert!(!backup.exists());
}

#[test]
fn failed_post_move_validation_never_overwrites_reappeared_source() {
    let temp = TempDir::new();
    let target = temp.0.join("target");
    let backup = temp.0.join("backup");
    make_skill(&target, "user-owned");
    let guard = target_fingerprint::capture_state(&target, &target).unwrap();
    target_prepare::change_target_during_prepare(6);

    let error =
        target_fingerprint::relocate_noreplace(&guard, &target, &target, &backup).unwrap_err();

    assert!(error.contains("source reappeared"));
    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "reappeared-source"
    );
    assert_eq!(
        std::fs::read_to_string(backup.join("value.txt")).unwrap(),
        "changed-at-6"
    );
}

#[test]
fn transaction_pin_survives_external_pin_eviction() {
    let temp = TempDir::new();
    let target = temp.0.join("target");
    let moved = temp.0.join("moved");
    make_skill(&target, "leased");
    let guard = target_fingerprint::capture_state(&target, &target).unwrap();
    let moved_guard =
        target_fingerprint::relocate_noreplace(&guard, &target, &target, &moved).unwrap();

    for index in 0..300 {
        let external = temp.0.join(format!("external-{index}"));
        make_skill(&external, "pending");
        target_fingerprint::confirmation_token("pending", &external, &["amp".into()]).unwrap();
    }

    assert!(target_fingerprint::matches_confirmation(&moved_guard, &target, &moved).unwrap());
    target_fingerprint::revoke_confirmation(&moved_guard);
}
