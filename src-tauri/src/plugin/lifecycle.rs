// Plugin process lifecycle: spawn + health gate (start), kill + deregister (stop). Moved
// verbatim from plugin.rs.

use serde_json::Value;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::store;

use super::manager::{PluginManager, RunningPlugin};
use super::util::{platform_key, provider_id};

impl PluginManager {
    /// Enable a plugin: spawn it, health-gate, then upsert its provider.
    pub async fn start(&self, id: &str) -> Result<(), String> {
        let man = self.manifest(id).ok_or_else(|| format!("plugin '{}' not found", id))?;

        if self.is_running(id) {
            self.ensure_provider(&man, self.running_port(id).unwrap_or_else(|| self.port_for(id)));
            return Ok(());
        }

        let exec = man
            .exec_path()
            .ok_or_else(|| format!("no binary for this platform ({})", platform_key()))?;
        if !exec.exists() {
            return Err(format!("plugin binary missing: {}", exec.display()));
        }

        // Use the remembered port, but if it's already taken (e.g. a stale sidecar from a
        // previous run still holding it), grab a fresh free port instead — otherwise our
        // child can't bind and we'd falsely health-gate against the squatter.
        let port = self.bindable_port(id);
        let dir = self.plugin_dir(id);
        let _ = std::fs::create_dir_all(&dir);
        let home = dir.to_string_lossy().to_string();
        let args = man.resolved_args(port, &home);

        // stderr → plugin.log for diagnosis; stdout is the plugin's ready channel
        // (we already know the port, so we discard it).
        let stderr = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join("plugin.log"))
            .map(Stdio::from)
            .unwrap_or_else(|_| Stdio::null());

        let child = Command::new(&exec)
            .args(&args)
            .current_dir(&man.dir)
            .stdout(Stdio::null())
            .stderr(stderr)
            .spawn()
            .map_err(|e| format!("spawn {}: {}", exec.display(), e))?;

        self.running.lock().unwrap().insert(id.to_string(), RunningPlugin { child, port });

        if !self.wait_ready(port, &man.health_path, man.ready_timeout_ms).await {
            let _ = self.stop(id);
            return Err("plugin did not become ready (see plugin.log)".into());
        }
        // Guard against a false positive: if our child died during startup (e.g. it still
        // failed to bind) even though something answered /healthz, don't register a dead
        // provider — surface the failure so the UI doesn't flash "enabled" then revert.
        if !self.is_running(id) {
            return Err("plugin exited during startup (see plugin.log)".into());
        }

        self.ensure_provider(&man, port);
        Ok(())
    }

    /// Disable a plugin: kill the process and remove its provider.
    pub fn stop(&self, id: &str) -> Result<(), String> {
        if let Some(mut rp) = self.running.lock().unwrap().remove(id) {
            let _ = rp.child.kill();
            let _ = rp.child.wait();
        }
        // Keep the provider (the service mirrors install state, not running state),
        // but if this stopped plugin was the active provider, switch away — it can no
        // longer serve requests. Pick the first other provider, else clear.
        let pid = provider_id(id);
        let mut cfg = store::read_config();
        if cfg.get("activeProviderId").and_then(|v| v.as_str()) == Some(pid.as_str()) {
            let next = cfg
                .get("providers")
                .and_then(|v| v.as_array())
                .and_then(|arr| {
                    arr.iter()
                        .find(|p| p.get("id").and_then(|v| v.as_str()) != Some(pid.as_str()))
                        .and_then(|p| p.get("id").and_then(|v| v.as_str()))
                        .map(|s| s.to_string())
                });
            cfg["activeProviderId"] = next.map(Value::String).unwrap_or(Value::Null);
            store::write_config(cfg);
        }
        Ok(())
    }

    pub(super) async fn wait_ready(&self, port: u16, health_path: &str, timeout_ms: u64) -> bool {
        let url = format!("http://127.0.0.1:{}{}", port, health_path);
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        // Ramp the poll interval: a local sidecar usually starts in well under a
        // second, so probe aggressively at first (catch "ready" the instant it
        // happens) and back off toward 150ms to keep the tail cheap. Connection-
        // refused before the server binds returns immediately, so early probes
        // don't stall.
        let mut delay = Duration::from_millis(20);
        loop {
            if let Ok(r) = self.client.get(&url).timeout(Duration::from_millis(1500)).send().await {
                if r.status().is_success() {
                    return true;
                }
            }
            if Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(delay).await;
            delay = (delay * 2).min(Duration::from_millis(150));
        }
    }
}
