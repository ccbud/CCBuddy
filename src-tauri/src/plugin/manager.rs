// The manager type itself: running processes, plugin discovery and port assignment. Moved
// verbatim from plugin.rs.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Child;
use std::sync::{Arc, Mutex};

use super::manifest::Manifest;
use super::util::{free_port, plugins_root, port_is_free};

pub(super) struct RunningPlugin {
    pub(super) child: Child,
    pub(super) port: u16,
}

/// Owns running plugin processes and their derived providers.
pub struct PluginManager {
    pub(super) running: Mutex<HashMap<String, RunningPlugin>>,
    pub(super) client: reqwest::Client,
}

impl PluginManager {
    pub fn new() -> Arc<PluginManager> {
        Arc::new(PluginManager {
            running: Mutex::new(HashMap::new()),
            client: reqwest::Client::new(),
        })
    }

    pub(super) fn plugins_dir(&self) -> PathBuf {
        plugins_root()
    }

    pub(super) fn plugin_dir(&self, id: &str) -> PathBuf {
        self.plugins_dir().join(id)
    }

    pub(super) fn manifest(&self, id: &str) -> Option<Manifest> {
        Manifest::load(self.plugin_dir(id))
    }

    pub(super) fn discover(&self) -> Vec<Manifest> {
        let mut out = vec![];
        if let Ok(rd) = std::fs::read_dir(self.plugins_dir()) {
            for e in rd.flatten() {
                if e.path().is_dir() {
                    if let Some(m) = Manifest::load(e.path()) {
                        out.push(m);
                    }
                }
            }
        }
        out
    }

    pub(super) fn running_port(&self, id: &str) -> Option<u16> {
        self.running.lock().unwrap().get(id).map(|rp| rp.port)
    }

    /// True if the plugin process is alive; reaps and forgets an exited one.
    pub fn is_running(&self, id: &str) -> bool {
        let mut g = self.running.lock().unwrap();
        if let Some(rp) = g.get_mut(id) {
            match rp.child.try_wait() {
                Ok(Some(_)) => {
                    g.remove(id);
                    false
                }
                _ => true,
            }
        } else {
            false
        }
    }

    /// Port for a plugin: the live one if running, else a remembered one from
    /// runtime.json, else a freshly assigned free port (persisted).
    pub(super) fn port_for(&self, id: &str) -> u16 {
        if let Some(p) = self.running_port(id) {
            return p;
        }
        let rt = self.plugin_dir(id).join("runtime.json");
        if let Ok(raw) = std::fs::read(&rt) {
            if let Ok(v) = serde_json::from_slice::<Value>(&raw) {
                if let Some(p) = v.get("port").and_then(|x| x.as_u64()) {
                    if p > 0 {
                        return p as u16;
                    }
                }
            }
        }
        let p = free_port().unwrap_or(8899);
        let _ = std::fs::create_dir_all(self.plugin_dir(id));
        let _ = std::fs::write(&rt, serde_json::to_vec(&json!({ "port": p })).unwrap_or_default());
        p
    }

    /// A port we can actually bind for this plugin: the remembered one if it's free,
    /// else a freshly assigned free port (persisted to runtime.json). Avoids colliding
    /// with a stale sidecar squatting on the old port.
    pub(super) fn bindable_port(&self, id: &str) -> u16 {
        let port = self.port_for(id);
        if port_is_free(port) {
            return port;
        }
        let fresh = free_port().unwrap_or(port);
        let _ = std::fs::create_dir_all(self.plugin_dir(id));
        let rt = self.plugin_dir(id).join("runtime.json");
        let _ = std::fs::write(&rt, serde_json::to_vec(&json!({ "port": fresh })).unwrap_or_default());
        fresh
    }
}
