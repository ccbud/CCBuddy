//! Retry classification and bounded delay calculation.

use http::StatusCode;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Forwarders map their concrete transport error into this small, dependency-
/// free classification.  TLS/configuration/protocol errors must use
/// `NonRetryable`; only errors known to be temporary use `TransientNetwork`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RetryClass {
    HttpStatus(StatusCode),
    TransientNetwork,
    NonRetryable,
}

impl RetryClass {
    pub fn from_status(status: StatusCode) -> Self {
        Self::HttpStatus(status)
    }

    pub fn is_retryable(self) -> bool {
        match self {
            Self::HttpStatus(status) => is_retryable_status(status),
            Self::TransientNetwork => true,
            Self::NonRetryable => false,
        }
    }
}

/// Only statuses that are safe candidates for transient retry/failover.
pub fn is_retryable_status(status: StatusCode) -> bool {
    matches!(status.as_u16(), 408 | 409 | 425 | 429) || status.is_server_error()
}

/// Statuses for which another provider may succeed even when retrying the same provider would not
/// help. This mirrors cc-switch's provider-failover buckets: request-shape errors stay with the
/// client, while credentials, quota, region, model availability, redirects, and server failures
/// may differ between providers.
pub fn is_failover_status(status: StatusCode) -> bool {
    !status.is_success()
        && !matches!(
            status.as_u16(),
            400 | 405 | 406 | 413 | 414 | 415 | 422 | 501
        )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RetryPolicy {
    /// Number of retries after the initial attempt.
    pub max_retries: u32,
    /// Delay before the first retry.
    pub base_delay: Duration,
    /// Upper bound for exponential backoff.
    pub max_delay: Duration,
    /// Independent upper bound for an upstream `Retry-After` value.
    pub max_retry_after: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_retries: 3,
            base_delay: Duration::from_millis(500),
            max_delay: Duration::from_secs(8),
            max_retry_after: Duration::from_secs(30),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RetryDecision {
    /// One-based retry number (`1` is the first retry after the initial call).
    pub retry_number: u32,
    pub delay: Duration,
}

impl RetryPolicy {
    /// Decide whether to retry after the latest failed attempt.
    ///
    /// `retries_so_far` excludes the initial request.  Pass `0` after the
    /// initial failure, `1` after the first retry fails, and so on.
    pub fn decision(
        &self,
        retries_so_far: u32,
        class: RetryClass,
        retry_after: Option<&str>,
        now: SystemTime,
    ) -> Option<RetryDecision> {
        if retries_so_far >= self.max_retries || !class.is_retryable() {
            return None;
        }

        let delay = retry_after
            .and_then(|value| parse_retry_after(value, now, self.max_retry_after))
            .unwrap_or_else(|| self.backoff_delay(retries_so_far));
        Some(RetryDecision {
            retry_number: retries_so_far.saturating_add(1),
            delay,
        })
    }

    /// Deterministic exponential backoff.  The first retry uses `base_delay`.
    pub fn backoff_delay(&self, retries_so_far: u32) -> Duration {
        let exponent = retries_so_far.min(31);
        let multiplier = 1u32 << exponent;
        self.base_delay
            .saturating_mul(multiplier)
            .min(self.max_delay)
    }
}

/// Parse either Retry-After's delta-seconds form or its IMF-fixdate form.
/// Returned delays are always capped, including maliciously large values.
pub fn parse_retry_after(value: &str, now: SystemTime, max_delay: Duration) -> Option<Duration> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }

    if let Ok(seconds) = value.parse::<u64>() {
        return Some(Duration::from_secs(seconds).min(max_delay));
    }

    let target_seconds = parse_imf_fixdate_epoch_seconds(value)?;
    let now_seconds = now.duration_since(UNIX_EPOCH).ok()?.as_secs();
    Some(Duration::from_secs(target_seconds.saturating_sub(now_seconds)).min(max_delay))
}

/// RFC 7231's preferred HTTP-date representation: `Sun, 06 Nov 1994 08:49:37 GMT`.
/// A small parser avoids coupling the retry core to chrono/httpdate.
fn parse_imf_fixdate_epoch_seconds(value: &str) -> Option<u64> {
    let parts: Vec<&str> = value.split_ascii_whitespace().collect();
    if parts.len() != 6
        || parts[0].len() != 4
        || !parts[0].ends_with(',')
        || !parts[5].eq_ignore_ascii_case("GMT")
    {
        return None;
    }

    let day = parts[1].parse::<u32>().ok()?;
    let month = match parts[2].to_ascii_lowercase().as_str() {
        "jan" => 1,
        "feb" => 2,
        "mar" => 3,
        "apr" => 4,
        "may" => 5,
        "jun" => 6,
        "jul" => 7,
        "aug" => 8,
        "sep" => 9,
        "oct" => 10,
        "nov" => 11,
        "dec" => 12,
        _ => return None,
    };
    let year = parts[3].parse::<i32>().ok()?;
    if year < 1970 || day == 0 || day > days_in_month(year, month) {
        return None;
    }

    let mut time = parts[4].split(':');
    let hour = time.next()?.parse::<u32>().ok()?;
    let minute = time.next()?.parse::<u32>().ok()?;
    let second = time.next()?.parse::<u32>().ok()?;
    if time.next().is_some() || hour > 23 || minute > 59 || second > 59 {
        return None;
    }

    let days = days_since_unix_epoch(year, month, day)?;
    days.checked_mul(86_400)?
        .checked_add(u64::from(hour) * 3_600)?
        .checked_add(u64::from(minute) * 60)?
        .checked_add(u64::from(second))
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap_year(year) => 29,
        2 => 28,
        _ => 0,
    }
}

