// Local install / uninstall of a plugin directory. Moved verbatim from plugin.rs.

use super::manager::PluginManager;
use super::manifest::Manifest;
use super::util::copy_dir_all;

impl PluginManager {
    /// Install a plugin from a local directory (must contain plugin.json) into
    /// ~/.ccbud/plugins/<id>. Reinstalling replaces the existing copy. Returns
    /// the installed plugin id.
    pub fn install(&self, src: &std::path::Path) -> Result<String, String> {
        let src_dir = if src.is_file() {
            src.parent().map(|p| p.to_path_buf()).ok_or("无效的路径")?
        } else {
            src.to_path_buf()
        };
        let man = Manifest::load(src_dir.clone()).ok_or("所选目录没有有效的 plugin.json")?;
        let dst = self.plugin_dir(&man.id);
        if self.is_running(&man.id) {
            return Err("请先停用同名插件，再重新安装".into());
        }
        // Picking the already-installed dir itself is a no-op, not a self-copy.
        let same = src_dir.canonicalize().ok() == dst.canonicalize().ok();
        if same && dst.exists() {
            return Ok(man.id);
        }
        if dst.exists() {
            std::fs::remove_dir_all(&dst).map_err(|e| e.to_string())?;
        }
        copy_dir_all(&src_dir, &dst).map_err(|e| format!("拷贝失败: {}", e))?;
        self.sync_providers(); // installing a plugin auto-adds its service
        Ok(man.id)
    }

    /// Uninstall a plugin: stop it, delete its directory, and drop its service.
    pub fn uninstall(&self, id: &str) -> Result<(), String> {
        let _ = self.stop(id);
        let dir = self.plugin_dir(id);
        if dir.exists() {
            std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
        }
        self.sync_providers(); // removing a plugin auto-removes its service
        Ok(())
    }
}
