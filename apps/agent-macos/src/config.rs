use std::env;

#[derive(Clone, Debug)]
pub struct AgentConfig {
    pub rate_per_origin_per_min: f64,
    pub auth_max_global: usize,
    pub auth_max_per_origin: usize,
    pub idempotency_ttl_s: u64,

    // M1.4: Proximity mode config
    pub prox_mode: crate::proximity::ProxMode,
    pub prox_grace_ms: u64,
    pub prox_pause_default_s: u64,
    pub prox_session_ttl_s: u64,

    // M1.5: Monotonic TTL config
    pub auth_ttl_s: u64,
    pub skew_max_s: i64,
    pub skew_degraded_ttl_s: u64,
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            rate_per_origin_per_min: 5.0,
            auth_max_global: 3,
            auth_max_per_origin: 1,
            idempotency_ttl_s: 300,
            prox_mode: crate::proximity::ProxMode::FirstUse,
            prox_grace_ms: 60_000,
            prox_pause_default_s: 1_800,
            prox_session_ttl_s: 3_600,

            // M1.5 defaults
            auth_ttl_s: 3_600,       // 60 minutes
            skew_max_s: 90,          // 90 seconds
            skew_degraded_ttl_s: 30, // 30 seconds
        }
    }
}

impl AgentConfig {
    pub fn from_env() -> Self {
        let default_cfg = Self::default();

        let rate_per_origin_per_min = env::var("ARM_RATE_PER_ORIGIN_PER_MIN")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_cfg.rate_per_origin_per_min);

        let auth_max_global = env::var("ARM_AUTH_MAX_GLOBAL")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_cfg.auth_max_global);

        let auth_max_per_origin = env::var("ARM_AUTH_MAX_PER_ORIGIN")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_cfg.auth_max_per_origin);

        let idempotency_ttl_s = std::env::var("ARM_IDEMPOTENCY_TTL_S")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_cfg.idempotency_ttl_s);

        // M1.4: Proximity config

        let prox_mode = std::env::var("ARM_PROX_MODE")
            .ok()
            .and_then(|s| match s.to_lowercase().as_str() {
                "auto_unlock" => Some(crate::proximity::ProxMode::AutoUnlock),
                "first_use" => Some(crate::proximity::ProxMode::FirstUse),
                "intent" => Some(crate::proximity::ProxMode::Intent),
                _ => None,
            })
            .unwrap_or(crate::proximity::ProxMode::FirstUse);

        let prox_grace_ms = std::env::var("ARM_PROX_GRACE_MS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_cfg.prox_grace_ms);

        let prox_pause_default_s = std::env::var("ARM_PROX_PAUSE_DEFAULT_S")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_cfg.prox_pause_default_s);

        let prox_session_ttl_s = std::env::var("ARM_PROX_SESSION_TTL_S")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_cfg.prox_session_ttl_s);

        // M1.5: TTL config
        let auth_ttl_s = std::env::var("ARM_AUTH_TTL_S")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_cfg.auth_ttl_s);

        let skew_max_s = std::env::var("ARM_SKEW_MAX_S")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_cfg.skew_max_s);

        let skew_degraded_ttl_s = std::env::var("ARM_SKEW_DEGRADED_TTL_S")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_cfg.skew_degraded_ttl_s);

        Self {
            rate_per_origin_per_min,
            auth_max_global,
            auth_max_per_origin,
            idempotency_ttl_s,
            prox_mode,
            prox_grace_ms,
            prox_pause_default_s,
            prox_session_ttl_s,
            auth_ttl_s,
            skew_max_s,
            skew_degraded_ttl_s,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let cfg = AgentConfig::default();
        assert_eq!(cfg.rate_per_origin_per_min, 5.0);
        assert_eq!(cfg.auth_max_global, 3);
        assert_eq!(cfg.auth_max_per_origin, 1);
        assert_eq!(cfg.idempotency_ttl_s, 300);
    }

    #[test]
    fn test_from_env_with_defaults() {
        // Without any env vars, should use defaults
        std::env::remove_var("ARM_RATE_PER_ORIGIN_PER_MIN");
        std::env::remove_var("ARM_AUTH_MAX_GLOBAL");

        let cfg = AgentConfig::from_env();
        assert_eq!(cfg.rate_per_origin_per_min, 5.0);
        assert_eq!(cfg.auth_max_global, 3);
    }
}
