use axum::http::HeaderMap;
use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::RwLock;

const MAX_CAPTURE_BYTES: usize = 1_048_576;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MonitorRecord {
    pub id: u64,
    pub started_at: DateTime<Utc>,
    pub elapsed_ms: Option<u64>,
    pub method: String,
    pub path: String,
    pub status: Option<u16>,
    pub client_model: Option<String>,
    pub provider_id: Option<String>,
    pub provider_name: Option<String>,
    pub attempts: u32,
    pub translation: Option<String>,
    pub error: Option<String>,
    pub client_request: CapturedMessage,
    pub upstream_request: Option<CapturedMessage>,
    pub upstream_response: Option<CapturedMessage>,
    pub client_response: Option<CapturedMessage>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CapturedMessage {
    pub headers: Value,
    pub body: String,
    pub truncated: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MonitorSummary {
    pub id: u64,
    pub started_at: DateTime<Utc>,
    pub elapsed_ms: Option<u64>,
    pub method: String,
    pub path: String,
    pub status: Option<u16>,
    pub client_model: Option<String>,
    pub provider_id: Option<String>,
    pub provider_name: Option<String>,
    pub attempts: u32,
    pub translation: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AttemptCapture {
    pub provider_id: String,
    pub provider_name: String,
    pub attempts: u32,
    pub translation: Option<String>,
    pub request_headers: HeaderMap,
    pub request_body: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct CompletionCapture {
    pub status: u16,
    pub elapsed_ms: u64,
    pub upstream_headers: HeaderMap,
    pub upstream_body: Vec<u8>,
    pub client_headers: HeaderMap,
    pub client_body: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct StreamFailureCapture {
    pub elapsed_ms: u64,
    pub error: String,
    pub upstream_headers: HeaderMap,
    pub upstream_body: Vec<u8>,
    pub client_headers: HeaderMap,
    pub client_body: Vec<u8>,
}

pub struct MonitorStore {
    capacity: usize,
    next_id: AtomicU64,
    records: RwLock<VecDeque<MonitorRecord>>,
}

impl MonitorStore {
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity,
            next_id: AtomicU64::new(1),
            records: RwLock::new(VecDeque::with_capacity(capacity.min(1024))),
        }
    }

    pub async fn begin(
        &self,
        method: &str,
        path: &str,
        model: Option<String>,
        headers: &HeaderMap,
        body: &[u8],
    ) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let record = MonitorRecord {
            id,
            started_at: Utc::now(),
            elapsed_ms: None,
            method: method.to_string(),
            path: path.to_string(),
            status: None,
            client_model: model,
            provider_id: None,
            provider_name: None,
            attempts: 0,
            translation: None,
            error: None,
            client_request: capture(headers, body),
            upstream_request: None,
            upstream_response: None,
            client_response: None,
        };
        let mut records = self.records.write().await;
        records.push_front(record);
        while records.len() > self.capacity {
            records.pop_back();
        }
        id
    }

    pub async fn attempt(&self, id: u64, attempt: AttemptCapture) {
        let mut records = self.records.write().await;
        if let Some(record) = records.iter_mut().find(|record| record.id == id) {
            record.provider_id = Some(attempt.provider_id);
            record.provider_name = Some(attempt.provider_name);
            record.attempts = attempt.attempts;
            record.translation = attempt.translation;
            record.upstream_request =
                Some(capture(&attempt.request_headers, &attempt.request_body));
        }
    }

    pub async fn complete(&self, id: u64, completion: CompletionCapture) {
        let mut records = self.records.write().await;
        if let Some(record) = records.iter_mut().find(|record| record.id == id) {
            record.status = Some(completion.status);
            record.elapsed_ms = Some(completion.elapsed_ms);
            record.upstream_response = Some(capture(
                &completion.upstream_headers,
                &completion.upstream_body,
            ));
            record.client_response =
                Some(capture(&completion.client_headers, &completion.client_body));
        }
    }

    pub async fn complete_local(
        &self,
        id: u64,
        status: u16,
        elapsed_ms: u64,
        client_headers: &HeaderMap,
        client_body: &[u8],
    ) {
        let mut records = self.records.write().await;
        if let Some(record) = records.iter_mut().find(|record| record.id == id) {
            record.status = Some(status);
            record.elapsed_ms = Some(elapsed_ms);
            record.client_response = Some(capture(client_headers, client_body));
        }
    }

    pub async fn fail(&self, id: u64, elapsed_ms: u64, error: impl Into<String>) {
        let mut records = self.records.write().await;
        if let Some(record) = records.iter_mut().find(|record| record.id == id) {
            record.elapsed_ms = Some(elapsed_ms);
            record.error = Some(redact_text(&error.into()));
        }
    }

    pub async fn fail_stream(&self, id: u64, failure: StreamFailureCapture) {
        let mut records = self.records.write().await;
        if let Some(record) = records.iter_mut().find(|record| record.id == id) {
            record.elapsed_ms = Some(failure.elapsed_ms);
            record.error = Some(redact_text(&failure.error));
            record.upstream_response =
                Some(capture(&failure.upstream_headers, &failure.upstream_body));
            record.client_response = Some(capture(&failure.client_headers, &failure.client_body));
        }
    }

    pub async fn list(&self, limit: usize, before: Option<u64>) -> Vec<MonitorSummary> {
        self.records
            .read()
            .await
            .iter()
            .filter(|record| before.is_none_or(|before| record.id < before))
            .take(limit.min(500))
            .map(MonitorSummary::from)
            .collect()
    }

    pub async fn detail(&self, id: u64) -> Option<MonitorRecord> {
        self.records
            .read()
            .await
            .iter()
            .find(|record| record.id == id)
            .cloned()
    }

    pub async fn clear(&self) -> usize {
        let mut records = self.records.write().await;
        let count = records.len();
        records.clear();
        count
    }
}

impl From<&MonitorRecord> for MonitorSummary {
    fn from(record: &MonitorRecord) -> Self {
        Self {
            id: record.id,
            started_at: record.started_at,
            elapsed_ms: record.elapsed_ms,
            method: record.method.clone(),
            path: record.path.clone(),
            status: record.status,
            client_model: record.client_model.clone(),
            provider_id: record.provider_id.clone(),
            provider_name: record.provider_name.clone(),
            attempts: record.attempts,
            translation: record.translation.clone(),
            error: record.error.clone(),
        }
    }
}

fn capture(headers: &HeaderMap, body: &[u8]) -> CapturedMessage {
    let (body, truncated) = if body.len() > MAX_CAPTURE_BYTES {
        (&body[..MAX_CAPTURE_BYTES], true)
    } else {
        (body, false)
    };
    CapturedMessage {
        headers: redact_headers(headers),
        body: String::from_utf8_lossy(body).into_owned(),
        truncated,
    }
}

fn redact_headers(headers: &HeaderMap) -> Value {
    let mut output = serde_json::Map::new();
    for (name, value) in headers {
        let lower = name.as_str().to_ascii_lowercase();
        let value = if matches!(
            lower.as_str(),
            "authorization"
                | "proxy-authorization"
                | "x-api-key"
                | "x-goog-api-key"
                | "cookie"
                | "set-cookie"
        ) || lower.contains("token")
            || lower.contains("secret")
        {
            "<redacted>".to_string()
        } else {
            value
                .to_str()
                .map(redact_text)
                .unwrap_or_else(|_| "<binary>".into())
        };
        output.insert(name.to_string(), Value::String(value));
    }
    Value::Object(output)
}

fn redact_text(input: &str) -> String {
    let mut output = input.to_string();
    for marker in ["Bearer ", "Basic "] {
        while let Some(start) = output.find(marker) {
            let value_start = start + marker.len();
            let value_end = output[value_start..]
                .find(char::is_whitespace)
                .map(|offset| value_start + offset)
                .unwrap_or(output.len());
            output.replace_range(value_start..value_end, "<redacted>");
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn ring_is_bounded_and_headers_are_redacted() {
        let store = MonitorStore::new(2);
        let mut headers = HeaderMap::new();
        headers.insert("authorization", "Bearer very-secret".parse().unwrap());
        for index in 0..3 {
            store
                .begin("POST", &format!("/{index}"), None, &headers, b"{}")
                .await;
        }
        let records = store.list(10, None).await;
        assert_eq!(records.len(), 2);
        let detail = store.detail(records[0].id).await.unwrap();
        assert_eq!(detail.client_request.headers["authorization"], "<redacted>");
    }

    #[tokio::test]
    async fn local_completion_does_not_invent_an_upstream_response() {
        let store = MonitorStore::new(2);
        let id = store
            .begin("GET", "/v1/models", None, &HeaderMap::new(), b"")
            .await;
        let mut headers = HeaderMap::new();
        headers.insert("content-type", "application/json".parse().unwrap());
        store
            .complete_local(id, 200, 1, &headers, br#"{"models":[]}"#)
            .await;
        let detail = store.detail(id).await.unwrap();
        assert!(detail.upstream_request.is_none());
        assert!(detail.upstream_response.is_none());
        assert_eq!(detail.client_response.unwrap().body, r#"{"models":[]}"#);
    }
}
