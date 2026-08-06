// The derived `backend:"plugin"` providers: upsert for one plugin, reconcile for all. Moved
// verbatim from plugin.rs.

use serde_json::json;

use crate::store;

use super::manager::PluginManager;
use super::manifest::Manifest;
use super::util::provider_id;

impl PluginManager {
    /// Upsert the `backend:"plugin"` provider that fronts this plugin. The provider is
    /// fully derived from the manifest each time: primary/light from modelMapping and
    /// NO custom aliases — the plugin advertises the rest via its own /v1/models, so an
    /// identity-alias list would just be noise.
    pub(super) fn ensure_provider(&self, man: &Manifest, port: u16) {
        let pid = provider_id(&man.id);
        let provider = json!({
            "id": pid,
            "name": man.name,
            "backend": "plugin",
            "pluginId": man.id,
            "baseUrl": man.base_url(port),
            "authToken": "",
            "protocol": man.protocol,
            "defaultModel": man.primary,
            "smallFastModel": man.light,
            "mapDefaultModels": true,
            "models": [],
            "icon": man.icon_data_uri(),
        });

        let mut cfg = store::read_config();
        let arr = match cfg.get_mut("providers").and_then(|v| v.as_array_mut()) {
            Some(a) => a,
            None => {
                cfg["providers"] = json!([]);
                cfg["providers"].as_array_mut().unwrap()
            }
        };
        if let Some(i) = arr
            .iter()
            .position(|x| x.get("id").and_then(|v| v.as_str()) == Some(pid.as_str()))
        {
            arr[i] = provider; // keep position, refresh contents
        } else {
            arr.push(provider);
        }
        store::write_config(cfg);
    }

    /// Reconcile the provider list with the set of installed plugins: add a provider
    /// for every installed plugin (created even while stopped, so the service is
    /// visible but — see provider_set_active — not switchable until running) and
    /// prune plugin providers whose plugin is no longer installed.
    pub fn sync_providers(&self) {
        let discovered = self.discover();
        for man in &discovered {
            let port = self.running_port(&man.id).unwrap_or_else(|| self.port_for(&man.id));
            self.ensure_provider(man, port);
        }
        let ids: std::collections::HashSet<String> = discovered.iter().map(|m| m.id.clone()).collect();
        let mut cfg = store::read_config();
        if let Some(arr) = cfg.get_mut("providers").and_then(|v| v.as_array_mut()) {
            arr.retain(|p| {
                if p.get("backend").and_then(|v| v.as_str()) == Some("plugin") {
                    p.get("pluginId")
                        .and_then(|v| v.as_str())
                        .map(|pid| ids.contains(pid))
                        .unwrap_or(false)
                } else {
                    true
                }
            });
        }
        store::write_config(cfg); // normalize fixes activeProviderId if it was pruned
    }
}
