use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use crate::error::ApiError;
use crate::time::Clock;

#[derive(Clone, Copy, Debug)]
pub enum AuthPolicy {
    PerSession,
    PerOp,
    Ttl(#[allow(dead_code)] Duration),
}

#[derive(Debug, Clone, Copy)]
pub struct AuthStatus {
    pub authorized: bool,
    pub auth_age_ms: Option<u128>,
    pub expires_in_ms: Option<u128>,
}

impl AuthStatus {
    #[allow(dead_code)] // Kept for deferred call sites that build explicit unauthorized snapshots.
    pub fn unauthorized() -> Self {
        Self {
            authorized: false,
            auth_age_ms: None,
            expires_in_ms: None,
        }
    }
}

#[derive(Debug)]
pub enum ProofError {
    MissingField(#[allow(dead_code)] &'static str),
    ClockSkew,
    NonceReplay,
}

// M1.5: Helper for absolute time difference
#[allow(dead_code)] // Used by deferred skew-hardening flow.
fn abs_diff(a: SystemTime, b: SystemTime) -> Duration {
    a.duration_since(b).unwrap_or_else(|e| e.duration())
}

#[derive(Copy, Clone, Debug)]
enum SkewStatus {
    Ok,
    Degraded,
    #[allow(dead_code)] // Reserved for future hard-fail mode
    Deny,
}

pub struct AuthState {
    // M1.5: Clock and TTL config
    clock: Arc<dyn Clock>,
    base_ttl: Duration,
    degraded_ttl: Duration,
    #[allow(dead_code)] // Reserved for future hard-fail skew mode.
    skew_max: Duration,
    skew: SkewStatus,
    is_remote_session: bool,

    // Existing fields
    ttl: Duration,
    max_skew: Duration,
    nonce_ttl: Duration,
    nonce_cache_limit: usize,
    nonces: VecDeque<(String, SystemTime)>,
    auth_ok_until: Option<Instant>,
    last_auth_at: Option<SystemTime>,
    auth_expires_at_wall: Option<SystemTime>,
    last_session_id: Option<String>,
    scope_grants: std::collections::HashMap<String, Instant>,
    pending_scope: Option<(String, Duration)>,
}

impl AuthState {
    pub fn new_with_clock(
        clock: Arc<dyn Clock>,
        base_ttl: Duration,
        degraded_ttl: Duration,
        skew_max_config: Duration,
    ) -> Self {
        Self {
            clock: clock.clone(),
            base_ttl,
            degraded_ttl,
            skew_max: skew_max_config,
            skew: SkewStatus::Ok,
            is_remote_session: false,
            ttl: base_ttl,
            max_skew: Duration::from_secs(60),
            nonce_ttl: base_ttl + Duration::from_secs(30),
            nonce_cache_limit: 128,
            nonces: VecDeque::new(),
            auth_ok_until: None,
            last_auth_at: None,
            auth_expires_at_wall: None,
            last_session_id: None,
            scope_grants: std::collections::HashMap::new(),
            pending_scope: None,
        }
    }

    #[allow(dead_code)] // Used by deferred status/reporting path.
    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    pub fn status(&self) -> AuthStatus {
        let now = Instant::now();
        let authorized = self.auth_ok_until.map(|until| until > now).unwrap_or(false);
        let expires_in_ms = self.auth_expires_at_wall.and_then(|wall| {
            wall.duration_since(SystemTime::now())
                .ok()
                .map(|rem| rem.as_millis())
        });
        let expires_in_ms = expires_in_ms.or_else(|| {
            self.auth_ok_until.and_then(|until| {
                if until > now {
                    Some((until - now).as_millis())
                } else {
                    None
                }
            })
        });
        let auth_age_ms = self
            .last_auth_at
            .and_then(|ts| SystemTime::now().duration_since(ts).ok())
            .map(|d| d.as_millis());
        AuthStatus {
            authorized,
            auth_age_ms,
            expires_in_ms,
        }
    }

    #[allow(dead_code)] // Kept for legacy authorization check callers.
    pub fn is_authorized(&self) -> bool {
        self.status().authorized
    }

    pub fn apply_proof(
        &mut self,
        ts: SystemTime,
        nonce: &str,
        sid: Option<&str>,
    ) -> Result<AuthStatus, ProofError> {
        self.cleanup_nonces(SystemTime::now());
        self.check_skew(ts)?;
        self.check_nonce(nonce, ts)?;
        self.mark_authorized(sid);
        if let Some((scope, ttl)) = self.pending_scope.take() {
            self.set_scope_grant(&scope, ttl);
        }
        Ok(self.status())
    }

    fn check_skew(&self, ts: SystemTime) -> Result<(), ProofError> {
        let now = SystemTime::now();
        if ts > now {
            let ahead = ts.duration_since(now).unwrap_or(Duration::from_secs(0));
            if ahead > self.max_skew {
                return Err(ProofError::ClockSkew);
            }
        } else {
            let behind = now.duration_since(ts).unwrap_or(Duration::from_secs(0));
            if behind > self.max_skew {
                return Err(ProofError::ClockSkew);
            }
        }
        Ok(())
    }

