use std::path::Path;

pub fn create(source: &Path, stage: &Path, mode: &str) -> Result<String, String> {
    if mode == "copy" {
        super::transfer::copy_directory(source, stage)?;
        return Ok("copy".into());
    }
    match create_symlink(source, stage) {
        Ok(()) => Ok("symlink".into()),
        Err(error) if mode == "auto" => {
            if let Some(root) = stage.parent() {
                let _ = super::paths::remove_direct_child(root, stage);
            }
            super::transfer::copy_directory(source, stage)
                .map_err(|copy| format!("symlink failed ({error}); copy failed ({copy})"))?;
            Ok("copy".into())
        }
        Err(error) => Err(error),
    }
}

#[cfg(target_os = "macos")]
pub fn install_noreplace(source: &Path, target: &Path) -> std::io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let source = std::ffi::CString::new(source.as_os_str().as_bytes())?;
    let target = std::ffi::CString::new(target.as_os_str().as_bytes())?;
    let result = unsafe { libc::renamex_np(source.as_ptr(), target.as_ptr(), libc::RENAME_EXCL) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(target_os = "linux")]
pub fn install_noreplace(source: &Path, target: &Path) -> std::io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let source = std::ffi::CString::new(source.as_os_str().as_bytes())?;
    let target = std::ffi::CString::new(target.as_os_str().as_bytes())?;
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            target.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(target_os = "windows")]
pub fn install_noreplace(source: &Path, target: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;

    #[link(name = "kernel32")]
    extern "system" {
        fn MoveFileExW(existing: *const u16, target: *const u16, flags: u32) -> i32;
    }

    let source: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let target: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
    let result = unsafe { MoveFileExW(source.as_ptr(), target.as_ptr(), 0) };
    if result != 0 {
        Ok(())
    } else {
        let error = std::io::Error::last_os_error();
        if matches!(error.raw_os_error(), Some(80) | Some(183)) {
            Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                error,
            ))
        } else {
            Err(error)
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
pub fn install_noreplace(_source: &Path, _target: &Path) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "atomic no-replace rename is unavailable on this platform",
    ))
}

#[cfg(unix)]
fn create_symlink(source: &Path, target: &Path) -> Result<(), String> {
    std::os::unix::fs::symlink(source, target)
        .map_err(|error| format!("create symlink {}: {error}", target.display()))
}

#[cfg(windows)]
fn create_symlink(source: &Path, target: &Path) -> Result<(), String> {
    std::os::windows::fs::symlink_dir(source, target)
        .map_err(|error| format!("create directory link {}: {error}", target.display()))
}
