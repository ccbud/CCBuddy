//! Headless process lifecycle and the public/management listener split.

use crate::auth::management_authorized;
use crate::config::GatewayConfig;
use crate::error::GatewayError;
use crate::forwarder::handle_inference;
use crate::header_case::OriginalHeaderCases;
use crate::state::GatewayState;
use axum::body::Body;
use axum::extract::{Path, Query, Request, State};
use axum::http::{header, Method, StatusCode};
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};
use hyper_util::rt::TokioIo;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::io::Write;
use std::net::Ipv4Addr;
use std::sync::Arc;
use tokio::sync::{oneshot, watch};
use tokio::task::{JoinHandle, JoinSet};
use tower::Service;

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BoundListeners {
    pub public_port: u16,
    pub management_port: u16,
}

pub struct RunningGateway {
    pub listeners: BoundListeners,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<Result<(), GatewayError>>,
}

impl RunningGateway {
    pub async fn shutdown(mut self) -> Result<(), GatewayError> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        self.task
            .await
            .map_err(|error| GatewayError::Http(format!("gateway task failed: {error}")))?
    }
}

pub async fn run(config: GatewayConfig) -> Result<(), GatewayError> {
    let running = start(config).await?;
    println!(
        "{}",
        json!({
            "event": "ready",
            "publicPort": running.listeners.public_port,
            "managementPort": running.listeners.management_port,
        })
    );
    let _ = std::io::stdout().flush();
    shutdown_signal().await;
    running.shutdown().await
}

pub async fn start(config: GatewayConfig) -> Result<RunningGateway, GatewayError> {
    config.validate()?;
    let public = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, config.public_port)).await?;
    let management =
        match tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, config.management.port)).await {
            Ok(listener) => listener,
            Err(error) => {
                drop(public);
                return Err(GatewayError::Io(error));
            }
        };
    let listeners = BoundListeners {
        public_port: public.local_addr()?.port(),
        management_port: management.local_addr()?.port(),
    };
    let state = GatewayState::new(config);
    state.set_bound_ports(listeners.public_port, listeners.management_port);

    let public_router = Router::new()
        .fallback(public_entry)
        .with_state(state.clone());
    let management_router = Router::new()
        .route("/health", get(health))
        .route("/status", get(status))
        .route("/logs", get(log_list).delete(log_clear))
        .route("/logs/clear", post(log_clear))
        .route("/logs/{id}", get(log_detail))
        .fallback(management_not_found)
        .layer(middleware::from_fn_with_state(
            state.clone(),
            require_management_auth,
        ))
        .with_state(state);

    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let task = tokio::spawn(async move {
        let (stop_tx, stop_rx) = watch::channel(false);
        let mut servers = JoinSet::new();
        servers.spawn(accept_loop(public, public_router, stop_rx.clone(), true));
        servers.spawn(accept_loop(management, management_router, stop_rx, false));
        let early_exit = tokio::select! {
            _ = (&mut shutdown_rx) => None,
            result = servers.join_next() => result,
        };
        let _ = stop_tx.send(true);
        if let Some(result) = early_exit {
            result
                .map_err(|error| GatewayError::Http(format!("listener task failed: {error}")))??;
            servers.abort_all();
            return Err(GatewayError::Http("listener exited unexpectedly".into()));
        }
        let drain = async {
            while let Some(result) = servers.join_next().await {
                result.map_err(|error| {
                    GatewayError::Http(format!("listener task failed: {error}"))
                })??;
            }
            Ok::<(), GatewayError>(())
        };
        match tokio::time::timeout(std::time::Duration::from_secs(5), drain).await {
            Ok(result) => result?,
            Err(_) => {
                servers.abort_all();
                return Err(GatewayError::Http("listener shutdown timed out".into()));
            }
        }
        Ok(())
    });
    Ok(RunningGateway {
        listeners,
        shutdown: Some(shutdown_tx),
        task,
    })
}

async fn accept_loop(
    listener: tokio::net::TcpListener,
    router: Router,
    mut stop: watch::Receiver<bool>,
    capture_header_case: bool,
) -> Result<(), GatewayError> {
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            biased;
            changed = stop.changed() => {
                if changed.is_err() || *stop.borrow() { break; }
            }
            accepted = listener.accept() => {
                let (stream, peer) = accepted?;
                if !peer.ip().is_loopback() {
                    continue;
                }
                let router = router.clone();
                let mut connection_stop = stop.clone();
                connections.spawn(async move {
                    let cases = if capture_header_case {
                        let mut bytes = vec![0u8; 32 * 1_024];
                        stream.peek(&mut bytes).await
                            .ok()
                            .map(|count| OriginalHeaderCases::from_raw_bytes(&bytes[..count]))
                            .unwrap_or_default()
                    } else {
                        OriginalHeaderCases::default()
                    };
                    let service = hyper::service::service_fn(
                        move |request: hyper::Request<hyper::body::Incoming>| {
                            let mut router = router.clone();
                            let cases = cases.clone();
                            async move {
                                let (mut parts, body) = request.into_parts();
                                if capture_header_case {
                                    parts.extensions.insert(cases);
                                }
                                let request = http::Request::from_parts(parts, Body::new(body));
                                Service::call(&mut router, request).await
                            }
                        },
                    );
                    let connection = hyper::server::conn::http1::Builder::new()
                        .preserve_header_case(true)
                        .serve_connection(TokioIo::new(stream), service);
                    tokio::pin!(connection);
                    tokio::select! {
                        _ = &mut connection => {},
                        changed = connection_stop.changed() => {
                            if changed.is_ok() && *connection_stop.borrow() {
                                connection.as_mut().graceful_shutdown();
                                let _ = connection.await;
                            }
                        }
                    }
                });
            }
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
    drop(listener);
    let drain = async { while connections.join_next().await.is_some() {} };
    if tokio::time::timeout(std::time::Duration::from_secs(5), drain)
        .await
        .is_err()
    {
        connections.abort_all();
    }
    Ok(())
}