fn is_leap_year(year: i32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

/// Howard Hinnant's civil-date conversion, shifted to Unix epoch day zero.
fn days_since_unix_epoch(year: i32, month: u32, day: u32) -> Option<u64> {
    let adjusted_year = year - i32::from(month <= 2);
    let era = if adjusted_year >= 0 {
        adjusted_year
    } else {
        adjusted_year - 399
    } / 400;
    let year_of_era = adjusted_year - era * 400;
    let month_prime = i32::try_from(month).ok()? + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * month_prime + 2) / 5 + i32::try_from(day).ok()? - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let unix_days = era * 146_097 + day_of_era - 719_468;
    u64::try_from(unix_days).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retries_only_explicit_transient_statuses() {
        for code in [408, 409, 425, 429, 500, 502, 503, 599] {
            assert!(
                is_retryable_status(StatusCode::from_u16(code).unwrap()),
                "{code}"
            );
        }
        for code in [200, 301, 400, 401, 404, 422, 499] {
            assert!(
                !is_retryable_status(StatusCode::from_u16(code).unwrap()),
                "{code}"
            );
        }
    }

    #[test]
    fn failover_includes_provider_specific_client_errors() {
        for code in [301, 401, 403, 404, 408, 409, 425, 429, 451, 500, 503] {
            assert!(
                is_failover_status(StatusCode::from_u16(code).unwrap()),
                "{code}"
            );
        }
        for code in [200, 400, 405, 406, 413, 414, 415, 422, 501] {
            assert!(
                !is_failover_status(StatusCode::from_u16(code).unwrap()),
                "{code}"
            );
        }
    }

    #[test]
    fn retries_only_network_errors_classified_as_transient() {
        assert!(RetryClass::TransientNetwork.is_retryable());
        assert!(!RetryClass::NonRetryable.is_retryable());
    }

    #[test]
    fn exponential_backoff_is_bounded() {
        let policy = RetryPolicy {
            max_retries: 20,
            base_delay: Duration::from_millis(250),
            max_delay: Duration::from_secs(2),
            max_retry_after: Duration::from_secs(30),
        };
        assert_eq!(policy.backoff_delay(0), Duration::from_millis(250));
        assert_eq!(policy.backoff_delay(1), Duration::from_millis(500));
        assert_eq!(policy.backoff_delay(2), Duration::from_secs(1));
        assert_eq!(policy.backoff_delay(3), Duration::from_secs(2));
        assert_eq!(policy.backoff_delay(19), Duration::from_secs(2));
    }

    #[test]
    fn retry_budget_counts_retries_not_initial_attempt() {
        let policy = RetryPolicy {
            max_retries: 2,
            ..RetryPolicy::default()
        };
        let now = SystemTime::now();
        assert_eq!(
            policy
                .decision(0, RetryClass::TransientNetwork, None, now)
                .unwrap()
                .retry_number,
            1
        );
        assert_eq!(
            policy
                .decision(1, RetryClass::TransientNetwork, None, now)
                .unwrap()
                .retry_number,
            2
        );
        assert!(policy
            .decision(2, RetryClass::TransientNetwork, None, now)
            .is_none());
        assert!(policy
            .decision(0, RetryClass::NonRetryable, None, now)
            .is_none());
    }

    #[test]
    fn retry_after_delta_seconds_is_honored_and_capped() {
        let now = UNIX_EPOCH + Duration::from_secs(1_000);
        assert_eq!(
            parse_retry_after("7", now, Duration::from_secs(30)),
            Some(Duration::from_secs(7))
        );
        assert_eq!(
            parse_retry_after("999999", now, Duration::from_secs(30)),
            Some(Duration::from_secs(30))
        );
    }

    #[test]
    fn retry_after_http_date_is_honored_and_past_dates_are_immediate() {
        let base = parse_imf_fixdate_epoch_seconds("Mon, 24 Aug 2026 00:00:00 GMT").unwrap();
        let now = UNIX_EPOCH + Duration::from_secs(base);
        assert_eq!(
            parse_retry_after(
                "Mon, 24 Aug 2026 00:00:10 GMT",
                now,
                Duration::from_secs(30)
            ),
            Some(Duration::from_secs(10))
        );
        assert_eq!(
            parse_retry_after(
                "Sun, 23 Aug 2026 23:59:59 GMT",
                now,
                Duration::from_secs(30)
            ),
            Some(Duration::ZERO)
        );
    }

    #[test]
    fn invalid_retry_after_falls_back_to_exponential_delay() {
        let policy = RetryPolicy::default();
        let decision = policy
            .decision(
                0,
                RetryClass::from_status(StatusCode::TOO_MANY_REQUESTS),
                Some("not-a-date"),
                SystemTime::now(),
            )
            .unwrap();
        assert_eq!(decision.delay, policy.base_delay);
    }
}
