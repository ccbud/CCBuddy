// The parsed plugin.json manifest and its loader. Moved verbatim from plugin.rs.

use serde_json::Value;
use std::path::PathBuf;

/// A plugin's parsed manifest (plugin.json). Only the fields the host needs.
pub struct Manifest {
    pub dir: PathBuf,
    pub id: String,
    pub name: String,
    pub version: String,
    pub description: String,
    /// Optional icon file relative to the plugin dir, e.g. "icon.svg".
    pub icon: String,
    /// endpoint.protocol → provider wire protocol.
    pub protocol: String,
    /// endpoint.basePath, e.g. "/v1".
    pub base_path: String,
    /// endpoint.healthPath, e.g. "/healthz".
    pub health_path: String,
    /// endpoint.readyTimeoutMs.
    pub ready_timeout_ms: u64,
    /// runtime.exec: { "<os>-<arch>": "bin/..." }.
    pub(super) exec: Value,
    /// runtime.args, with {port}/{home} placeholders.
    pub(super) args: Vec<String>,
    /// (alias, upstream) model pairs.
    pub models: Vec<(String, String)>,
    pub primary: String,
    pub light: String,
    /// Control-plane auth status path (read-only; the plugin reuses a CLI login).
    pub auth_status_path: String,
    /// source.git — upstream git repo used for install/update (optional).
    pub source_git: String,
    pub source_branch: String,
    /// source.build — shell command run in the clone to produce the binary.
    pub source_build: String,
    /// ui.actions — plugin-declared buttons/forms. Raw objects: the renderer draws
    /// them (label/kind/fields/url), the host reads submitPath/loadPath to forward
    /// a click to the plugin's control plane. See docs/plugin-system.md.
    pub actions: Vec<Value>,
}
impl Manifest {
    pub(super) fn load(dir: PathBuf) -> Option<Manifest> {
        let raw = std::fs::read(dir.join("plugin.json")).ok()?;
        let v: Value = serde_json::from_slice(&raw).ok()?;
        let id = v.get("id")?.as_str()?.to_string();

        let s = |path: &[&str], default: &str| -> String {
            let mut cur = &v;
            for k in path {
                match cur.get(*k) {
                    Some(next) => cur = next,
                    None => return default.to_string(),
                }
            }
            cur.as_str().unwrap_or(default).to_string()
        };

        let args = v
            .get("runtime")
            .and_then(|r| r.get("args"))
            .and_then(|a| a.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_else(|| vec!["serve".into(), "--port".into(), "{port}".into(), "--home".into(), "{home}".into()]);

        let mut models = vec![];
        if let Some(arr) = v.get("models").and_then(|m| m.as_array()) {
            for m in arr {
                let alias = m.get("alias").and_then(|x| x.as_str()).unwrap_or("").to_string();
                let upstream = m
                    .get("upstream")
                    .and_then(|x| x.as_str())
                    .unwrap_or(alias.as_str())
                    .to_string();
                if !alias.is_empty() {
                    models.push((alias, upstream));
                }
            }
        }

        let ready_timeout_ms = v
            .get("endpoint")
            .and_then(|e| e.get("readyTimeoutMs"))
            .and_then(|x| x.as_u64())
            .unwrap_or(8000);

        // ui.actions: keep only well-formed objects that carry an id.
        let actions = v
            .get("ui")
            .and_then(|u| u.get("actions"))
            .and_then(|a| a.as_array())
            .map(|a| {
                a.iter()
                    .filter(|x| x.get("id").and_then(|i| i.as_str()).map(|s| !s.is_empty()).unwrap_or(false))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();

        Some(Manifest {
            dir,
            id,
            name: s(&["name"], "Plugin"),
            version: s(&["version"], "0.0.0"),
            description: s(&["description"], ""),
            icon: s(&["icon"], ""),
            protocol: s(&["endpoint", "protocol"], "openai-responses"),
            base_path: s(&["endpoint", "basePath"], "/v1"),
            health_path: s(&["endpoint", "healthPath"], "/healthz"),
            ready_timeout_ms,
            exec: v.get("runtime").and_then(|r| r.get("exec")).cloned().unwrap_or(Value::Null),
            args,
            models,
            primary: s(&["modelMapping", "primary"], ""),
            light: s(&["modelMapping", "light"], ""),
            auth_status_path: s(&["auth", "statusPath"], "/v1/plugin/auth"),
            source_git: s(&["source", "git"], ""),
            source_branch: {
                let b = s(&["source", "branch"], "");
                if b.trim().is_empty() { "main".to_string() } else { b }
            },
            source_build: s(&["source", "build"], ""),
            actions,
        })
    }
}
