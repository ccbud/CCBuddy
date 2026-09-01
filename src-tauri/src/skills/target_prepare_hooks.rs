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
        if matches!(point, 3 | 4) {
            std::fs::create_dir_all(path).unwrap();
        }
        std::fs::write(path.join("value.txt"), format!("changed-at-{point}")).unwrap();
    }
}

#[cfg(not(test))]
pub fn inject_change(_point: u8, _path: &Path) {}
