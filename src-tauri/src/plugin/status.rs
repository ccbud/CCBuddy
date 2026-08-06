// UI-facing snapshots (status / list) and the declarative action calls. Moved verbatim from
// plugin.rs.

use serde_json::{json, Value};
use std::time::Duration;

use super::manager::PluginManager;
use super::util::{is_official_source, provider_id};

impl PluginManager {
    /// Full snapshot for the UI: install info + running + auth (queried live).
    pub async fn status(&self, id: &str) -> Value {
        let man = self.manifest(id);
        let running = self.is_running(id);
        let mut auth = Value::Null;
        if running {
            if let (Some(m), Some(port)) = (man.as_ref(), self.running_port(id)) {
                let url = format!("http://127.0.0.1:{}{}", port, m.auth_status_path);
                if let Ok(r) = self.client.get(&url).timeout(Duration::from_secs(3)).send().await {
                    if let Ok(v) = r.json::<Value>().await {
                        auth = v;
                    }
                }
            }
        }
        json!({
            "id": id,
            "name": man.as_ref().map(|m| m.name.clone()).unwrap_or_default(),
            "version": man.as_ref().map(|m| m.version.clone()).unwrap_or_default(),
            "description": man.as_ref().map(|m| m.description.clone()).unwrap_or_default(),
            "protocol": man.as_ref().map(|m| m.protocol.clone()).unwrap_or_default(),
            "icon": man.as_ref().and_then(|m| m.icon_data_uri()),
            "hasSource": man.as_ref().map(|m| !m.source_git.trim().is_empty()).unwrap_or(false),
            "official": man.as_ref().map(|m| is_official_source(&m.source_git)).unwrap_or(false),
            "providerId": provider_id(id),
            "running": running,
            "auth": auth,
            "actions": man.as_ref().map(|m| m.public_actions()).unwrap_or_default(),
        })
    }

    /// List all discovered plugins with their status.
    pub async fn list(&self) -> Value {
        let mut out = vec![];
        for m in self.discover() {
            out.push(self.status(&m.id).await);
        }
        json!(out)
    }

    /// Run a declarative UI action: POST the form `values` to the action's control
    /// plane endpoint and return the plugin's JSON response ({ ok, message }). A
    /// non-2xx status surfaces the plugin's `message` as an error to the UI.
    pub async fn action(&self, id: &str, action_id: &str, values: Value) -> Result<Value, String> {
        let man = self.manifest(id).ok_or("plugin not found")?;
        let (submit, _) = man.action_paths(action_id).ok_or("action not found")?;
        let port = self.running_port(id).ok_or("plugin not running")?;
        let url = format!("http://127.0.0.1:{}{}", port, submit);
        let r = self
            .client
            .post(&url)
            .json(&values)
            .timeout(Duration::from_secs(30))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        let ok = r.status().is_success();
        let body = r.json::<Value>().await.unwrap_or_else(|_| json!({}));
        if !ok {
            let msg = body
                .get("message")
                .and_then(|x| x.as_str())
                .unwrap_or("plugin returned an error");
            return Err(msg.to_string());
        }
        Ok(body)
    }

    /// Fetch current values to prefill a declarative form (GET the action's
    /// loadPath). Returns the plugin's JSON, typically `{ values: { ... } }`.
    pub async fn action_load(&self, id: &str, action_id: &str) -> Result<Value, String> {
        let man = self.manifest(id).ok_or("plugin not found")?;
        let (_, load) = man.action_paths(action_id).ok_or("action not found")?;
        let port = self.running_port(id).ok_or("plugin not running")?;
        let url = format!("http://127.0.0.1:{}{}", port, load);
        let r = self
            .client
            .get(&url)
            .timeout(Duration::from_secs(10))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        r.json::<Value>().await.map_err(|e| e.to_string())
    }
}
