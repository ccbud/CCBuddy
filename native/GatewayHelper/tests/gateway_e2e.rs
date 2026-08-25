use ccbud_gateway::anthropic_reasoning::{
    encode_anthropic_thinking_block, ANTHROPIC_THINKING_ENCRYPTED_PREFIX,
};
use ccbud_gateway::config::GatewayConfig;
use ccbud_gateway::server::{start, RunningGateway};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{Mutex, Notify};

const MANAGEMENT_TOKEN: &str = "0123456789abcdef0123456789abcdef";

struct MockUpstream {
    port: u16,
    requests: Arc<Mutex<Vec<Vec<u8>>>>,
    task: tokio::task::JoinHandle<()>,
}

impl MockUpstream {
    async fn start(status: u16, body: Value) -> Self {
        let body = body.to_string();
        let reason = match status {
            200 => "OK",
            401 => "Unauthorized",
            429 => "Too Many Requests",
            503 => "Service Unavailable",
            _ => "Response",
        };
        Self::start_raw(format!(
            "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        ))
        .await
    }

    async fn start_raw(response: String) -> Self {
        Self::start_bytes(response.into_bytes()).await
    }

    async fn start_bytes(response: Vec<u8>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let recorded = requests.clone();
        let task = tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                let request = read_http_message(&mut stream).await.unwrap();
                recorded.lock().await.push(request);
                stream.write_all(&response).await.unwrap();
                stream.shutdown().await.unwrap();
            }
        });
        Self {
            port,
            requests,
            task,
        }
    }

    async fn count(&self) -> usize {
        self.requests.lock().await.len()
    }

    async fn latest_text(&self) -> String {
        let requests = self.requests.lock().await;
        String::from_utf8(requests.last().unwrap().clone()).unwrap()
    }
}

impl Drop for MockUpstream {
    fn drop(&mut self) {
        self.task.abort();
    }
}

struct GatedSseUpstream {
    port: u16,
    requests: Arc<Mutex<Vec<Vec<u8>>>>,
    release_terminal: Arc<Notify>,
    terminal_sent: Arc<AtomicBool>,
    task: tokio::task::JoinHandle<()>,
}

impl GatedSseUpstream {
    async fn start(first: String, terminal: String) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let recorded = requests.clone();
        let release_terminal = Arc::new(Notify::new());
        let release = release_terminal.clone();
        let terminal_sent = Arc::new(AtomicBool::new(false));
        let sent = terminal_sent.clone();
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let request = read_http_message(&mut stream).await.unwrap();
            recorded.lock().await.push(request);
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
                )
                .await
                .unwrap();
            stream.write_all(first.as_bytes()).await.unwrap();
            stream.flush().await.unwrap();
            release.notified().await;
            sent.store(true, Ordering::SeqCst);
            stream.write_all(terminal.as_bytes()).await.unwrap();
            stream.shutdown().await.unwrap();
        });
        Self {
            port,
            requests,
            release_terminal,
            terminal_sent,
            task,
        }
    }

    async fn latest_text(&self) -> String {
        let requests = self.requests.lock().await;
        String::from_utf8(requests.last().unwrap().clone()).unwrap()
    }
}

