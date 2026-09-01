use std::path::Path;

#[cfg(test)]
thread_local! {
    static CHANGE_POINT: std::cell::Cell<u8> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
pub fn change_target_during_prepare(point: u8) {
    CHANGE_POINT.with(|value| value.set(point));
}

#[cfg(test)]
pub fn inject_change(point: u8, path: &Path) {
    if CHANGE_POINT.with(|value| value.get() == point && value.replace(0) == point) {
        if point == 7 {
            std::fs::remove_dir_all(path).unwrap();
            std::fs::create_dir(path).unwrap();
            std::fs::write(path.join("SKILL.md"), "---\nname: replacement\n---\n").unwrap();
            std::fs::write(path.join("value.txt"), "replaced-at-7").unwrap();
            return;
        }
        if matches!(point, 3 | 4) {
            std::fs::create_dir_all(path).unwrap();
        }
        std::fs::write(path.join("value.txt"), format!("changed-at-{point}")).unwrap();
    }
}

#[cfg(test)]
pub fn inject_relocation(source: &Path, destination: &Path) {
    let point = CHANGE_POINT.with(|value| value.get());
    if point == 5 {
        CHANGE_POINT.with(|value| value.set(0));
        std::fs::write(destination.join("value.txt"), "changed-at-5").unwrap();
    } else if point == 6 {
        CHANGE_POINT.with(|value| value.set(0));
        std::fs::create_dir_all(source).unwrap();
        std::fs::write(source.join("value.txt"), "reappeared-source").unwrap();
        std::fs::write(destination.join("value.txt"), "changed-at-6").unwrap();
    } else if point == 8
        && source
            .file_name()
            .is_some_and(|name| name.to_string_lossy().starts_with(".ccbud-sync-stage"))
    {
        CHANGE_POINT.with(|value| value.set(0));
        std::fs::write(destination.join("value.txt"), "changed-at-8").unwrap();
    }
}

#[cfg(not(test))]
pub fn inject_change(_point: u8, _path: &Path) {}

#[cfg(not(test))]
pub fn inject_relocation(_source: &Path, _destination: &Path) {}
