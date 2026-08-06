// Manifest accessors the manager reads through: declared actions, the resolved executable and
// its argv, the plugin's base URL and its icon. Moved verbatim from plugin.rs.

use serde_json::Value;
use std::path::PathBuf;

use super::manifest::Manifest;
use super::util::{base64_encode, platform_key};

impl Manifest {
    /// Find a declared action by id.
    pub(super) fn action(&self, action_id: &str) -> Option<&Value> {
        self.actions
            .iter()
            .find(|a| a.get("id").and_then(|x| x.as_str()) == Some(action_id))
    }

    /// Resolve (submitPath, loadPath) for an action, applying defaults.
    /// submitPath defaults to `/v1/plugin/action/<id>`; loadPath defaults to submitPath.
    pub(super) fn action_paths(&self, action_id: &str) -> Option<(String, String)> {
        let a = self.action(action_id)?;
        let default_submit = format!("/v1/plugin/action/{}", action_id);
        let submit = a
            .get("submitPath")
            .or_else(|| a.get("path"))
            .and_then(|x| x.as_str())
            .unwrap_or(default_submit.as_str())
            .to_string();
        let load = a
            .get("loadPath")
            .and_then(|x| x.as_str())
            .unwrap_or(submit.as_str())
            .to_string();
        Some((submit, load))
    }

    /// Actions as sent to the renderer: host-internal wiring (submitPath/loadPath/
    /// path) stripped, display fields (label/kind/url/fields/…) kept.
    pub(super) fn public_actions(&self) -> Vec<Value> {
        self.actions
            .iter()
            .map(|a| {
                let mut o = a.clone();
                if let Some(m) = o.as_object_mut() {
                    m.remove("submitPath");
                    m.remove("loadPath");
                    m.remove("path");
                }
                o
            })
            .collect()
    }

    /// Absolute path to the executable for the current platform, if declared.
    pub(super) fn exec_path(&self) -> Option<PathBuf> {
        let rel = self.exec.get(platform_key()).and_then(|x| x.as_str())?;
        Some(self.dir.join(rel))
    }

    pub(super) fn resolved_args(&self, port: u16, home: &str) -> Vec<String> {
        self.args
            .iter()
            .map(|a| a.replace("{port}", &port.to_string()).replace("{home}", home))
            .collect()
    }

    pub(super) fn base_url(&self, port: u16) -> String {
        format!("http://127.0.0.1:{}{}", port, self.base_path)
    }

    /// The plugin's icon as a data URI (data:image/...;base64,...), if declared
    /// and readable — lets a plugin ship its own logo for the UI.
    pub(super) fn icon_data_uri(&self) -> Option<String> {
        let rel = self.icon.trim();
        if rel.is_empty() {
            return None;
        }
        let path = self.dir.join(rel);
        let bytes = std::fs::read(&path).ok()?;
        if bytes.is_empty() || bytes.len() > 512 * 1024 {
            return None;
        }
        let ext = path.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase());
        let mime = match ext.as_deref() {
            Some("svg") => "image/svg+xml",
            Some("png") => "image/png",
            Some("jpg") | Some("jpeg") => "image/jpeg",
            Some("webp") => "image/webp",
            Some("gif") => "image/gif",
            _ => return None,
        };
        Some(format!("data:{};base64,{}", mime, base64_encode(&bytes)))
    }
}