impl Drop for GatedSseUpstream {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn config(providers: Value, failover: Value, circuit: Value) -> GatewayConfig {
    serde_json::from_value(json!({
        "publicPort": 0,
        "management": {"port": 0, "bearerToken": MANAGEMENT_TOKEN},
        "providers": providers,
        "activeProviderId": "primary",
        "failover": failover,
        "retry": {"enabled": true, "maxRetries": 10, "baseMs": 1, "maxBackoffMs": 1},
        "circuitBreaker": circuit,
        "monitorCapacity": 32,
        "requestBodyLimitBytes": 1048576,
        "responseBodyLimitBytes": 1048576
    }))
    .unwrap()
}

async fn send_raw_gateway_request(running: &RunningGateway, body: &Value) -> Vec<u8> {
    send_raw_gateway_request_to(running, "/v1/messages", body).await
}

async fn send_raw_gateway_request_to(
    running: &RunningGateway,
    path: &str,
    body: &Value,
) -> Vec<u8> {
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", running.listeners.public_port))
        .await
        .unwrap();
    let body = body.to_string();
    let request = format!(
        "POST {path} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nX-Custom-Case: preserved\r\nx-api-key: client-placeholder\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        running.listeners.public_port,
        body.len()
    );
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut response = Vec::new();
    stream.read_to_end(&mut response).await.unwrap();
    response
}

async fn send_encoded_gateway_request(
    running: &RunningGateway,
    path: &str,
    content_encoding: &str,
    body: &[u8],
) -> Vec<u8> {
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", running.listeners.public_port))
        .await
        .unwrap();
    let request_head = format!(
        "POST {path} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nx-api-key: client-placeholder\r\nContent-Type: application/json\r\nContent-Encoding: {content_encoding}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        running.listeners.public_port,
        body.len()
    );
    stream.write_all(request_head.as_bytes()).await.unwrap();
    stream.write_all(body).await.unwrap();
    let mut response = Vec::new();
    stream.read_to_end(&mut response).await.unwrap();
    response
}

#[tokio::test]
async fn translates_anthropic_to_chat_and_preserves_header_case() {
    let upstream = MockUpstream::start(
        200,
        json!({
            "id":"chatcmpl-1", "object":"chat.completion", "created":1,
            "model":"upstream-model",
            "choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],
            "usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}
        }),
    )
    .await;
    let running = start(config(
        json!([{
            "id":"primary", "name":"Primary", "baseUrl":format!("http://127.0.0.1:{}/v1", upstream.port),
            "authToken":"provider-secret", "defaultModel":"upstream-model", "protocol":"openai-chat"
        }]),
        json!({"enabled":false,"providerIds":[]}),
        json!({"failureThreshold":2,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();
    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6", "max_tokens":64,
            "messages":[{"role":"user","content":"hi"}], "stream":false
        }),
    )
    .await;
    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    assert!(response.contains("\"type\":\"message\""), "{response}");
    assert!(response.contains("\"text\":\"hello\""), "{response}");

    let upstream_request = upstream.latest_text().await;
    assert!(
        upstream_request.contains("X-Custom-Case: preserved\r\n"),
        "{upstream_request}"
    );
    assert!(
        upstream_request.contains("authorization: Bearer provider-secret\r\n"),
        "{upstream_request}"
    );
    assert!(!upstream_request.contains("client-placeholder"));
    let upstream_body: Value =
        serde_json::from_str(upstream_request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(upstream_body["model"], "upstream-model");
    assert_eq!(upstream_body["messages"][0]["content"], "hi");

    let management = format!("http://127.0.0.1:{}", running.listeners.management_port);
    let logs: Value = reqwest::Client::new()
        .get(format!("{management}/logs"))
        .bearer_auth(MANAGEMENT_TOKEN)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(logs["data"][0]["translation"], "anthropic → openai-chat");
    let id = logs["data"][0]["id"].as_u64().unwrap();
    let detail: Value = reqwest::Client::new()
        .get(format!("{management}/logs/{id}"))
        .bearer_auth(MANAGEMENT_TOKEN)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        detail["clientRequest"]["headers"]["x-api-key"],
        "<redacted>"
    );
    assert_eq!(
        detail["upstreamRequest"]["headers"]["authorization"],
        "<redacted>"
    );
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn ordered_failover_opens_primary_circuit_and_skips_it_next_time() {
    let primary = MockUpstream::start(503, json!({"error":{"message":"down"}})).await;
    let secondary = MockUpstream::start(200, json!({"type":"message","content":[]})).await;
    let running = start(config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic"},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}",secondary.port),"protocol":"anthropic"}
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();
    let request = json!({
        "model":"claude-sonnet-4-6","max_tokens":32,
        "messages":[{"role":"user","content":"hi"}],"stream":false
    });
    for _ in 0..2 {
        let response = send_raw_gateway_request(&running, &request).await;
        assert!(String::from_utf8(response)
            .unwrap()
            .starts_with("HTTP/1.1 200"));
    }
    assert_eq!(primary.count().await, 1, "open primary must be skipped");
    assert_eq!(secondary.count().await, 2);

    let status: Value = reqwest::Client::new()
        .get(format!(
            "http://127.0.0.1:{}/status",
            running.listeners.management_port
        ))
        .bearer_auth(MANAGEMENT_TOKEN)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(status["providers"][0]["circuit"]["state"], "open");
    assert_eq!(status["successfulRequests"], 2);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn enabled_failover_uses_only_the_declared_queue_and_ignores_active_provider() {
    let primary = MockUpstream::start(500, json!({"error":{"message":"must not be called"}})).await;
    let secondary = MockUpstream::start(200, json!({"type":"message","content":[]})).await;
    let running = start(config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic"},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}",secondary.port),"protocol":"anthropic"}
        ]),
        json!({"enabled":true,"providerIds":["secondary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6","max_tokens":32,
            "messages":[{"role":"user","content":"hi"}],"stream":false
        }),
    )
    .await;

