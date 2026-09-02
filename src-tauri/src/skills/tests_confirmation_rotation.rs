use super::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "ccbud-skills-confirmation-rotation-{}-{}-{}",
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

fn make_skill(path: &Path) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(path.join("SKILL.md"), "---\nname: Guard\n---\n").unwrap();
    std::fs::write(path.join("value.txt"), "user-owned").unwrap();
}

fn pin_parts(token: &str) -> (&str, &str) {
    token
        .strip_prefix("v3:")
        .and_then(|value| value.split_once(':'))
        .unwrap()
}

fn lease_state(id: &str) -> Option<bool> {
    target_pin::store()
        .lock()
        .ok()?
        .pins
        .iter()
        .find(|pin| pin.id == id)
        .map(|pin| pin.state == target_pin::PinState::Leased)
}

#[test]
fn external_confirmation_claim_is_exclusive() {
    let temp = TempDir::new();
    let target = temp.0.join("target");
    let moved = temp.0.join("moved");
    let competing = temp.0.join("competing");
    make_skill(&target);
    let external = external_guard(&target);
    let worker_guard = external.clone();
    let worker_target = target.clone();
    let worker_moved = moved.clone();
    let (entered_tx, entered_rx) = std::sync::mpsc::channel();
    let (resume_tx, resume_rx) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        target_pin_rotate_test_hook::pause_after_claim(entered_tx, resume_rx);
        target_fingerprint::relocate_noreplace(
            &worker_guard,
            &worker_target,
            &worker_target,
            &worker_moved,
        )
    });
    entered_rx.recv().unwrap();

    let competing_result =
        target_fingerprint::relocate_noreplace(&external, &target, &target, &competing);
    resume_tx.send(()).unwrap();
    let worker_result = worker.join().unwrap();

    let error = competing_result.unwrap_err();
    assert!(error.contains("already being relocated"));
    let moved_guard = worker_result.unwrap();
    assert!(!target_fingerprint::matches_confirmation(&external, &target, &moved).unwrap());
    assert!(target_fingerprint::matches_confirmation(&moved_guard, &target, &moved).unwrap());
    target_fingerprint::revoke_confirmation(&moved_guard);
}

#[test]
fn concurrent_revoke_does_not_destroy_an_active_claim() {
    let temp = TempDir::new();
    let target = temp.0.join("target");
    let moved = temp.0.join("moved");
    make_skill(&target);
    let external = external_guard(&target);
    let external_id = pin_parts(&external.fingerprint_token).0.to_string();
    let worker_guard = external.clone();
    let worker_target = target.clone();
    let worker_moved = moved.clone();
    let (entered_tx, entered_rx) = std::sync::mpsc::channel();
    let (resume_tx, resume_rx) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        target_pin_rotate_test_hook::pause_after_claim(entered_tx, resume_rx);
        target_fingerprint::relocate_noreplace(
            &worker_guard,
            &worker_target,
            &worker_target,
            &worker_moved,
        )
    });
    entered_rx.recv().unwrap();

    target_fingerprint::revoke_confirmation(&external);
    assert!(target_fingerprint::matches_confirmation(&external, &target, &target).unwrap());
    resume_tx.send(()).unwrap();

    let moved_guard = worker.join().unwrap().unwrap();
    assert_eq!(lease_state(&external_id), None);
    assert!(target_fingerprint::matches_confirmation(&moved_guard, &target, &moved).unwrap());
    target_fingerprint::revoke_confirmation(&moved_guard);
}

fn external_guard(target: &Path) -> model::SyncConflictDto {
    model::SyncConflictDto {
        skill_id: "guard".into(),
        path: target.to_string_lossy().into_owned(),
        keys: vec!["amp".into()],
        fingerprint_token: target_fingerprint::confirmation_token("guard", target, &["amp".into()])
            .unwrap(),
    }
}

#[test]
fn external_confirmation_is_consumed_across_guarded_round_trip() {
    let temp = TempDir::new();
    let target = temp.0.join("target");
    let moved = temp.0.join("moved");
    make_skill(&target);
    let external = external_guard(&target);

    let moved_guard =
        target_fingerprint::relocate_noreplace(&external, &target, &target, &moved).unwrap();
    let (external_id, _) = pin_parts(&external.fingerprint_token);
    let (moved_id, moved_inner) = pin_parts(&moved_guard.fingerprint_token);
    assert_ne!(external_id, moved_id);
    assert_eq!(lease_state(external_id), None);
    assert_eq!(lease_state(moved_id), Some(true));
    assert!(!target_fingerprint::matches_confirmation(&external, &target, &moved).unwrap());

    // A repeated filesystem timestamp cannot revive the consumed external capability.
    let mut timestamp_collision = external.clone();
    timestamp_collision.fingerprint_token = format!("v3:{external_id}:{moved_inner}");
    assert!(
        !target_fingerprint::matches_confirmation(&timestamp_collision, &target, &moved).unwrap()
    );

    let restored_guard =
        target_fingerprint::relocate_noreplace(&moved_guard, &target, &moved, &target).unwrap();
    assert!(!target_fingerprint::matches_confirmation(&external, &target, &target).unwrap());
    assert!(target_fingerprint::matches_confirmation(&restored_guard, &target, &target).unwrap());
    let restored_id = pin_parts(&restored_guard.fingerprint_token).0.to_string();
    assert_eq!(moved_id, restored_id);
    target_fingerprint::revoke_confirmation(&restored_guard);
    assert_eq!(lease_state(&restored_id), None);
}

#[test]
fn failed_external_pin_rotation_restores_source_and_releases_lease() {
    let temp = TempDir::new();
    let target = temp.0.join("target");
    let moved = temp.0.join("moved");
    make_skill(&target);
    let guard = external_guard(&target);
    let id = pin_parts(&guard.fingerprint_token).0.to_string();
    target_pin_rotate_test_hook::fail_next();

    let error =
        target_fingerprint::relocate_noreplace(&guard, &target, &target, &moved).unwrap_err();

    assert!(error.contains("injected target pin rotation failure"));
    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "user-owned"
    );
    assert!(!moved.exists());
    assert_eq!(lease_state(&id), Some(false));
    target_fingerprint::revoke_confirmation(&guard);
    assert_eq!(lease_state(&id), None);
}
