use crate::circuit_breaker::CircuitBreakerConfig;
use crate::config::GatewayConfig;
use crate::monitor::MonitorStore;
use crate::protocol::codex_history::CodexHistoryStore;
use crate::routing::ProviderRouter;
use serde::Serialize;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

pub struct GatewayState {
    pub config: Arc<GatewayConfig>,
    pub router: ProviderRouter,
    pub monitor: MonitorStore,
    pub history: CodexHistoryStore,
    started: Instant,
    public_port: AtomicU32,
    management_port: AtomicU32,
    active_connections: AtomicU64,
    total_requests: AtomicU64,
    successful_requests: AtomicU64,
    failed_requests: AtomicU64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStatus {
    pub running: bool,
    pub public_port: u16,
    pub management_port: u16,
    pub uptime_seconds: u64,
    pub active_connections: u64,
    pub total_requests: u64,
    pub successful_requests: u64,
    pub failed_requests: u64,
    pub providers: Vec<ProviderStatus>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderStatus {
    pub id: String,
    pub name: String,
    pub circuit: Option<crate::circuit_breaker::CircuitBreakerStats>,
}

impl GatewayState {
    pub fn new(config: GatewayConfig) -> Arc<Self> {
        let circuit = CircuitBreakerConfig {
            failure_threshold: config.circuit_breaker.failure_threshold,
            success_threshold: config.circuit_breaker.success_threshold,
            timeout_seconds: config.circuit_breaker.timeout_seconds,
            error_rate_threshold: config.circuit_breaker.error_rate_threshold,
            min_requests: config.circuit_breaker.min_requests,
        };
        Arc::new(Self {
            monitor: MonitorStore::new(config.monitor_capacity),
            config: Arc::new(config),
            router: ProviderRouter::new(circuit),
            history: CodexHistoryStore::default(),
            started: Instant::now(),
            public_port: AtomicU32::new(0),
            management_port: AtomicU32::new(0),
            active_connections: AtomicU64::new(0),
            total_requests: AtomicU64::new(0),
            successful_requests: AtomicU64::new(0),
            failed_requests: AtomicU64::new(0),
        })
    }

    pub fn set_bound_ports(&self, public: u16, management: u16) {
        self.public_port.store(u32::from(public), Ordering::Release);
        self.management_port
            .store(u32::from(management), Ordering::Release);
    }

    pub fn begin_request(self: &Arc<Self>) -> RequestGuard {
        self.active_connections.fetch_add(1, Ordering::Relaxed);
        self.total_requests.fetch_add(1, Ordering::Relaxed);
        RequestGuard {
            state: self.clone(),
            outcome: None,
        }
    }

    pub async fn status(&self) -> GatewayStatus {
        let mut providers = Vec::with_capacity(self.config.providers.len());
        for provider in &self.config.providers {
            providers.push(ProviderStatus {
                id: provider.id.clone(),
                name: provider.name.clone(),
                circuit: self.router.stats(&provider.id).await,
            });
        }
        let public_port = self.public_port.load(Ordering::Acquire) as u16;
        let management_port = self.management_port.load(Ordering::Acquire) as u16;
        GatewayStatus {
            running: public_port != 0 && management_port != 0,
            public_port,
            management_port,
            uptime_seconds: self.started.elapsed().as_secs(),
            active_connections: self.active_connections.load(Ordering::Relaxed),
            total_requests: self.total_requests.load(Ordering::Relaxed),
            successful_requests: self.successful_requests.load(Ordering::Relaxed),
            failed_requests: self.failed_requests.load(Ordering::Relaxed),
            providers,
        }
    }
}

pub struct RequestGuard {
    state: Arc<GatewayState>,
    outcome: Option<bool>,
}

impl RequestGuard {
    pub fn success(&mut self) {
        self.outcome = Some(true);
    }
    pub fn failure(&mut self) {
        self.outcome = Some(false);
    }
}

impl Drop for RequestGuard {
    fn drop(&mut self) {
        self.state
            .active_connections
            .fetch_sub(1, Ordering::Relaxed);
        match self.outcome {
            Some(true) => {
                self.state
                    .successful_requests
                    .fetch_add(1, Ordering::Relaxed);
            }
            Some(false) | None => {
                self.state.failed_requests.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}