    assert!(String::from_utf8(response)
        .unwrap()
        .starts_with("HTTP/1.1 200"));
    assert_eq!(primary.count().await, 0);
    assert_eq!(secondary.count().await, 1);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn failover_retry_budget_is_global_and_each_provider_runs_once() {
    let primary = MockUpstream::start(503, json!({"error":{"message":"primary down"}})).await;
    let secondary = MockUpstream::start(503, json!({"error":{"message":"secondary down"}})).await;
    let tertiary = MockUpstream::start(503, json!({"error":{"message":"tertiary down"}})).await;
    let mut gateway_config = config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic"},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}",secondary.port),"protocol":"anthropic"},
            {"id":"tertiary","name":"Tertiary","baseUrl":format!("http://127.0.0.1:{}",tertiary.port),"protocol":"anthropic"}
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary","tertiary"]}),
        json!({"failureThreshold":4,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    );
    gateway_config.retry.max_retries = 1;
    let running = start(gateway_config).await.unwrap();

    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6","max_tokens":32,
            "messages":[{"role":"user","content":"hi"}],"stream":false
        }),
    )
    .await;

    assert!(String::from_utf8(response)
        .unwrap()
        .starts_with("HTTP/1.1 503"));
    assert_eq!(primary.count().await, 1);
    assert_eq!(secondary.count().await, 1);
    assert_eq!(tertiary.count().await, 0);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn disabling_same_provider_retry_keeps_the_failover_provider_budget() {
    let primary = MockUpstream::start(503, json!({"error":{"message":"primary down"}})).await;
    let secondary = MockUpstream::start(200, json!({"type":"message","content":[]})).await;
    let mut gateway_config = config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic"},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}",secondary.port),"protocol":"anthropic"}
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary"]}),
        json!({"failureThreshold":4,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    );
    gateway_config.retry.enabled = false;
    let running = start(gateway_config).await.unwrap();

    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6","max_tokens":32,
            "messages":[{"role":"user","content":"hi"}],"stream":false
        }),
    )
    .await;

    assert!(String::from_utf8(response)
        .unwrap()
        .starts_with("HTTP/1.1 200"));
    assert_eq!(primary.count().await, 1);
    assert_eq!(secondary.count().await, 1);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn provider_local_compaction_error_fails_over_before_upstream_io() {
    let primary = MockUpstream::start(500, json!({"error":{"message":"must not be called"}})).await;
    let secondary = MockUpstream::start(200, json!({"id":"resp-compact-1","output":[]})).await;
    let running = start(config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic"},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}",secondary.port),"protocol":"openai-responses"}
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let response = send_raw_gateway_request_to(
        &running,
        "/v1/responses/compact",
        &json!({"model":"gpt-5.4","input":"compact me"}),
    )
    .await;

    assert!(String::from_utf8(response)
        .unwrap()
        .starts_with("HTTP/1.1 200"));
    assert_eq!(primary.count().await, 0);
    assert_eq!(secondary.count().await, 1);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn alpha_search_skips_incompatible_providers_and_preserves_native_semantics() {
    let primary = MockUpstream::start(500, json!({"error":{"message":"must not be called"}})).await;
    let response_body = r#"{"encrypted_output":"ciphertext"}"#;
    let secondary = MockUpstream::start_raw(format!(
        "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nx-upstream-request-id: search-1\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response_body}",
        response_body.len()
    ))
    .await;
    let running = start(config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}/v1",primary.port),"protocol":"anthropic"},
            {
                "id":"secondary","name":"Secondary",
                "baseUrl":format!("http://127.0.0.1:{}/v1",secondary.port),
                "authToken":"responses-secret","defaultModel":"gpt-default",
                "models":[{"alias":"gpt-client","upstream":"gpt-upstream"}],
                "protocol":"openai-responses"
            }
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();
    let body = json!({
        "id":"search-1",
        "model":"gpt-client",
        "commands":{"search_query":[{"q":"latest Rust release"}]},
        "metadata":{"request":"alpha-1"},
        "_ccbud_private":"must-not-leak"
    });

    let response = send_raw_gateway_request_to(
        &running,
        "/codex/v1/alpha/search?api-version=test&client_version=0.144.6",
        &body,
    )
    .await;

    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 202"), "{response}");
    assert!(
        response.contains("x-upstream-request-id: search-1\r\n"),
        "{response}"
    );
    assert!(response.ends_with(response_body), "{response}");
    assert_eq!(primary.count().await, 0);
    assert_eq!(secondary.count().await, 1);
    let upstream_request = secondary.latest_text().await;
    assert!(
        upstream_request.starts_with(
            "POST /v1/alpha/search?api-version=test&client_version=0.144.6 HTTP/1.1\r\n"
        ),
        "{upstream_request}"
    );
    assert!(
        upstream_request.contains("authorization: Bearer responses-secret\r\n"),
        "{upstream_request}"
    );
    assert!(
        upstream_request.contains("X-Custom-Case: preserved\r\n"),
        "{upstream_request}"
    );
    assert!(!upstream_request.contains("client-placeholder"));
    let upstream_body: Value =
        serde_json::from_str(upstream_request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(upstream_body["id"], body["id"]);
    assert_eq!(
        upstream_body["commands"]["search_query"],
        body["commands"]["search_query"]
    );
    assert_eq!(upstream_body["metadata"], body["metadata"]);
    assert_eq!(upstream_body["model"], "gpt-upstream");
    assert!(upstream_body.get("_ccbud_private").is_none());
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn decodes_codex_zstd_requests_before_model_mapping_and_forwarding() {
    let upstream = MockUpstream::start(200, json!({"id":"resp-zstd-1","output":[]})).await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}/v1",upstream.port),
            "authToken":"provider-secret","protocol":"openai-responses",
            "models":[{"alias":"gpt-client","upstream":"gpt-upstream"}]
        }]),
        json!({"enabled":false,"providerIds":[]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();
    let body = json!({
        "model":"gpt-client",
        "input":"compressed request",
        "stream":false
    })
    .to_string();
    let compressed = zstd::stream::encode_all(std::io::Cursor::new(body.as_bytes()), 0).unwrap();

    let response =
        send_encoded_gateway_request(&running, "/codex/v1/responses", "zstd", &compressed).await;

    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    let upstream_request = upstream.latest_text().await;
    assert!(!upstream_request
        .to_ascii_lowercase()
        .contains("content-encoding"));
    let upstream_body: Value =
        serde_json::from_str(upstream_request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(upstream_body["model"], "gpt-upstream");
    assert_eq!(upstream_body["input"], "compressed request");
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn rejects_stacked_or_malformed_compression_before_upstream_io() {
    let upstream =
        MockUpstream::start(500, json!({"error":{"message":"must not be called"}})).await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}/v1",upstream.port),
            "protocol":"openai-responses"
        }]),
        json!({"enabled":false,"providerIds":[]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let stacked = send_encoded_gateway_request(
        &running,
        "/v1/responses",
        "gzip, zstd",
        br#"{"model":"gpt-5.6-sol"}"#,
    )
    .await;
    let stacked = String::from_utf8(stacked).unwrap();
    assert!(stacked.starts_with("HTTP/1.1 400"), "{stacked}");
    assert!(stacked.contains("stacked content-encoding"), "{stacked}");

    let malformed =
        send_encoded_gateway_request(&running, "/v1/responses", "zstd", b"not-a-zstd-frame").await;
    let malformed = String::from_utf8(malformed).unwrap();
    assert!(malformed.starts_with("HTTP/1.1 400"), "{malformed}");
    assert!(
        malformed.contains("failed to decompress zstd"),
        "{malformed}"
    );
    assert_eq!(upstream.count().await, 0);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn decodes_bounded_upstream_zstd_before_cross_wire_response_translation() {
    let upstream_body = json!({
        "id":"chatcmpl-compressed",
        "object":"chat.completion",
        "created":1,
        "model":"upstream-model",
        "choices":[{
            "index":0,
            "message":{"role":"assistant","content":"compressed hello"},
            "finish_reason":"stop"
        }]
    })
    .to_string();
    let compressed =
        zstd::stream::encode_all(std::io::Cursor::new(upstream_body.as_bytes()), 0).unwrap();
    let mut raw_response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: zstd\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        compressed.len()
    )
    .into_bytes();
    raw_response.extend_from_slice(&compressed);
    let upstream = MockUpstream::start_bytes(raw_response).await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}/v1",upstream.port),
            "defaultModel":"upstream-model","protocol":"openai-chat"
        }]),
        json!({"enabled":false,"providerIds":[]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6","max_tokens":64,
            "messages":[{"role":"user","content":"hello"}],"stream":false
        }),
    )
    .await;

    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    assert!(response.contains("compressed hello"), "{response}");
    assert!(response.contains("\"type\":\"message\""), "{response}");
    assert!(!response.to_ascii_lowercase().contains("content-encoding"));
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn decodes_compressed_terminal_failover_response_and_preserves_raw_monitor_capture() {
    let upstream_body = json!({"error":{"message":"compressed overload"}}).to_string();
    let compressed =
        zstd::stream::encode_all(std::io::Cursor::new(upstream_body.as_bytes()), 0).unwrap();
    let mut raw_response = format!(
        "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Encoding: zstd\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        compressed.len()
    )
    .into_bytes();
    raw_response.extend_from_slice(&compressed);
    let upstream = MockUpstream::start_bytes(raw_response).await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}",upstream.port),
            "protocol":"anthropic"
        }]),
        json!({"enabled":true,"providerIds":["primary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6","max_tokens":32,
            "messages":[{"role":"user","content":"hello"}],"stream":false
        }),
    )
    .await;

    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 503"), "{response}");
    assert!(response.contains("compressed overload"), "{response}");
    assert!(!response.to_ascii_lowercase().contains("content-encoding"));

    let management = format!("http://127.0.0.1:{}", running.listeners.management_port);
    let logs: Value = reqwest::Client::new()
        .get(format!("{management}/logs"))
        .bearer_auth(MANAGEMENT_TOKEN)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let id = logs["data"][0]["id"].as_u64().unwrap();
    let detail: Value = reqwest::Client::new()
        .get(format!("{management}/logs/{id}"))
        .bearer_auth(MANAGEMENT_TOKEN)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        detail["upstreamResponse"]["headers"]["content-encoding"],
        "zstd"
    );
    assert!(detail["clientResponse"]["headers"]
        .get("content-encoding")
        .is_none());
    assert!(detail["clientResponse"]["body"]
        .as_str()
        .unwrap()
        .contains("compressed overload"));
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn rejects_compressed_terminal_failover_bombs_at_the_decompressed_limit() {
    let expanded = vec![0u8; 2 * 1024 * 1024];
    let compressed = zstd::stream::encode_all(std::io::Cursor::new(expanded), 0).unwrap();
    assert!(compressed.len() < 1024 * 1024);
    let mut raw_response = format!(
        "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Encoding: zstd\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        compressed.len()
    )
    .into_bytes();
    raw_response.extend_from_slice(&compressed);
    let upstream = MockUpstream::start_bytes(raw_response).await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}",upstream.port),
            "protocol":"anthropic"
        }]),
        json!({"enabled":true,"providerIds":["primary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6","max_tokens":32,
            "messages":[{"role":"user","content":"hello"}],"stream":false
        }),
    )
    .await;

    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 502"), "{response}");
    assert!(
        response.contains("response body exceeded 1048576 bytes"),
        "{response}"
    );

    let management = format!("http://127.0.0.1:{}", running.listeners.management_port);
    let logs: Value = reqwest::Client::new()
        .get(format!("{management}/logs"))
        .bearer_auth(MANAGEMENT_TOKEN)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let id = logs["data"][0]["id"].as_u64().unwrap();
    let detail: Value = reqwest::Client::new()
        .get(format!("{management}/logs/{id}"))
        .bearer_auth(MANAGEMENT_TOKEN)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(detail["status"], 502);
    assert_eq!(
        detail["upstreamResponse"]["headers"]["content-encoding"],
        "zstd"
    );
    assert!(!detail["upstreamResponse"]["body"]
        .as_str()
        .unwrap()
        .is_empty());
    assert!(detail["clientResponse"]["body"]
        .as_str()
        .unwrap()
        .contains("response body exceeded 1048576 bytes"));
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn rejects_upstream_compression_bombs_at_the_decompressed_limit() {
    let expanded = vec![0u8; 2 * 1024 * 1024];
    let compressed = zstd::stream::encode_all(std::io::Cursor::new(expanded), 0).unwrap();
    assert!(compressed.len() < 1024 * 1024);
    let mut raw_response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: zstd\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        compressed.len()
    )
    .into_bytes();
    raw_response.extend_from_slice(&compressed);
    let upstream = MockUpstream::start_bytes(raw_response).await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}/v1",upstream.port),
            "protocol":"openai-responses"
        }]),
        json!({"enabled":false,"providerIds":[]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let response = send_raw_gateway_request_to(
        &running,
        "/v1/responses",
        &json!({"model":"gpt-5.6-sol","input":"hello"}),
    )
    .await;

    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 502"), "{response}");
    assert!(
        response.contains("response body exceeded 1048576 bytes"),
        "{response}"
    );
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn responses_hosted_search_is_not_silently_dropped_by_cross_wire_failover() {
    let primary = MockUpstream::start(500, json!({"error":{"message":"must not be called"}})).await;
    let secondary = MockUpstream::start(200, json!({"id":"resp-search-1","output":[]})).await;
    let running = start(config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}/v1",primary.port),"protocol":"anthropic"},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}/v1",secondary.port),"protocol":"openai-responses"}
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let response = send_raw_gateway_request_to(
        &running,
        "/v1/responses",
        &json!({
            "model":"gpt-5.6-sol",
            "input":"Find the current release",
            "tools":[{"type":"web_search"}]
        }),
    )
    .await;

    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    assert_eq!(primary.count().await, 0);
    assert_eq!(secondary.count().await, 1);
    let upstream_request = secondary.latest_text().await;
    let upstream_body: Value =
        serde_json::from_str(upstream_request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(upstream_body["tools"], json!([{"type":"web_search"}]));
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn anthropic_hosted_search_bridges_to_responses_with_pairs_and_citations() {
    let primary = MockUpstream::start(
        200,
        json!({
            "id":"resp-search-1", "status":"completed", "model":"gpt-5.6",
            "output":[
                {
                    "type":"web_search_call", "id":"ws_1", "status":"completed",
                    "action":{"type":"search","query":"current release","sources":[{
                        "type":"url","url":"https://example.com/release"
                    }]}
                },
                {
                    "type":"message", "role":"assistant", "content":[{
                        "type":"output_text", "text":"The current release is available.",
                        "annotations":[{
                            "type":"url_citation", "url":"https://example.com/release",
                            "title":"Release notes"
                        }]
                    }]
                }
            ],
            "usage":{"input_tokens":9,"output_tokens":5}
        }),
    )
    .await;
    let secondary = MockUpstream::start(200, json!({"type":"message","content":[]})).await;
    let running = start(config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}/v1",primary.port),"protocol":"openai-responses"},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}/v1",secondary.port),"protocol":"anthropic"}
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6",
            "max_tokens":64,
            "messages":[{"role":"user","content":"Find the current release"}],
            "tools":[{
                "type":"web_search_20260318",
                "name":"web_search",
                "allowed_callers":["direct"],
                "max_uses":2,
                "allowed_domains":["example.com"]
            }]
        }),
    )
    .await;

    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    assert!(response.contains("server_tool_use"), "{response}");
    assert!(response.contains("web_search_tool_result"), "{response}");
    assert!(response.contains("Release notes"), "{response}");
    assert!(response.contains("web_search_requests"), "{response}");
    assert_eq!(primary.count().await, 1);
    assert_eq!(secondary.count().await, 0);
    let upstream_request = primary.latest_text().await;
    let upstream_body: Value =
        serde_json::from_str(upstream_request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(upstream_body["tools"][0]["type"], "web_search");
    assert_eq!(
        upstream_body["tools"][0]["filters"]["allowed_domains"],
        json!(["example.com"])
    );
    assert_eq!(upstream_body["max_tool_calls"], 2);
    assert_eq!(
        upstream_body["include"],
        json!(["web_search_call.action.sources"])
    );
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn anthropic_hosted_search_stream_recovers_terminal_responses_sse() {
    let terminal = json!({
        "id":"resp-search-stream", "status":"completed", "model":"gpt-5.6",
        "output":[
            {
                "type":"web_search_call", "id":"ws_stream", "status":"completed",
                "action":{"type":"search","query":"Rust docs","sources":[{
                    "type":"url","url":"https://doc.rust-lang.org/","title":"Rust docs"
                }]}
            },
            {
                "type":"message", "role":"assistant", "content":[{
                    "type":"output_text", "text":"Rust documentation is online.",
                    "annotations":[{
                        "type":"url_citation", "url":"https://doc.rust-lang.org/",
                        "title":"Rust docs"
                    }]
                }]
            }
        ],
        "usage":{"input_tokens":8,"output_tokens":5}
    });
    let sse = format!(
        "event: response.created\ndata: {}\n\n\
         event: response.output_item.added\ndata: {}\n\n\
         event: response.output_item.done\ndata: {}\n\n\
         event: response.completed\ndata: {}\n\n\
         data: [DONE]\n\n",
        json!({"type":"response.created","response":{"id":"resp-search-stream"}}),
        json!({"type":"response.output_item.added","output_index":0,"item":{"id":"ws_stream","type":"web_search_call","status":"in_progress"}}),
        json!({"type":"response.output_item.done","output_index":0,"item":terminal["output"][0]}),
        json!({"type":"response.completed","response":terminal})
    );
    let upstream = MockUpstream::start_raw(format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{sse}",
        sse.len()
    ))
    .await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}/v1",upstream.port),
            "protocol":"openai-responses"
        }]),
        json!({"enabled":false,"providerIds":[]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6", "max_tokens":64, "stream":true,
            "messages":[{"role":"user","content":"Find Rust docs"}],
            "tools":[{
                "type":"web_search_20260318", "name":"web_search_next",
                "allowed_callers":["direct"], "max_uses":2
            }]
        }),
    )
    .await;

    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    assert!(
        response.contains("content-type: text/event-stream"),
        "{response}"
    );
    assert!(response.contains("message_stop"), "{response}");
    assert!(response.contains("web_search_next"), "{response}");
    assert!(response.contains("Rust docs"), "{response}");
    assert!(
        response.contains("https://doc.rust-lang.org/"),
        "{response}"
    );
    assert!(response.contains("web_search_requests"), "{response}");
    let call = response.find("server_tool_use").unwrap();
    let result = response.find("web_search_tool_result").unwrap();
    assert!(call < result, "{response}");
    assert!(!response.contains("response.output_item"), "{response}");

    let upstream_request = upstream.latest_text().await;
    let upstream_body: Value =
        serde_json::from_str(upstream_request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(upstream_body["stream"], false);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn codex_anthropic_signed_thinking_stream_is_incremental_and_complete() {
    let first = concat!(
        "event: message_start\n",
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_live\",\"model\":\"claude-upstream\",\"usage\":{\"input_tokens\":5,\"cache_read_input_tokens\":2}}}\n\n",
        "event: content_block_start\n",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n",
        "event: content_block_delta\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"inspect live\"}}\n\n"
    );
    let terminal = concat!(
        "event: content_block_delta\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig_live\"}}\n\n",
        "event: content_block_stop\n",
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
        "event: content_block_start\n",
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_live\",\"name\":\"read\",\"input\":{}}}\n\n",
        "event: content_block_delta\n",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"live.txt\\\"}\"}}\n\n",
        "event: content_block_stop\n",
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n",
        "event: message_delta\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":3,\"output_tokens_details\":{\"thinking_tokens\":2}}}\n\n",
        "event: message_stop\n",
        "data: {\"type\":\"message_stop\"}\n\n"
    );
    let upstream = GatedSseUpstream::start(first.to_string(), terminal.to_string()).await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}/v1",upstream.port),
            "defaultModel":"claude-upstream","protocol":"anthropic"
        }]),
        json!({"enabled":false,"providerIds":[]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", running.listeners.public_port))
        .await
        .unwrap();
    let body = json!({
        "model":"gpt-client","stream":true,"reasoning":{"effort":"high"},
        "input":[{"type":"message","role":"user","content":"inspect live"}],
        "tools":[{
            "type":"function","name":"read","parameters":{
                "type":"object","properties":{"path":{"type":"string"}}
            }
        }]
    })
    .to_string();
    let request = format!(
        "POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        running.listeners.public_port,
        body.len()
    );
    stream.write_all(request.as_bytes()).await.unwrap();

    let mut response = Vec::new();
    let mut buffer = [0u8; 8192];
    tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            let count = stream.read(&mut buffer).await.unwrap();
            assert!(count > 0, "gateway closed before the live reasoning delta");
            response.extend_from_slice(&buffer[..count]);
            if String::from_utf8_lossy(&response).contains("response.reasoning_summary_text.delta")
            {
                break;
            }
        }
    })
    .await
    .expect("live reasoning was buffered until the Anthropic terminal event");

    let prefix = String::from_utf8_lossy(&response);
    assert!(prefix.contains("response.reasoning_summary_part.added"));
    assert!(!prefix.contains("response.completed"));
    assert!(!prefix.contains(ANTHROPIC_THINKING_ENCRYPTED_PREFIX));
    assert!(!upstream.terminal_sent.load(Ordering::SeqCst));

    upstream.release_terminal.notify_one();
    stream.read_to_end(&mut response).await.unwrap();
    let response = String::from_utf8_lossy(&response);
    assert!(
        response.contains("response.reasoning_summary_text.done"),
        "{response}"
    );
    assert!(
        response.contains("response.reasoning_summary_part.done"),
        "{response}"
    );
    assert!(
        response.contains("response.function_call_arguments.delta"),
        "{response}"
    );
    assert!(
        response.contains("response.function_call_arguments.done"),
        "{response}"
    );
    assert!(response.contains("event: response.completed"), "{response}");
    assert_eq!(
        response
            .matches(ANTHROPIC_THINKING_ENCRYPTED_PREFIX)
            .count(),
        2,
        "the done item and terminal response must both carry signed reasoning: {response}"
    );
    assert!(response.contains("\"reasoning_tokens\":2"), "{response}");

    let upstream_request = upstream.latest_text().await;
    let upstream_body: Value =
        serde_json::from_str(upstream_request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(upstream_body["stream"], true);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn anthropic_hosted_search_stream_fails_closed_without_terminal_response() {
    let sse = concat!(
        "event: response.created\n",
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp-truncated\"}}\n\n",
        "data: [DONE]\n\n"
    );
    let upstream = MockUpstream::start_raw(format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{sse}",
        sse.len()
    ))
    .await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}/v1",upstream.port),
            "protocol":"openai-responses"
        }]),
        json!({"enabled":false,"providerIds":[]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6", "max_tokens":64, "stream":true,
            "messages":[{"role":"user","content":"search"}],
            "tools":[{"type":"web_search_20250305","name":"web_search"}]
        }),
    )
    .await;

    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 502"), "{response}");
    assert!(
        response.contains("without a completed or incomplete terminal response"),
        "{response}"
    );
    assert!(!response.contains("server_tool_use"), "{response}");
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn codex_anthropic_bridge_replays_and_returns_signed_thinking() {
    let returned_thinking =
        json!({"type":"thinking","thinking":"inspect next","signature":"sig_returned"});
    let upstream = MockUpstream::start(
        200,
        json!({
            "id":"msg_signed", "type":"message", "role":"assistant",
            "model":"claude-upstream",
            "content":[
                returned_thinking,
                {"type":"tool_use","id":"call_next","name":"read","input":{"path":"next.txt"}}
            ],
            "stop_reason":"tool_use",
            "usage":{
                "input_tokens":5,"cache_read_input_tokens":2,
                "cache_creation_input_tokens":1,"output_tokens":3,
                "output_tokens_details":{"thinking_tokens":2}
            }
        }),
    )
    .await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}/v1",upstream.port),
            "defaultModel":"claude-upstream","protocol":"anthropic"
        }]),
        json!({"enabled":false,"providerIds":[]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let replayed_thinking =
        json!({"type":"thinking","thinking":"inspect","signature":"sig_replayed"});
    let encrypted = encode_anthropic_thinking_block(&replayed_thinking).unwrap();
    let response = send_raw_gateway_request_to(
        &running,
        "/v1/responses",
        &json!({
            "model":"gpt-client","max_output_tokens":8192,"stream":true,
            "reasoning":{"effort":"high","summary":"auto"},
            "input":[
                {"type":"message","role":"user","content":[{"type":"input_text","text":"inspect"}]},
                {"type":"reasoning","id":"rs_previous","summary":[{"type":"summary_text","text":"inspect"}],
                 "encrypted_content":encrypted},
                {"type":"function_call","id":"fc_previous","call_id":"call_previous",
                 "name":"read","arguments":"{\"path\":\"old.txt\"}","status":"completed"},
                {"type":"function_call_output","call_id":"call_previous","output":"old contents"}
            ],
            "tools":[{
                "type":"function","name":"read","description":"Read a file",
                "parameters":{"type":"object","properties":{"path":{"type":"string"}}}
            }]
        }),
    )
    .await;

    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    assert!(
        response.contains("content-type: text/event-stream"),
        "{response}"
    );
    assert!(response.contains("event: response.completed"), "{response}");
    assert!(
        response.contains("response.reasoning_summary_text.delta"),
        "{response}"
    );
    assert_eq!(
        response
            .matches(ANTHROPIC_THINKING_ENCRYPTED_PREFIX)
            .count(),
        2,
        "signed reasoning must be present in the done item and terminal response: {response}"
    );
    assert!(response.contains("\"cached_tokens\":2"), "{response}");
    assert!(response.contains("\"reasoning_tokens\":2"), "{response}");

    let upstream_request = upstream.latest_text().await;
    let upstream_body: Value =
        serde_json::from_str(upstream_request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(upstream_body["model"], "claude-upstream");
    // Compatible gateways may ignore stream:true and return JSON. The gateway still preserves
    // signed reasoning while the conforming path remains genuinely incremental (covered above).
    assert_eq!(upstream_body["stream"], true);
    assert_eq!(upstream_body["thinking"]["type"], "enabled");
    assert_eq!(upstream_body["thinking"]["budget_tokens"], 4096);
    let assistant = upstream_body["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|message| {
            message.get("role").and_then(Value::as_str) == Some("assistant")
                && message["content"]
                    .as_array()
                    .is_some_and(|blocks| blocks.iter().any(|block| block["id"] == "call_previous"))
        })
        .unwrap();
    assert_eq!(assistant["content"][0], replayed_thinking);
    assert_eq!(assistant["content"][1]["type"], "tool_use");
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn invalid_client_history_is_terminal_without_trying_any_provider() {
    let primary = MockUpstream::start(500, json!({"error":{"message":"must not be called"}})).await;
    let secondary = MockUpstream::start(200, json!({"id":"resp-1","output":[]})).await;
    let running = start(config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic"},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}",secondary.port),"protocol":"openai-responses"}
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();

    let response = send_raw_gateway_request_to(
        &running,
        "/v1/responses",
        &json!({
            "model":"gpt-5.4",
            "input":[{"type":"function_call_output","call_id":"missing","output":"x"}]
        }),
    )
    .await;
    let response = String::from_utf8(response).unwrap();

    assert!(response.starts_with("HTTP/1.1 400"), "{response}");
    assert!(response.contains("invalid_request_error"), "{response}");
    assert_eq!(primary.count().await, 0);
    assert_eq!(secondary.count().await, 0);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn non_object_inference_json_is_rejected_before_routing() {
    let primary = MockUpstream::start(200, json!({"type":"message","content":[]})).await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic"
        }]),
        json!({"enabled":true,"providerIds":["primary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":1}),
    ))
    .await
    .unwrap();

    for body in [
        json!([{"model":"claude-sonnet-4-6"}]),
        json!("text"),
        Value::Null,
    ] {
        let response = String::from_utf8(send_raw_gateway_request(&running, &body).await).unwrap();
        assert!(response.starts_with("HTTP/1.1 400"), "{response}");
        assert!(response.contains("invalid_request_error"), "{response}");
        assert!(
            response.contains("request body must be a JSON object"),
            "{response}"
        );
    }

    assert_eq!(primary.count().await, 0);
    let status: Value = reqwest::Client::new()
        .get(format!(
            "http://127.0.0.1:{}/status",
            running.listeners.management_port
        ))
        .bearer_auth(MANAGEMENT_TOKEN)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert!(status["providers"][0]["circuit"].is_null());
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn all_open_provider_circuits_return_explicit_service_unavailable() {
    let primary = MockUpstream::start(503, json!({"error":{"message":"primary down"}})).await;
    let secondary = MockUpstream::start(503, json!({"error":{"message":"secondary down"}})).await;
    let running = start(config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic"},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}",secondary.port),"protocol":"anthropic"}
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();
    let request = json!({
        "model":"claude-sonnet-4-6","max_tokens":32,
        "messages":[{"role":"user","content":"hi"}],"stream":false
    });

    let first = send_raw_gateway_request(&running, &request).await;
    assert!(String::from_utf8(first)
        .unwrap()
        .starts_with("HTTP/1.1 503"));
    assert_eq!(primary.count().await, 1);
    assert_eq!(secondary.count().await, 1);

    let second = String::from_utf8(send_raw_gateway_request(&running, &request).await).unwrap();
    assert!(second.starts_with("HTTP/1.1 503"), "{second}");
    assert!(
        second.contains("all configured provider circuits are unavailable"),
        "{second}"
    );
    assert_eq!(primary.count().await, 1);
    assert_eq!(secondary.count().await, 1);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn request_shape_errors_are_neutral_for_provider_health() {
    for status_code in [400, 405, 406, 413, 414, 415, 422, 501] {
        let primary =
            MockUpstream::start(status_code, json!({"error":{"message":"bad request"}})).await;
        let running = start(config(
            json!([{
                "id":"primary","name":"Primary",
                "baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic"
            }]),
            json!({"enabled":true,"providerIds":["primary"]}),
            json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":1}),
        ))
        .await
        .unwrap();

        let response = send_raw_gateway_request(
            &running,
            &json!({
                "model":"claude-sonnet-4-6","max_tokens":32,
                "messages":[{"role":"user","content":"hi"}],"stream":false
            }),
        )
        .await;
        assert!(
            String::from_utf8(response)
                .unwrap()
                .starts_with(&format!("HTTP/1.1 {status_code}")),
            "status {status_code} was not returned to the client"
        );

        let status: Value = reqwest::Client::new()
            .get(format!(
                "http://127.0.0.1:{}/status",
                running.listeners.management_port
            ))
            .bearer_auth(MANAGEMENT_TOKEN)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(status["providers"][0]["circuit"]["state"], "closed");
        assert_eq!(status["providers"][0]["circuit"]["totalRequests"], 0);
        assert_eq!(status["providers"][0]["circuit"]["failedRequests"], 0);
        running.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn disabled_failover_never_circuit_locks_the_active_provider() {
    let primary = MockUpstream::start(503, json!({"error":{"message":"down"}})).await;
    let running = start(config(
        json!([{
            "id":"primary","name":"Primary",
            "baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic"
        }]),
        json!({"enabled":false,"providerIds":[]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();
    let request = json!({
        "model":"claude-sonnet-4-6","max_tokens":32,
        "messages":[{"role":"user","content":"hi"}],"stream":false
    });
    for _ in 0..2 {
        let response = send_raw_gateway_request(&running, &request).await;
        assert!(String::from_utf8(response)
            .unwrap()
            .starts_with("HTTP/1.1 503"));
    }
    assert_eq!(primary.count().await, 2);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn provider_specific_auth_failure_fails_over_without_retrying_primary() {
    let primary = MockUpstream::start(401, json!({"error":{"message":"bad key"}})).await;
    let secondary = MockUpstream::start(200, json!({"type":"message","content":[]})).await;
    let running = start(config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic"},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}",secondary.port),"protocol":"anthropic"}
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();
    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6","max_tokens":32,
            "messages":[{"role":"user","content":"hi"}],"stream":false
        }),
    )
    .await;
    assert!(String::from_utf8(response)
        .unwrap()
        .starts_with("HTTP/1.1 200"));
    assert_eq!(primary.count().await, 1);
    assert_eq!(secondary.count().await, 1);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn headers_only_stream_fails_over_before_committing_the_response() {
    let primary = MockUpstream::start_raw(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            .into(),
    )
    .await;
    let event = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";
    let secondary = MockUpstream::start_raw(format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{event}",
        event.len()
    ))
    .await;
    let running = start(config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"anthropic","timeoutSeconds":1},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}",secondary.port),"protocol":"anthropic","timeoutSeconds":1}
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();
    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6","max_tokens":32,
            "messages":[{"role":"user","content":"hi"}],"stream":true
        }),
    )
    .await;
    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    assert!(response.contains("message_stop"), "{response}");
    assert_eq!(primary.count().await, 1);
    assert_eq!(secondary.count().await, 1);
    running.shutdown().await.unwrap();
}

