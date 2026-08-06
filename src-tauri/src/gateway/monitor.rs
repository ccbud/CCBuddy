use axum::http::Method;
use serde_json::{json, Value};
use std::sync::atomic::Ordering;
use tauri::Emitter;

use super::routing::Routing;
use super::state::GatewayState;

impl GatewayState {
    pub(super) fn next_id(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed) + 1
    }
    /// Bounded live-debugging capture: keep only the most recent exchanges (matches the monitor
    /// stream's 100-row window so every visible row can open its detail).
    pub async fn record_exchange(&self, ex: Value) {
        let mut buf = self.exchanges.lock().await;
        buf.push_back(ex);
        while buf.len() > 100 {
            buf.pop_front();
        }
    }
    pub async fn monitor_get(&self, id: i64) -> Value {
        let buf = self.exchanges.lock().await;
        buf.iter()
            .rev()
            .find(|e| e.get("id").and_then(|v| v.as_i64()) == Some(id))
            .cloned()
            .unwrap_or(Value::Null)
    }
    pub async fn monitor_clear(&self) {
        self.exchanges.lock().await.clear();
    }
    pub async fn monitor_recent(&self) -> Value {
        self.exchanges.lock().await.back().cloned().unwrap_or(Value::Null)
    }

    pub(super) fn emit_request(&self, id: u64, started: std::time::Instant, method: &Method, path: &str, provider: &str, routing: &Routing, status: u16, usage: Option<&UsageAcc>) {
        let (it, ot, cr, cc) = usage
            .map(|u| (u.input, u.output, u.cache_read, u.cache_creation))
            .unwrap_or((0, 0, 0, 0));
        let _ = self.app.emit(
            "gateway:request",
            json!({
                "id": id,
                "method": method.as_str(),
                "path": path,
                "provider": provider,
                "requestedModel": routing.client_facing_model,
                "outgoingModel": routing.outgoing_model,
                "clientFacingModel": routing.client_facing_model,
                "status": status,
                "ms": started.elapsed().as_millis() as u64,
                "inputTokens": it, "outputTokens": ot, "cacheRead": cr, "cacheCreation": cc,
            }),
        );
    }
}

#[derive(Default, Clone)]
pub(super) struct UsageAcc {
    pub(super) input: i64,
    pub(super) output: i64,
    pub(super) cache_read: i64,
    pub(super) cache_creation: i64,
    pub(super) saw: bool,
}
