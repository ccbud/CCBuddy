//! Per-provider circuit breaker used by the headless gateway.
//!
//! The state machine follows cc-switch's `Closed -> Open -> HalfOpen` model.  An
//! open circuit becomes half-open after its recovery timeout, and exactly one
//! probe may be in flight while half-open.  The probe is represented by an RAII
//! permit so cancellation cannot permanently consume that slot.

use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CircuitState {
    Closed,
    Open,
    HalfOpen,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CircuitBreakerConfig {
    /// Consecutive failures required to open a closed circuit.
    pub failure_threshold: u32,
    /// Successful half-open probes required to close the circuit.
    pub success_threshold: u32,
    /// Seconds an open circuit remains unavailable before allowing a probe.
    pub timeout_seconds: u64,
    /// Rolling error-rate threshold, in the inclusive range `0.0..=1.0`.
    pub error_rate_threshold: f64,
    /// Minimum observations before the error-rate threshold is considered.
    pub min_requests: u32,
}

impl Default for CircuitBreakerConfig {
    fn default() -> Self {
        Self {
            failure_threshold: 4,
            success_threshold: 2,
            timeout_seconds: 60,
            error_rate_threshold: 0.6,
            min_requests: 10,
        }
    }
}

impl CircuitBreakerConfig {
    fn normalized(self) -> Self {
        Self {
            failure_threshold: self.failure_threshold.max(1),
            success_threshold: self.success_threshold.max(1),
            timeout_seconds: self.timeout_seconds,
            error_rate_threshold: if self.error_rate_threshold.is_finite() {
                self.error_rate_threshold.clamp(0.0, 1.0)
            } else {
                Self::default().error_rate_threshold
            },
            min_requests: self.min_requests.max(1),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CircuitBreakerStats {
    pub state: CircuitState,
    pub consecutive_failures: u32,
    pub consecutive_successes: u32,
    pub total_requests: u64,
    pub failed_requests: u64,
    pub half_open_probe_in_flight: bool,
}

#[derive(Debug)]
struct Inner {
    config: CircuitBreakerConfig,
    state: CircuitState,
    consecutive_failures: u32,
    consecutive_successes: u32,
    total_requests: u64,
    failed_requests: u64,
    opened_at: Option<Instant>,
}

/// Thread-safe state for one provider.
pub struct CircuitBreaker {
    inner: Mutex<Inner>,
    // Kept outside the async mutex so a dropped/cancelled permit can release it
    // synchronously from `Drop`.
    half_open_probe_in_flight: AtomicBool,
}

impl CircuitBreaker {
    pub fn new(config: CircuitBreakerConfig) -> Self {
        Self {
            inner: Mutex::new(Inner {
                config: config.normalized(),
                state: CircuitState::Closed,
                consecutive_failures: 0,
                consecutive_successes: 0,
                total_requests: 0,
                failed_requests: 0,
                opened_at: None,
            }),
            half_open_probe_in_flight: AtomicBool::new(false),
        }
    }

    pub fn shared(config: CircuitBreakerConfig) -> Arc<Self> {
        Arc::new(Self::new(config))
    }

    /// Acquire permission for one upstream request.
    ///
    /// `None` means the provider must be skipped.  A returned permit must be
    /// completed with `success` or `failure`; dropping it is treated neutrally
    /// and only releases a half-open probe slot.
    pub async fn try_acquire(self: &Arc<Self>) -> Option<CircuitPermit> {
        let mut inner = self.inner.lock().await;

        if inner.state == CircuitState::Open {
            let timeout = Duration::from_secs(inner.config.timeout_seconds);
            let recovered = inner
                .opened_at
                .is_some_and(|opened_at| opened_at.elapsed() >= timeout);
            if !recovered {
                return None;
            }
            inner.state = CircuitState::HalfOpen;
            inner.consecutive_successes = 0;
            self.half_open_probe_in_flight
                .store(false, Ordering::Release);
        }

        let is_half_open_probe = match inner.state {
            CircuitState::Closed => false,
            CircuitState::Open => return None,
            CircuitState::HalfOpen => {
                if self
                    .half_open_probe_in_flight
                    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
                {
                    return None;
                }
                true
            }
        };

        Some(CircuitPermit {
            breaker: self.clone(),
            is_half_open_probe,
            resolved: false,
        })
    }

    pub async fn state(&self) -> CircuitState {
        self.inner.lock().await.state
    }

    pub async fn config(&self) -> CircuitBreakerConfig {
        self.inner.lock().await.config
    }

    /// Change thresholds without discarding live health state.
    pub async fn update_config(&self, config: CircuitBreakerConfig) {
        self.inner.lock().await.config = config.normalized();
    }

    pub async fn stats(&self) -> CircuitBreakerStats {
        let inner = self.inner.lock().await;
        CircuitBreakerStats {
            state: inner.state,
            consecutive_failures: inner.consecutive_failures,
            consecutive_successes: inner.consecutive_successes,
            total_requests: inner.total_requests,
            failed_requests: inner.failed_requests,
            half_open_probe_in_flight: self.half_open_probe_in_flight.load(Ordering::Acquire),
        }
    }

    pub async fn reset(&self) {
        let mut inner = self.inner.lock().await;
        Self::transition_to_closed(&mut inner);
        self.half_open_probe_in_flight
            .store(false, Ordering::Release);
    }

    async fn record_success(&self, is_half_open_probe: bool) {
        let mut inner = self.inner.lock().await;
        inner.total_requests = inner.total_requests.saturating_add(1);
        inner.consecutive_failures = 0;

        if inner.state == CircuitState::HalfOpen && is_half_open_probe {
            inner.consecutive_successes = inner.consecutive_successes.saturating_add(1);
            if inner.consecutive_successes >= inner.config.success_threshold {
                Self::transition_to_closed(&mut inner);
            }
        }

        if is_half_open_probe {
            self.half_open_probe_in_flight
                .store(false, Ordering::Release);
        }
    }

    async fn record_failure(&self, is_half_open_probe: bool) {
        let mut inner = self.inner.lock().await;
        inner.total_requests = inner.total_requests.saturating_add(1);
        inner.failed_requests = inner.failed_requests.saturating_add(1);
        inner.consecutive_failures = inner.consecutive_failures.saturating_add(1);
        inner.consecutive_successes = 0;

        match inner.state {
            CircuitState::HalfOpen if is_half_open_probe => {
                Self::transition_to_open(&mut inner);
            }
            CircuitState::Closed => {
                let reached_failure_threshold =
                    inner.consecutive_failures >= inner.config.failure_threshold;
                let reached_error_rate = inner.total_requests
                    >= u64::from(inner.config.min_requests)
                    && (inner.failed_requests as f64 / inner.total_requests as f64)
                        >= inner.config.error_rate_threshold;
                if reached_failure_threshold || reached_error_rate {
                    Self::transition_to_open(&mut inner);
                }
            }
            CircuitState::Open | CircuitState::HalfOpen => {}
        }

        if is_half_open_probe {
            self.half_open_probe_in_flight
                .store(false, Ordering::Release);
        }
    }

    fn transition_to_open(inner: &mut Inner) {
        inner.state = CircuitState::Open;
        inner.opened_at = Some(Instant::now());
        inner.consecutive_failures = 0;
        inner.consecutive_successes = 0;
    }

    fn transition_to_closed(inner: &mut Inner) {
        inner.state = CircuitState::Closed;
        inner.opened_at = None;
        inner.consecutive_failures = 0;
        inner.consecutive_successes = 0;
        inner.total_requests = 0;
        inner.failed_requests = 0;
    }

    fn release_half_open_probe(&self) {
        self.half_open_probe_in_flight
            .store(false, Ordering::Release);
    }
}

/// Permission for one provider request.
///
/// It deliberately owns an `Arc<CircuitBreaker>` so it remains valid if a
/// config reload removes the provider from the router while a request is live.
pub struct CircuitPermit {
    breaker: Arc<CircuitBreaker>,
    is_half_open_probe: bool,
    resolved: bool,
}

impl CircuitPermit {
    pub fn is_half_open_probe(&self) -> bool {
        self.is_half_open_probe
    }

    pub async fn success(mut self) {
        self.breaker.record_success(self.is_half_open_probe).await;
        self.resolved = true;
    }

    pub async fn failure(mut self) {
        self.breaker.record_failure(self.is_half_open_probe).await;
        self.resolved = true;
    }

    /// Release a half-open slot without changing provider health.
    pub fn release_neutral(mut self) {
        if self.is_half_open_probe {
            self.breaker.release_half_open_probe();
        }
        self.resolved = true;
    }
}

impl Drop for CircuitPermit {
    fn drop(&mut self) {
        if !self.resolved && self.is_half_open_probe {
            self.breaker.release_half_open_probe();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn immediate_config() -> CircuitBreakerConfig {
        CircuitBreakerConfig {
            failure_threshold: 2,
            success_threshold: 2,
            timeout_seconds: 0,
            error_rate_threshold: 1.0,
            min_requests: 100,
        }
    }

    #[tokio::test]
    async fn opens_at_failure_threshold() {
        let breaker = CircuitBreaker::shared(immediate_config());

        breaker.try_acquire().await.unwrap().failure().await;
        assert_eq!(breaker.state().await, CircuitState::Closed);
        breaker.try_acquire().await.unwrap().failure().await;
        assert_eq!(breaker.state().await, CircuitState::Open);
    }

    #[tokio::test]
    async fn open_circuit_blocks_until_recovery_timeout() {
        let mut config = immediate_config();
        config.failure_threshold = 1;
        config.timeout_seconds = 60;
        let breaker = CircuitBreaker::shared(config);

        breaker.try_acquire().await.unwrap().failure().await;
        assert_eq!(breaker.state().await, CircuitState::Open);
        assert!(breaker.try_acquire().await.is_none());
        assert_eq!(breaker.state().await, CircuitState::Open);
    }

    #[tokio::test]
    async fn half_open_probe_is_single_flight_and_success_recovers() {
        let breaker = CircuitBreaker::shared(immediate_config());
        breaker.try_acquire().await.unwrap().failure().await;
        breaker.try_acquire().await.unwrap().failure().await;

        let first_probe = breaker.try_acquire().await.expect("first probe");
        assert!(first_probe.is_half_open_probe());
        assert!(
            breaker.try_acquire().await.is_none(),
            "probe must be single-flight"
        );
        first_probe.success().await;
        assert_eq!(breaker.state().await, CircuitState::HalfOpen);

        let second_probe = breaker.try_acquire().await.expect("second probe");
        second_probe.success().await;
        assert_eq!(breaker.state().await, CircuitState::Closed);
    }

    #[tokio::test]
    async fn failed_half_open_probe_reopens_circuit() {
        let mut config = immediate_config();
        config.failure_threshold = 1;
        let breaker = CircuitBreaker::shared(config);
        breaker.try_acquire().await.unwrap().failure().await;

        breaker.try_acquire().await.unwrap().failure().await;
        assert_eq!(breaker.state().await, CircuitState::Open);
    }

    #[tokio::test]
    async fn dropped_probe_releases_slot_without_changing_health() {
        let mut config = immediate_config();
        config.failure_threshold = 1;
        let breaker = CircuitBreaker::shared(config);
        breaker.try_acquire().await.unwrap().failure().await;

        let probe = breaker.try_acquire().await.unwrap();
        drop(probe);
        let replacement = breaker.try_acquire().await.expect("replacement probe");
        replacement.release_neutral();

        let stats = breaker.stats().await;
        assert_eq!(stats.state, CircuitState::HalfOpen);
        assert!(!stats.half_open_probe_in_flight);
    }

    #[tokio::test]
    async fn error_rate_can_open_before_consecutive_threshold() {
        let breaker = CircuitBreaker::shared(CircuitBreakerConfig {
            failure_threshold: 100,
            success_threshold: 1,
            timeout_seconds: 60,
            error_rate_threshold: 0.5,
            min_requests: 4,
        });

        breaker.try_acquire().await.unwrap().success().await;
        breaker.try_acquire().await.unwrap().success().await;
        breaker.try_acquire().await.unwrap().failure().await;
        breaker.try_acquire().await.unwrap().failure().await;
        assert_eq!(breaker.state().await, CircuitState::Open);
    }
}