#[tokio::test]
async fn response_conversion_failure_fails_over_to_the_next_provider() {
    let primary = MockUpstream::start_raw(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 8\r\nConnection: close\r\n\r\nnot-json"
            .into(),
    )
    .await;
    let secondary = MockUpstream::start(200, json!({"type":"message","content":[]})).await;
    let running = start(config(
        json!([
            {"id":"primary","name":"Primary","baseUrl":format!("http://127.0.0.1:{}",primary.port),"protocol":"openai-chat"},
            {"id":"secondary","name":"Secondary","baseUrl":format!("http://127.0.0.1:{}",secondary.port),"protocol":"anthropic"}
        ]),
        json!({"enabled":true,"providerIds":["primary","secondary"]}),
        json!({"failureThreshold":1,"successThreshold":1,"timeoutSeconds":60,"errorRateThreshold":1.0,"minRequests":10}),
    ))
    .await
    .unwrap();
    let response = send_raw_gateway_request(
        &running,
        &json!({
            "model":"claude-sonnet-4-6","max_tokens":32,
            "messages":[{"role":"user","content":"hi"}],"stream":false
        }),
    )
    .await;
    assert!(String::from_utf8(response)
        .unwrap()
        .starts_with("HTTP/1.1 200"));
    assert_eq!(primary.count().await, 1);
    assert_eq!(secondary.count().await, 1);
    running.shutdown().await.unwrap();
}

async fn read_http_message(stream: &mut tokio::net::TcpStream) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 4096];
    let mut expected = None;
    loop {
        let count = stream.read(&mut buffer).await?;
        if count == 0 {
            break;
        }
        bytes.extend_from_slice(&buffer[..count]);
        if expected.is_none() {
            if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
                let head_end = index + 4;
                let head = String::from_utf8_lossy(&bytes[..head_end]);
                let length = head
                    .lines()
                    .find_map(|line| {
                        line.split_once(':').and_then(|(name, value)| {
                            name.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse::<usize>().ok())
                                .flatten()
                        })
                    })
                    .unwrap_or(0);
                expected = Some(head_end + length);
            }
        }
        if expected.is_some_and(|expected| bytes.len() >= expected) {
            break;
        }
    }
    Ok(bytes)
}
