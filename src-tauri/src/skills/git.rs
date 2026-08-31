use std::path::{Path, PathBuf};
use std::process::Command;

pub struct GitCheckout {
    root: PathBuf,
    pub dir: PathBuf,
    pub revision: String,
}

impl Drop for GitCheckout {
    fn drop(&mut self) {
        let _ = super::paths::remove_direct_child(&self.root, &self.dir);
    }
}

pub fn validate_url(value: &str) -> Result<String, String> {
    let url = value.trim();
    if url != value || url.len() < 8 || url.len() > 2048 || url.starts_with('-') {
        return Err("invalid git URL".into());
    }
    if url.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err("git URL contains invalid characters".into());
    }
    let path = if let Some(rest) = url.strip_prefix("https://") {
        let (host, path) = rest
            .split_once('/')
            .ok_or("git URL must include a repository path")?;
        if host.is_empty() || host.contains('@') || host == "localhost" {
            return Err("git URL host is not allowed".into());
        }
        path
    } else if let Some(rest) = url.strip_prefix("ssh://") {
        let (_, path) = rest
            .split_once('/')
            .ok_or("git URL must include a repository path")?;
        path
    } else if let Some(rest) = url.strip_prefix("git@") {
        let (_, path) = rest.split_once(':').ok_or("invalid SSH git URL")?;
        path
    } else {
        return Err("only HTTPS and SSH git URLs are supported".into());
    };
    if path.is_empty() || path.split('/').any(|part| part == ".." || part.is_empty()) {
        return Err("invalid git repository path".into());
    }
    Ok(url.to_string())
}

pub fn clone_shallow(root: &Path, value: &str) -> Result<GitCheckout, String> {
    clone_with_program(root, value, Path::new("git"))
}

fn clone_with_program(root: &Path, value: &str, program: &Path) -> Result<GitCheckout, String> {
    let url = validate_url(value)?;
    let dir = super::transfer::unique_hidden(root, "git");
    let output = Command::new(program)
        .args(["clone", "--depth", "1", "--no-tags", "--"])
        .arg(&url)
        .arg(&dir)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_SSH_COMMAND", "ssh -oBatchMode=yes -oConnectTimeout=15")
        .output()
        .map_err(|e| format!("start git: {e}"))?;
    if !output.status.success() {
        let _ = super::paths::remove_direct_child(root, &dir);
        return Err(format!("git clone failed: {}", stderr_text(&output.stderr)));
    }
    let revision = match git_output(program, &dir, &["rev-parse", "HEAD"]) {
        Ok(value) => value,
        Err(error) => {
            let _ = super::paths::remove_direct_child(root, &dir);
            return Err(error);
        }
    };
    Ok(GitCheckout {
        root: root.to_path_buf(),
        dir,
        revision,
    })
}

pub fn remote_head(value: &str) -> Result<String, String> {
    let url = validate_url(value)?;
    let output = Command::new("git")
        .args(["ls-remote", "--"])
        .arg(url)
        .arg("HEAD")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_SSH_COMMAND", "ssh -oBatchMode=yes -oConnectTimeout=15")
        .output()
        .map_err(|e| format!("start git: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "git refresh failed: {}",
            stderr_text(&output.stderr)
        ));
    }
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .next()
        .filter(|value| value.len() >= 7 && value.chars().all(|c| c.is_ascii_hexdigit()))
        .map(str::to_string)
        .ok_or_else(|| "git remote did not return HEAD".into())
}

fn git_output(program: &Path, dir: &Path, args: &[&str]) -> Result<String, String> {
    let output = Command::new(program)
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .map_err(|e| format!("start git: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "git command failed: {}",
            stderr_text(&output.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

#[cfg(test)]
pub fn clone_with_test_program(
    root: &Path,
    value: &str,
    program: &Path,
) -> Result<GitCheckout, String> {
    clone_with_program(root, value, program)
}

fn stderr_text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).chars().take(800).collect()
}
