//! Ordered provider selection backed by one circuit breaker per provider ID.

use crate::circuit_breaker::{
    CircuitBreaker, CircuitBreakerConfig, CircuitBreakerStats, CircuitPermit,
};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Persistent router state shared by all requests.
///
/// Provider details deliberately live outside this type.  The config/forwarder
/// layer supplies its ordered IDs and performs the ID -> ProviderConfig lookup;
/// this keeps health state independent from credentials and hot config reloads.
pub struct ProviderRouter {
    default_breaker_config: RwLock<CircuitBreakerConfig>,
    breakers: RwLock<HashMap<String, Arc<CircuitBreaker>>>,
}

impl ProviderRouter {
    pub fn new(default_breaker_config: CircuitBreakerConfig) -> Self {
        Self {
            default_breaker_config: RwLock::new(default_breaker_config),
            breakers: RwLock::new(HashMap::new()),
        }
    }

    /// Select the first currently permitted provider in configuration order.
    pub async fn select(&self, ordered_provider_ids: &[String]) -> Option<RouteSelection> {
        self.select_from(ordered_provider_ids, 0).await
    }

    /// Continue an attempt chain at `start_index`.
    ///
    /// The returned selection exposes `next_index()`, allowing a forwarder to
    /// fail one provider and continue without retrying it:
    ///
    /// ```ignore
    /// let mut cursor = 0;
    /// while let Some(route) = router.select_from(&provider_ids, cursor).await {
    ///     cursor = route.next_index();
    ///     // forward, then route.success().await or route.failure().await
    /// }
    /// ```
    pub async fn select_from(
        &self,
        ordered_provider_ids: &[String],
        start_index: usize,
    ) -> Option<RouteSelection> {
        if start_index >= ordered_provider_ids.len() {
            return None;
        }

        // Treat duplicate IDs as one route.  Seed with prior entries so a
        // caller advancing through the list cannot hit the same provider twice.
        let mut seen: HashSet<&str> = ordered_provider_ids[..start_index]
            .iter()
            .map(String::as_str)
            .collect();

        for (index, provider_id) in ordered_provider_ids.iter().enumerate().skip(start_index) {
            if provider_id.trim().is_empty() || !seen.insert(provider_id.as_str()) {
                continue;
            }

            let breaker = self.breaker_for(provider_id).await;
            if let Some(permit) = breaker.try_acquire().await {
                return Some(RouteSelection {
                    provider_id: provider_id.clone(),
                    index,
                    permit,
                });
            }
        }

        None
    }

    /// Apply a new default to both future and already-observed providers.
    pub async fn update_breaker_config(&self, config: CircuitBreakerConfig) {
        *self.default_breaker_config.write().await = config;
        let breakers: Vec<Arc<CircuitBreaker>> =
            self.breakers.read().await.values().cloned().collect();
        for breaker in breakers {
            breaker.update_config(config).await;
        }
    }

    pub async fn reset(&self, provider_id: &str) {
        if let Some(breaker) = self.breakers.read().await.get(provider_id).cloned() {
            breaker.reset().await;
        }
    }

    /// Returns `None` until the provider has participated in routing.
    pub async fn stats(&self, provider_id: &str) -> Option<CircuitBreakerStats> {
        let breaker = self.breakers.read().await.get(provider_id).cloned();
        match breaker {
            Some(breaker) => Some(breaker.stats().await),
            None => None,
        }
    }

    async fn breaker_for(&self, provider_id: &str) -> Arc<CircuitBreaker> {
        if let Some(breaker) = self.breakers.read().await.get(provider_id).cloned() {
            return breaker;
        }

        let config = *self.default_breaker_config.read().await;
        let mut breakers = self.breakers.write().await;
        breakers
            .entry(provider_id.to_string())
            .or_insert_with(|| CircuitBreaker::shared(config))
            .clone()
    }
}

impl Default for ProviderRouter {
    fn default() -> Self {
        Self::new(CircuitBreakerConfig::default())
    }
}

/// One acquired provider route.
///
/// Dropping this value before recording a result is neutral.  In particular,
/// it safely releases an in-flight half-open probe permit.
pub struct RouteSelection {
    provider_id: String,
    index: usize,
    permit: CircuitPermit,
}

impl RouteSelection {
    pub fn provider_id(&self) -> &str {
        &self.provider_id
    }

    pub fn index(&self) -> usize {
        self.index
    }

    pub fn next_index(&self) -> usize {
        self.index.saturating_add(1)
    }

    pub fn is_half_open_probe(&self) -> bool {
        self.permit.is_half_open_probe()
    }

    pub async fn success(self) {
        self.permit.success().await;
    }

    pub async fn failure(self) {
        self.permit.failure().await;
    }

    pub fn release_neutral(self) {
        self.permit.release_neutral();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::circuit_breaker::CircuitState;

    fn ids(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    fn config(timeout_seconds: u64) -> CircuitBreakerConfig {
        CircuitBreakerConfig {
            failure_threshold: 1,
            success_threshold: 1,
            timeout_seconds,
            error_rate_threshold: 1.0,
            min_requests: 100,
        }
    }

    #[tokio::test]
    async fn preserves_configured_order() {
        let router = ProviderRouter::new(config(60));
        let ordered = ids(&["provider-b", "provider-a", "provider-c"]);

        let route = router.select(&ordered).await.unwrap();
        assert_eq!(route.provider_id(), "provider-b");
        assert_eq!(route.next_index(), 1);
        route.success().await;
    }

    #[tokio::test]
    async fn skips_open_provider_and_continues_at_next_id() {
        let router = ProviderRouter::new(config(60));
        let ordered = ids(&["primary", "secondary"]);

        router.select(&ordered).await.unwrap().failure().await;
        assert_eq!(
            router.stats("primary").await.unwrap().state,
            CircuitState::Open
        );

        let route = router.select(&ordered).await.unwrap();
        assert_eq!(route.provider_id(), "secondary");
        route.success().await;
    }

    #[tokio::test]
    async fn advancing_cursor_never_retries_duplicate_provider_id() {
        let router = ProviderRouter::new(config(60));
        let ordered = ids(&["primary", "primary", "secondary"]);

        let first = router.select(&ordered).await.unwrap();
        let cursor = first.next_index();
        first.failure().await;

        let next = router.select_from(&ordered, cursor).await.unwrap();
        assert_eq!(next.provider_id(), "secondary");
        assert_eq!(next.index(), 2);
        next.success().await;
    }

    #[tokio::test]
    async fn half_open_probe_is_single_flight_at_router_boundary() {
        let router = ProviderRouter::new(config(0));
        let ordered = ids(&["primary"]);

        router.select(&ordered).await.unwrap().failure().await;
        let probe = router.select(&ordered).await.expect("first recovery probe");
        assert!(probe.is_half_open_probe());
        assert!(router.select(&ordered).await.is_none());

        probe.success().await;
        let normal = router.select(&ordered).await.expect("closed circuit route");
        assert!(!normal.is_half_open_probe());
        normal.success().await;
    }

    #[tokio::test]
    async fn empty_and_duplicate_ids_do_not_change_priority() {
        let router = ProviderRouter::new(config(60));
        let ordered = ids(&["", "alpha", "alpha", "beta"]);

        let route = router.select(&ordered).await.unwrap();
        assert_eq!(route.provider_id(), "alpha");
        route.success().await;
    }
}