async fn public_entry(State(state): State<Arc<GatewayState>>, request: Request) -> Response {
    handle_inference(state, request).await
}

async fn require_management_auth(
    State(state): State<Arc<GatewayState>>,
    request: Request,
    next: Next,
) -> Response {
    if !management_authorized(request.headers(), &state.config.management) {
        return Response::builder()
            .status(StatusCode::UNAUTHORIZED)
            .header(header::WWW_AUTHENTICATE, "Bearer realm=\"ccbud-gateway\"")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({"error":{"type":"authentication_error","message":"management authentication required"}})
                    .to_string(),
            ))
            .unwrap();
    }
    next.run(request).await
}

async fn health() -> Json<serde_json::Value> {
    Json(json!({"status":"ok"}))
}

async fn status(State(state): State<Arc<GatewayState>>) -> Json<serde_json::Value> {
    Json(serde_json::to_value(state.status().await).unwrap_or_else(|_| json!({})))
}

#[derive(Debug, Deserialize)]
struct LogQuery {
    limit: Option<usize>,
    before: Option<u64>,
}

async fn log_list(
    State(state): State<Arc<GatewayState>>,
    Query(query): Query<LogQuery>,
) -> Json<serde_json::Value> {
    let records = state
        .monitor
        .list(query.limit.unwrap_or(100), query.before)
        .await;
    Json(json!({"data":records}))
}

async fn log_detail(State(state): State<Arc<GatewayState>>, Path(id): Path<u64>) -> Response {
    match state.monitor.detail(id).await {
        Some(record) => Json(record).into_response(),
        None => Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({"error":{"message":"log not found"}}).to_string(),
            ))
            .unwrap(),
    }
}

async fn log_clear(State(state): State<Arc<GatewayState>>) -> Json<serde_json::Value> {
    Json(json!({"cleared":state.monitor.clear().await}))
}

async fn management_not_found(method: Method) -> Response {
    Response::builder()
        .status(StatusCode::NOT_FOUND)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({"error":{"message":format!("unknown management route for {method}")}})
                .to_string(),
        ))
        .unwrap()
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {},
            _ = terminate.recv() => {},
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

trait IntoResponse {
    fn into_response(self) -> Response;
}

impl<T: Serialize> IntoResponse for Json<T> {
    fn into_response(self) -> Response {
        axum::response::IntoResponse::into_response(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{
        CircuitConfig, FailoverConfig, ManagementConfig, ProviderConfig, RetryConfig, WireProtocol,
    };
    use std::collections::HashMap;
    use std::net::SocketAddr;

    fn config() -> GatewayConfig {
        GatewayConfig {
            public_port: 0,
            management: ManagementConfig {
                port: 0,
                bearer_token: Some("0123456789abcdef0123456789abcdef".into()),
                basic: None,
            },
            require_token: false,
            gateway_token: String::new(),
            active_provider_id: Some("one".into()),
            providers: vec![ProviderConfig {
                id: "one".into(),
                name: "One".into(),
                base_url: "http://127.0.0.1:9".into(),
                auth_token: String::new(),
                default_model: "model".into(),
                small_fast_model: String::new(),
                map_default_models: true,
                protocol: WireProtocol::Anthropic,
                models: vec![],
                enabled: true,
                headers: HashMap::new(),
                timeout_seconds: 1,
            }],
            failover: FailoverConfig::default(),
            retry: RetryConfig::default(),
            circuit_breaker: CircuitConfig::default(),
            monitor_capacity: 16,
            request_body_limit_bytes: 1024,
            response_body_limit_bytes: 1024,
            streaming_first_byte_timeout: 60,
            streaming_idle_timeout: 120,
            insecure_skip_verify: false,
        }
    }

    #[tokio::test]
    async fn binds_both_listeners_to_loopback_and_protects_health() {
        let running = start(config()).await.unwrap();
        let public = SocketAddr::from((Ipv4Addr::LOCALHOST, running.listeners.public_port));
        let management = SocketAddr::from((Ipv4Addr::LOCALHOST, running.listeners.management_port));
        assert!(public.ip().is_loopback());
        assert!(management.ip().is_loopback());
        let client = reqwest::Client::new();
        let unauthorized = client
            .get(format!("http://{management}/health"))
            .send()
            .await
            .unwrap();
        assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);
        let authorized = client
            .get(format!("http://{management}/health"))
            .bearer_auth("0123456789abcdef0123456789abcdef")
            .send()
            .await
            .unwrap();
        assert_eq!(authorized.status(), StatusCode::OK);
        running.shutdown().await.unwrap();
    }
}
