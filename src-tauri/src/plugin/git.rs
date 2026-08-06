// Git-sourced plugins: clone + build + install, remote version check, and update. Moved
// verbatim from plugin.rs.

use serde_json::{json, Value};
use std::process::Command;
use std::time::Duration;

use super::manager::PluginManager;
use super::manifest::Manifest;
use super::util::{
    build_env_path, copy_dir_all, github_raw, platform_key, plugins_root, unique_suffix, version_gt,
};

impl PluginManager {
    /// Install (or update) a plugin from a git repository: shallow-clone, run the
    /// manifest's build command, verify the binary exists, then install. Returns
    /// the plugin id.
    ///
    /// SECURITY: this clones and *builds* code from a user-supplied URL — i.e. it
    /// runs arbitrary code. The UI warns the user to import only trusted sources.
    pub fn install_from_git(&self, url: &str) -> Result<String, String> {
        let url = url.trim();
        if url.is_empty() {
            return Err("git 地址为空".into());
        }
        let _ = std::fs::create_dir_all(plugins_root());
        let tmp = plugins_root().join(format!(".import-{}", unique_suffix()));
        let _ = std::fs::remove_dir_all(&tmp);

        let out = Command::new("git")
            .args(["clone", "--depth", "1", url])
            .arg(&tmp)
            .output()
            .map_err(|e| format!("git 不可用: {}", e))?;
        if !out.status.success() {
            let _ = std::fs::remove_dir_all(&tmp);
            return Err(format!("git clone 失败: {}", String::from_utf8_lossy(&out.stderr).trim()));
        }

        let man = match Manifest::load(tmp.clone()) {
            Some(m) => m,
            None => {
                let _ = std::fs::remove_dir_all(&tmp);
                return Err("仓库根目录没有有效的 plugin.json".into());
            }
        };

        // The shallow clone above fetched the repo's default branch. If the manifest
        // pins a different source branch, switch to it so update() installs the code
        // that check_update() compared against (both use source.branch).
        let mut man = man;
        let branch = man.source_branch.trim().to_string();
        if !branch.is_empty() && branch != "main" {
            let fetched = Command::new("git")
                .arg("-C").arg(&tmp)
                .args(["fetch", "--depth", "1", "origin", &branch])
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);
            if fetched {
                let _ = Command::new("git").arg("-C").arg(&tmp).args(["checkout", "FETCH_HEAD"]).output();
                if let Some(m) = Manifest::load(tmp.clone()) {
                    man = m; // re-read from the pinned branch
                }
            }
        }

        if !man.source_build.trim().is_empty() {
            let built = Command::new("sh")
                .arg("-c")
                .arg(man.source_build.trim())
                .current_dir(&tmp)
                .env("PATH", build_env_path())
                .output();
            match built {
                Ok(o) if o.status.success() => {}
                Ok(o) => {
                    let _ = std::fs::remove_dir_all(&tmp);
                    return Err(format!(
                        "构建失败 (`{}`): {}",
                        man.source_build.trim(),
                        String::from_utf8_lossy(&o.stderr).trim()
                    ));
                }
                Err(e) => {
                    let _ = std::fs::remove_dir_all(&tmp);
                    return Err(format!("执行构建命令失败: {}", e));
                }
            }
        }

        match man.exec_path() {
            Some(p) if p.exists() => {}
            _ => {
                let _ = std::fs::remove_dir_all(&tmp);
                return Err(format!(
                    "构建后未找到当前平台二进制 ({})；请检查 plugin.json 的 runtime.exec / source.build",
                    platform_key()
                ));
            }
        }

        let _ = self.stop(&man.id);
        let dst = self.plugin_dir(&man.id);
        if dst.exists() {
            if let Err(e) = std::fs::remove_dir_all(&dst) {
                let _ = std::fs::remove_dir_all(&tmp);
                return Err(format!("移除旧版本失败: {}", e));
            }
        }
        if let Err(e) = copy_dir_all(&tmp, &dst) {
            let _ = std::fs::remove_dir_all(&tmp);
            return Err(format!("安装失败: {}", e));
        }
        let _ = std::fs::remove_dir_all(&tmp);
        self.sync_providers(); // installing/updating from git auto-adds its service
        Ok(man.id)
    }

    /// Check the plugin's git source for a newer version by fetching the remote
    /// plugin.json (GitHub raw) and comparing versions.
    pub async fn check_update(&self, id: &str) -> Value {
        let man = match self.manifest(id) {
            Some(m) => m,
            None => return json!({ "hasSource": false }),
        };
        if man.source_git.trim().is_empty() {
            return json!({ "hasSource": false, "current": man.version });
        }
        let raw = match github_raw(&man.source_git, &man.source_branch, "plugin.json") {
            Some(u) => u,
            None => {
                return json!({ "hasSource": true, "current": man.version, "error": "仅支持 github.com 来源的更新检查" })
            }
        };
        let latest = match self.client.get(&raw).timeout(Duration::from_secs(10)).send().await {
            Ok(r) if r.status().is_success() => match r.json::<Value>().await {
                Ok(v) => v.get("version").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                Err(_) => String::new(),
            },
            _ => String::new(),
        };
        if latest.is_empty() {
            return json!({ "hasSource": true, "current": man.version, "error": "无法获取远端版本" });
        }
        json!({
            "hasSource": true,
            "current": man.version,
            "latest": latest,
            "updateAvailable": version_gt(&latest, &man.version),
        })
    }

    /// Update a plugin by re-installing from its recorded git source.
    pub fn update(&self, id: &str) -> Result<String, String> {
        let man = self.manifest(id).ok_or_else(|| format!("插件 '{}' 未找到", id))?;
        if man.source_git.trim().is_empty() {
            return Err("该插件没有 git 来源，无法更新".into());
        }
        let url = man.source_git.clone();
        self.install_from_git(&url)
    }
}
