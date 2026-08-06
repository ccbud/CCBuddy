// Live provider connection test, moved verbatim from lib.rs.

use serde_json::{json, Value};
use tauri::Emitter;

use crate::store;

async fn send_provider_probe(
    client: &reqwest::Client,
    url: &str,
    wire: crate::protocol::Wire,
    token: &str,
    body: &Value,
) -> Result<reqwest::Response, reqwest::Error> {
    let mut request = client
        .post(url)
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {}", token));
    if wire == crate::protocol::Wire::Anthropic {
        request = request.header("anthropic-version", "2023-06-01");
    }
    request.json(body).send().await
}

/// Live connection test: POST a tiny ping to the provider, shaped for its declared wire protocol
/// (Anthropic /messages, OpenAI /chat/completions, or /responses), and report ok/error/timeout.
/// The renderer localizes the result message.
#[tauri::command]
pub(crate) async fn provider_test(app: tauri::AppHandle, p: Value) -> Value {
    let base = p.get("baseUrl").and_then(|v| v.as_str()).unwrap_or("").trim();
    if base.is_empty() {
        return json!({ "ok": false, "reason": "baseUrlEmpty" });
    }
    if !(base.starts_with("http://") || base.starts_with("https://")) {
        return json!({ "ok": false, "reason": "baseUrlInvalid" });
    }
    // Test against the provider's DECLARED protocol endpoint — an openai-chat provider must be
    // pinged at /chat/completions with a Chat body, not the Anthropic /v1/messages default.
    let wire = crate::protocol::Wire::from_provider(p.get("protocol").and_then(|v| v.as_str()));
    let url = wire.upstream_url(base);
    let model = p
        .get("defaultModel")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .or_else(|| {
            p.get("models")
                .and_then(|m| m.as_array())
                .and_then(|a| a.first())
                .and_then(|m| m.get("upstream"))
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
        })
        .unwrap_or("claude-3-5-haiku-20241022")
        .to_string();
    let token = p.get("authToken").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let insecure = store::read_config()
        .get("insecureSkipVerify")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    // Protocol-shaped ping body.
    let body = match wire {
        crate::protocol::Wire::OpenAiResponses => json!({ "model": model, "max_output_tokens": 16, "input": "ping" }),
        crate::protocol::Wire::OpenAiChat => json!({ "model": model, "max_tokens": 16, "messages": [{ "role": "user", "content": "ping" }] }),
        crate::protocol::Wire::Anthropic => json!({ "model": model, "max_tokens": 16, "messages": [{ "role": "user", "content": "ping" }] }),
    };
    let client = match reqwest::Client::builder()
        .danger_accept_invalid_certs(insecure)
        .timeout(std::time::Duration::from_secs(30))
        .build()
    {
        Ok(c) => c,
        Err(e) => return json!({ "ok": false, "message": e.to_string() }),
    };
    // Auth via Authorization: Bearer only. Sending both authorization and x-api-key trips
    // providers that reject having the two auth headers present at once.
    let first = send_provider_probe(&client, &url, wire, &token, &body).await;
    match first {
        Ok(mut r) => {
            let mut migrated_base_url: Option<String> = None;
            if crate::protocol::should_try_v1_fallback(r.status().as_u16()) {
                if let Some(fallback_url) = wire.v1_fallback_url(base) {
                    if let Ok(candidate) = send_provider_probe(&client, &fallback_url, wire, &token, &body).await {
                        if candidate.status().is_success() {
                            r = candidate;
                            migrated_base_url = Some(format!("{}/v1", base.trim_end_matches('/')));
                        }
                    }
                }
            }
            let status = r.status().as_u16();
            let text = r.text().await.unwrap_or_default();
            let parsed: Option<Value> = serde_json::from_str(&text).ok();
            let http_ok = (200..300).contains(&status);
            // A well-shaped reply for the tested protocol: Anthropic `type:message`, Chat `choices`,
            // Responses `output`/`id`.
            let shape_ok = parsed.as_ref().map(|j| match wire {
                crate::protocol::Wire::Anthropic => j.get("type").and_then(|v| v.as_str()) == Some("message"),
                crate::protocol::Wire::OpenAiChat => j.get("choices").map(|c| c.is_array()).unwrap_or(false),
                crate::protocol::Wire::OpenAiResponses => j.get("output").is_some() || j.get("id").is_some(),
            }).unwrap_or(false);
            if http_ok && shape_ok {
                let m = parsed
                    .as_ref()
                    .and_then(|j| j.get("model"))
                    .and_then(|v| v.as_str())
                    .unwrap_or(&model);
                if let Some(next_base) = migrated_base_url.as_deref() {
                    if let Some(id) = p.get("id").and_then(Value::as_str) {
                        if let Some(saved) = store::migrate_provider_base_url_to_v1(id, base) {
                            let _ = app.emit("config:changed", saved);
                            return json!({ "ok": true, "status": status, "model": m, "baseUrl": next_base });
                        }
                    } else {
                        return json!({ "ok": true, "status": status, "model": m, "baseUrl": next_base });
                    }
                }
                return json!({ "ok": true, "status": status, "model": m });
            }
            let msg = parsed
                .as_ref()
                .and_then(|j| j.get("error"))
                .and_then(|e| e.get("message"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| {
                    if !text.is_empty() {
                        text.chars().take(200).collect()
                    } else {
                        format!("HTTP {}", status)
                    }
                });
            json!({ "ok": false, "status": status, "message": msg })
        }
        Err(e) => {
            if e.is_timeout() {
                json!({ "ok": false, "reason": "timeout" })
            } else {
                json!({ "ok": false, "message": e.to_string() })
            }
        }
    }
}
