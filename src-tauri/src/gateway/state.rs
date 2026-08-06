use axum::Router;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tauri::Emitter;
use tokio::sync::{oneshot, Mutex};

use super::handler::handle;
use super::signatures::ThoughtSignatureCache;

// ---------------- gateway runtime ----------------

pub struct GatewayState {
    pub(super) app: tauri::AppHandle,
    pub(super) known: Mutex<HashMap<String, HashSet<String>>>,
    pub(super) thought_signatures: Mutex<ThoughtSignatureCache>,
    pub(super) codex_history: crate::protocol::codex_history::CodexHistoryStore,
    pub(super) seq: AtomicU64,
    running: Mutex<Option<RunningServer>>,
    // Sync mirror of the bound port (0 = stopped) for callers that can't await (tray refresh).
    running_port: std::sync::atomic::AtomicU32,
    pub(super) exchanges: Mutex<VecDeque<Value>>,
    pub(super) client: reqwest::Client,
    pub(super) client_insecure: reqwest::Client,
    // Ring buffer of recent gateway log lines (seq+ts stamped) so the settings Logs panel can
    // backfill on open — mirrors main.js gatewayLogs (cap 80). std Mutex: log() is sync.
    logs: std::sync::Mutex<VecDeque<Value>>,
    log_seq: AtomicU64,
}
struct RunningServer {
    port: u16,
    shutdown: oneshot::Sender<()>,
}

impl GatewayState {
    pub fn new(app: tauri::AppHandle) -> Arc<Self> {
        let client = reqwest::Client::builder()
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        let client_insecure = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Arc::new(Self {
            app,
            known: Mutex::new(HashMap::new()),
            thought_signatures: Mutex::new(ThoughtSignatureCache::default()),
            codex_history: crate::protocol::codex_history::CodexHistoryStore::default(),
            seq: AtomicU64::new(0),
            running: Mutex::new(None),
            running_port: std::sync::atomic::AtomicU32::new(0),
            exchanges: Mutex::new(VecDeque::new()),
            client,
            client_insecure,
            logs: std::sync::Mutex::new(VecDeque::new()),
            log_seq: AtomicU64::new(0),
        })
    }

    pub fn log(&self, level: &str, msg: impl AsRef<str>) {
        let seq = self.log_seq.fetch_add(1, Ordering::Relaxed) + 1;
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let entry = json!({ "seq": seq, "ts": ts, "level": level, "msg": msg.as_ref() });
        if let Ok(mut buf) = self.logs.lock() {
            buf.push_back(entry.clone());
            while buf.len() > 80 {
                buf.pop_front();
            }
        }
        let _ = self.app.emit("gateway:log", entry);
    }

    /// Snapshot of the recent-log ring, oldest→newest (logs_get backfill).
    pub fn logs_snapshot(&self) -> Value {
        self.logs
            .lock()
            .map(|b| Value::Array(b.iter().cloned().collect()))
            .unwrap_or_else(|_| json!([]))
    }
    pub fn logs_clear(&self) {
        if let Ok(mut b) = self.logs.lock() {
            b.clear();
        }
    }

    pub async fn status(&self) -> Value {
        match self.running.lock().await.as_ref() {
            Some(rs) => json!({ "running": true, "port": rs.port }),
            None => json!({ "running": false, "port": Value::Null }),
        }
    }

    pub async fn current_port(&self) -> Option<u16> {
        self.running.lock().await.as_ref().map(|r| r.port)
    }

    /// Sync view of the running state (tray menu refresh runs on the main thread, no await).
    pub fn port_sync(&self) -> Option<u16> {
        match self.running_port.load(Ordering::Relaxed) {
            0 => None,
            p => Some(p as u16),
        }
    }

    pub fn emit(&self, event: &str, payload: Value) {
        let _ = self.app.emit(event, payload);
    }

    pub async fn start(self: &Arc<Self>, port: u16) -> Result<u16, String> {
        if let Some(rs) = self.running.lock().await.as_ref() {
            return Ok(rs.port);
        }
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
            .await
            .map_err(|e| e.to_string())?;
        let actual = listener.local_addr().map_err(|e| e.to_string())?.port();
        let (tx, rx) = oneshot::channel::<()>();
        let router = Router::new().fallback(handle).with_state(self.clone());
        tauri::async_runtime::spawn(async move {
            let _ = axum::serve(listener, router)
                .with_graceful_shutdown(async move {
                    let _ = rx.await;
                })
                .await;
        });
        *self.running.lock().await = Some(RunningServer { port: actual, shutdown: tx });
        self.running_port.store(actual as u32, Ordering::Relaxed);
        self.log("info", format!("gateway listening on http://127.0.0.1:{}", actual));
        let status = self.status().await;
        let _ = self.app.emit("gateway:status", status);
        Ok(actual)
    }

    pub async fn stop(self: &Arc<Self>) {
        self.running_port.store(0, Ordering::Relaxed);
        let taken = self.running.lock().await.take();
        if let Some(rs) = taken {
            let _ = rs.shutdown.send(());
            self.log("info", "gateway stopped");
        }
        let status = self.status().await;
        let _ = self.app.emit("gateway:status", status);
    }
}
