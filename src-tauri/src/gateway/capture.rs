use axum::http::Method;
use serde_json::{json, Value};
use std::sync::Arc;

use super::monitor::UsageAcc;
use super::routing::Routing;
use super::state::GatewayState;

/// Makes a streaming request visible in the monitor even when the client aborts mid-stream.
/// The row + exchange record are normally emitted at the END of the response generator; when the
/// client disconnects, axum simply drops the generator and that code never runs — the request
/// vanished from the request stream (Codex users interrupt turns constantly). The generator owns
/// this guard: `complete()` hands back the prepared exchange (bodies filled) for the normal path,
/// and Drop-without-complete emits the row + a record.
///
/// The response capture buffers live IN the guard rather than in generator locals: a dropped
/// generator then still records whatever already streamed through. This matters beyond real
/// aborts — Responses clients (Codex) tear the connection down the moment the terminal
/// `response.completed` event arrives, before upstream EOF, which used to lose BOTH response
/// bodies on every transcoded turn. When the transcoder has already emitted its terminal event
/// (`finished`), that disconnect is the normal end of a turn and is not flagged `aborted`.
pub(super) struct StreamAbortGuard {
    armed: bool,
    st: Arc<GatewayState>,
    id: u64,
    started: std::time::Instant,
    method: Method,
    path: String,
    provider: String,
    routing: Routing,
    status: u16,
    ex: Value,
    res_cap: String,
    up_cap: Option<UpCapture>,
    pub(super) finished: bool,
    pub(super) usage: Option<UsageAcc>,
}

/// Raw upstream capture (pre-translation) for transcoded streams: status + headers are fixed at
/// guard construction, text accumulates as chunks arrive.
struct UpCapture {
    status: u16,
    headers: Value,
    text: String,
    total: usize,
}

const RES_CAP_MAX: usize = 2 * 1024 * 1024;
const UP_CAP_MAX: usize = 1024 * 1024;

impl StreamAbortGuard {
    #[allow(clippy::too_many_arguments)]
    pub(super) fn new(
        st: Arc<GatewayState>,
        id: u64,
        started: std::time::Instant,
        method: Method,
        path: String,
        provider: String,
        routing: Routing,
        status: u16,
        ex: Value,
        upstream: Option<(u16, Value)>,
    ) -> Self {
        let up_cap = upstream.map(|(status, headers)| UpCapture { status, headers, text: String::new(), total: 0 });
        Self {
            armed: true, st, id, started, method, path, provider, routing, status, ex,
            res_cap: String::new(), up_cap, finished: false, usage: None,
        }
    }

    /// Append to the client-facing response capture (the translated stream for transcoded pairs).
    pub(super) fn push_res(&mut self, s: &str) {
        if self.res_cap.len() < RES_CAP_MAX {
            self.res_cap.push_str(s);
        }
    }

    /// Append raw upstream bytes (pre-translation) when this guard tracks an upstream capture.
    pub(super) fn push_up(&mut self, raw: &str) {
        if let Some(u) = self.up_cap.as_mut() {
            u.total += raw.len();
            if u.text.len() < UP_CAP_MAX {
                u.text.push_str(raw);
            }
        }
    }

    /// Write the captured bodies into the exchange skeleton — shared by normal and abort paths.
    fn fill_bodies(&mut self) {
        self.ex["resBody"] = json!({ "text": self.res_cap, "bytes": self.res_cap.len(), "truncated": 0 });
        if let Some(u) = self.up_cap.as_ref() {
            self.ex["upstreamRes"] = json!({ "status": u.status, "headers": u.headers,
                "body": { "text": u.text, "bytes": u.total, "truncated": u.total.saturating_sub(u.text.len()) } });
        }
    }

    /// Normal completion: disarm and hand the exchange (bodies filled) back to the caller (who
    /// fills in ms / usage and records it).
    pub(super) fn complete(&mut self) -> Value {
        self.armed = false;
        self.fill_bodies();
        std::mem::take(&mut self.ex)
    }
}

impl Drop for StreamAbortGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        self.fill_bodies();
        let mut ex = std::mem::take(&mut self.ex);
        ex["ms"] = json!(self.started.elapsed().as_millis() as u64);
        // A disconnect after the transcoder's terminal event is the normal end of a Responses
        // turn — only flag genuinely interrupted streams.
        if !self.finished {
            ex["aborted"] = json!(true);
        }
        self.st.emit_request(self.id, self.started, &self.method, &self.path, &self.provider, &self.routing, self.status, self.usage.as_ref());
        let st = self.st.clone();
        // record_exchange is async and Drop is sync — spawn it, tolerating an already-torn-down
        // runtime at app quit.
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
            tauri::async_runtime::spawn(async move { st.record_exchange(ex).await });
        }));
    }
}
