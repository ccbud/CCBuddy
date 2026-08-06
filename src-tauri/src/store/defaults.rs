// The shipped default config. Moved verbatim from store.rs.

use serde_json::{json, Value};

pub fn default_config() -> Value {
    json!({
        "port": 8788,
        "activeProviderId": null,
        "requireToken": false,
        "gatewayToken": "",
        "gatewayEnabled": true,
        "openAtLogin": false,
        "claudeBackup": null,
        "trayUsage": { "enabled": false, "range": "7d" },
        "language": null,
        "historyDirs": ["~/.claude"],
        "historyActive": "all",
        "connectTargets": [],
        "retry429": { "enabled": true, "max": 3, "baseMs": 500 },
        "insecureSkipVerify": false,
        "autoUpdate": { "check": true, "autoDownload": true },
        "providers": []
    })
}