    fn check_nonce(&mut self, nonce: &str, ts: SystemTime) -> Result<(), ProofError> {
        if nonce.is_empty() {
            return Err(ProofError::MissingField("nonce_b64"));
        }
        if self.nonces.iter().any(|(n, _)| n == nonce) {
            return Err(ProofError::NonceReplay);
        }
        self.nonces.push_back((nonce.to_string(), ts));
        while self.nonces.len() > self.nonce_cache_limit {
            self.nonces.pop_front();
        }
        Ok(())
    }

    fn cleanup_nonces(&mut self, now: SystemTime) {
        while let Some((_, ts)) = self.nonces.front() {
            if now
                .duration_since(*ts)
                .map(|d| d > self.nonce_ttl)
                .unwrap_or(false)
            {
                self.nonces.pop_front();
            } else {
                break;
            }
        }
    }

    fn mark_authorized(&mut self, sid: Option<&str>) {
        let now = Instant::now();
        let wall = SystemTime::now();
        self.auth_ok_until = Some(now + self.ttl);
        self.last_auth_at = Some(wall);
        self.auth_expires_at_wall = Some(wall + self.ttl);
        if let Some(sid) = sid {
            self.last_session_id = Some(sid.to_string());
        }
    }

    pub fn expires_at_unix(&self) -> Option<u64> {
        self.auth_expires_at_wall.and_then(|wall| {
            wall.duration_since(SystemTime::UNIX_EPOCH)
                .ok()
                .map(|d| d.as_secs())
        })
    }

    pub fn session_matches(&self, sid: Option<&str>) -> bool {
        match (sid, &self.last_session_id) {
            (Some(s), Some(last)) => s == last,
            (None, Some(_)) => false,
            (_, None) => false,
        }
    }

    /// Returns true if a scoped grant is still valid for the given scope.
    pub fn scope_authorized(&mut self, scope: &str) -> bool {
        let now = Instant::now();
        self.cleanup_scope_grants(now);
        if let Some(exp) = self.scope_grants.get(scope) {
            return *exp > now;
        }
        false
    }

    /// Set/update a scoped grant with a TTL
    pub fn set_scope_grant(&mut self, scope: &str, ttl: Duration) {
        let exp = Instant::now() + ttl;
        self.scope_grants.insert(scope.to_string(), exp);
    }

    /// Record which scope we are currently requesting proof for so we can grant it on proof
    pub fn set_pending_scope(&mut self, scope: String, ttl: Duration) {
        self.pending_scope = Some((scope, ttl));
    }

    fn cleanup_scope_grants(&mut self, now: Instant) {
        self.scope_grants.retain(|_, exp| *exp > now);
    }

    // M1.5: Called once per phone handshake when we get the phone's wall clock
    #[allow(dead_code)] // Deferred until phone wall-clock skew telemetry is wired.
    pub fn set_skew_from_phone(&mut self, phone_wall: SystemTime) {
        let mac = self.clock.now_wall();
        let diff = abs_diff(mac, phone_wall);
        self.skew = if diff > self.skew_max {
            SkewStatus::Degraded
        } else {
            SkewStatus::Ok
        };
    }

    // M1.5: After successful Face ID step-up for session unlock
    pub fn issue_session_unlock(&mut self) {
        use SkewStatus::*;
        self.is_remote_session = false;
        let ttl = match self.skew {
            Ok => self.base_ttl,
            Degraded => self.degraded_ttl,
            Deny => Duration::from_secs(0),
        };
        if ttl.is_zero() {
            self.auth_ok_until = None;
            return;
        }
        let now = self.clock.now_mono();
        self.auth_ok_until = Some(now + ttl);
    }

    // M1.5: Before gated ops - returns Ok if session is still valid
    pub fn check_session(&self) -> Result<(), ApiError> {
        match self.auth_ok_until {
            Some(deadline) if self.clock.now_mono() <= deadline => Ok(()),
            _ => Err(ApiError::TokenExpired),
        }
    }

    /// Mark current session as remote (authenticated via TOTP when FAR)
    pub fn mark_remote_session(&mut self) {
        self.is_remote_session = true;
    }

    /// Clear remote session flag (e.g., when user becomes NEAR)
    #[allow(dead_code)] // Reserved for explicit remote-session teardown entrypoint.
    pub fn clear_remote_session(&mut self) {
        self.is_remote_session = false;
    }

    /// Issue session unlock with custom TTL (for TOTP with policy-defined TTL)
    pub fn issue_session_unlock_with_ttl(&mut self, ttl: Duration) {
        if ttl.is_zero() {
            self.auth_ok_until = None;
            return;
        }
        let now = self.clock.now_mono();
        self.auth_ok_until = Some(now + ttl);
    }

    pub fn is_remote_session(&self) -> bool {
        self.is_remote_session
    }
}
