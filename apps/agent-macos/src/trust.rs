use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrustMode {
    Strict,
    BackgroundTtl,
    Office,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrustState {
    Locked,
    Trusted,
    Revoking,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SignalState {
    Present,
    Lost,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrustConfig {
    pub mode: TrustMode,
    pub background_ttl_secs: u64,
    pub office_idle_secs: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrustEvent {
    pub event: String,
    pub reason: Option<String>,
    pub mode: TrustMode,
    pub trust_id: Option<String>,
    pub trust_until_ms: Option<u64>,
    pub deadline_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrustStatus {
    pub state: TrustState,
    pub mode: TrustMode,
    pub signal: SignalState,
    pub trust_id: Option<String>,
    pub trust_until_ms: Option<u64>,
    pub deadline_ms: Option<u64>,
}

pub struct TrustController {
    mode: TrustMode,
    trust: TrustState,
    signal: SignalState,
    trust_id: Option<String>,
    trust_until: Option<Instant>,
    deadline: Option<Instant>,
    last_user_activity: Instant,
    background_ttl_secs: u64,
    office_idle_secs: u64,
    boot_instant: Instant,
    boot_epoch_ms: u64,
}

impl TrustController {
    pub fn new(
        mode: TrustMode,
        background_ttl_secs: u64,
        office_idle_secs: u64,
        _cleanup_timeout: Duration,
    ) -> Self {
        Self {
            mode,
            trust: TrustState::Locked,
            signal: SignalState::Lost,
            trust_id: None,
            trust_until: None,
            deadline: None,
            last_user_activity: Instant::now(),
            background_ttl_secs,
            office_idle_secs,
            boot_instant: Instant::now(),
            boot_epoch_ms: now_epoch_ms(),
        }
    }

    pub fn is_trusted(&self) -> bool {
        matches!(self.trust, TrustState::Trusted)
    }

    pub fn config(&self) -> TrustConfig {
        TrustConfig {
            mode: self.mode,
            background_ttl_secs: self.background_ttl_secs,
            office_idle_secs: self.office_idle_secs,
        }
    }

    pub fn status(&self) -> TrustStatus {
        TrustStatus {
            state: self.trust,
            mode: self.mode,
            signal: self.signal,
            trust_id: self.trust_id.clone(),
            trust_until_ms: self.trust_until.map(|t| self.instant_to_epoch_ms(t)),
            deadline_ms: self.deadline.map(|d| self.instant_to_epoch_ms(d)),
        }
    }

    pub fn grant(
        &mut self,
        now: Instant,
        trust_id: String,
        mode: TrustMode,
        ttl_secs: u64,
    ) -> Vec<TrustEvent> {
        self.mode = mode;
        self.signal = SignalState::Present;
        self.trust = TrustState::Trusted;
        self.last_user_activity = now;
        self.trust_id = Some(trust_id.clone());
        self.trust_until = None;
        self.deadline = None;
        if matches!(mode, TrustMode::BackgroundTtl) && ttl_secs > 0 {
            self.background_ttl_secs = ttl_secs;
        }
        vec![TrustEvent {
            event: "granted".to_string(),
            reason: None,
            mode: self.mode,
            trust_id: Some(trust_id),
            trust_until_ms: self.trust_until.map(|t| self.instant_to_epoch_ms(t)),
            deadline_ms: None,
        }]
    }

    pub fn signal_lost(&mut self, now: Instant) -> Vec<TrustEvent> {
        self.signal = SignalState::Lost;
        let mut out = vec![TrustEvent {
            event: "signal_lost".to_string(),
            reason: None,
            mode: self.mode,
            trust_id: self.trust_id.clone(),
            trust_until_ms: self.trust_until.map(|t| self.instant_to_epoch_ms(t)),
            deadline_ms: self.deadline.map(|d| self.instant_to_epoch_ms(d)),
        }];
        if !matches!(self.trust, TrustState::Trusted) {
            return out;
        }
        match self.mode {
            TrustMode::Strict => out.extend(self.revoke(now, "signal_lost")),
            TrustMode::BackgroundTtl => {
                self.deadline = Some(now + Duration::from_secs(self.background_ttl_secs));
                out.push(TrustEvent {
                    event: "deadline_started".to_string(),
                    reason: None,
                    mode: self.mode,
                    trust_id: self.trust_id.clone(),
                    trust_until_ms: None,
                    deadline_ms: self.deadline.map(|d| self.instant_to_epoch_ms(d)),
                });
            }
            TrustMode::Office => {}
        }
        out
    }

    pub fn signal_present(&mut self, now: Instant) -> Vec<TrustEvent> {
        self.signal = SignalState::Present;
        self.last_user_activity = now;
        vec![TrustEvent {
            event: "signal_present".to_string(),
            reason: None,
            mode: self.mode,
            trust_id: self.trust_id.clone(),
            trust_until_ms: self.trust_until.map(|t| self.instant_to_epoch_ms(t)),
            deadline_ms: self.deadline.map(|d| self.instant_to_epoch_ms(d)),
        }]
    }

    pub fn revoke(&mut self, now: Instant, reason: &str) -> Vec<TrustEvent> {
        let _ = now;
        self.trust = TrustState::Locked;
        self.signal = SignalState::Lost;
        self.deadline = None;
        self.trust_until = None;
        let trust_id = self.trust_id.clone();
        self.trust_id = None;
        vec![TrustEvent {
            event: "revoked".to_string(),
            reason: Some(reason.to_string()),
            mode: self.mode,
            trust_id,
            trust_until_ms: None,
            deadline_ms: None,
        }]
    }

    pub fn tick(&mut self, now: Instant) -> Vec<TrustEvent> {
        let mut out = Vec::new();
        if matches!(self.mode, TrustMode::BackgroundTtl)
            && matches!(self.trust, TrustState::Trusted)
            && self.signal == SignalState::Lost
            && self.deadline.is_some_and(|d| now >= d)
        {
            out.extend(self.revoke(now, "ttl_expired"));
        }

        if matches!(self.mode, TrustMode::Office)
            && matches!(self.trust, TrustState::Trusted)
            && self.signal == SignalState::Lost
            && now.duration_since(self.last_user_activity)
                >= Duration::from_secs(self.office_idle_secs)
        {
            out.extend(self.revoke(now, "idle_timeout"));
        }

        out
    }

    pub fn set_config(
        &mut self,
        now: Instant,
        mode: TrustMode,
        background_ttl_secs: u64,
        office_idle_secs: u64,
    ) -> Vec<TrustEvent> {
        self.mode = mode;
        self.background_ttl_secs = background_ttl_secs.clamp(30, 3600);
        self.office_idle_secs = office_idle_secs.max(30);

        let mut out = Vec::new();
        if matches!(self.trust, TrustState::Trusted) && self.signal == SignalState::Lost {
            match self.mode {
                TrustMode::Strict => out.extend(self.revoke(now, "policy_changed")),
                TrustMode::BackgroundTtl => {
                    self.deadline = Some(now + Duration::from_secs(self.background_ttl_secs));
                    out.push(TrustEvent {
                        event: "deadline_started".to_string(),
                        reason: Some("policy_changed".to_string()),
                        mode: self.mode,
                        trust_id: self.trust_id.clone(),
                        trust_until_ms: None,
                        deadline_ms: self.deadline.map(|d| self.instant_to_epoch_ms(d)),
                    });
                }
                TrustMode::Office => {}
            }
        }
        out
    }

    fn instant_to_epoch_ms(&self, at: Instant) -> u64 {
        let delta = at.saturating_duration_since(self.boot_instant);
        self.boot_epoch_ms.saturating_add(delta.as_millis() as u64)
    }
}

fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

pub fn load_trust_config(path: &Path) -> Result<Option<TrustConfig>, String> {
    let contents = match fs::read_to_string(path) {
        Ok(v) => v,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("trust_config_read_failed:{}", e)),
    };
    if contents.trim().is_empty() {
        return Ok(None);
    }
    let cfg: TrustConfig =
        serde_yaml::from_str(&contents).map_err(|e| format!("trust_config_parse_failed:{}", e))?;
    Ok(Some(cfg))
}

pub fn save_trust_config(path: &Path, cfg: &TrustConfig) -> Result<(), String> {
    let yaml =
        serde_yaml::to_string(cfg).map_err(|e| format!("trust_config_serialize_failed:{}", e))?;
    atomic_write(path, yaml.as_bytes()).map_err(|e| format!("config_write_failed:{}", e))
}

fn atomic_write(path: &Path, data: &[u8]) -> Result<(), std::io::Error> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let tmp_path = path.with_extension(format!(
        "tmp.{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    ));
    {
        let mut f = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&tmp_path)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    fs::rename(&tmp_path, path)?;
    #[cfg(unix)]
    if let Some(parent) = path.parent() {
        let dir = fs::File::open(parent)?;
        dir.sync_all()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_controller(mode: TrustMode, ttl: u64, office_idle: u64) -> TrustController {
        TrustController::new(mode, ttl, office_idle, Duration::from_secs(10))
    }

    #[test]
    fn strict_mode_signal_lost_revokes_immediately() {
        let base = Instant::now();
        let mut tc = test_controller(TrustMode::Strict, 300, 900);

        let _ = tc.grant(base, "t_strict".to_string(), TrustMode::Strict, 300);
        assert!(tc.is_trusted());

        let events = tc.signal_lost(base + Duration::from_secs(1));
        assert_eq!(events[0].event, "signal_lost");
        assert!(events.iter().any(|e| e.event == "revoked"));
        assert!(!tc.is_trusted());
        assert_eq!(tc.status().state, TrustState::Locked);
    }

    #[test]
    fn background_ttl_keeps_trust_until_deadline_then_revokes() {
        let base = Instant::now();
        let mut tc = test_controller(TrustMode::BackgroundTtl, 5, 900);

        let _ = tc.grant(base, "t_ttl".to_string(), TrustMode::BackgroundTtl, 5);
        assert!(tc.is_trusted());

        let loss_events = tc.signal_lost(base + Duration::from_secs(1));
        assert!(loss_events.iter().any(|e| e.event == "deadline_started"));
        assert!(tc.is_trusted());
        assert!(tc.status().deadline_ms.is_some());

        // Deadline should still be active when signal returns; only re-grant clears it.
        let present_events = tc.signal_present(base + Duration::from_secs(2));
        assert_eq!(present_events[0].event, "signal_present");
        assert!(tc.status().deadline_ms.is_some());

        // Simulate loss again (countdown path) and expiry.
        let _ = tc.signal_lost(base + Duration::from_secs(2));
        let before_expiry = tc.tick(base + Duration::from_secs(6));
        assert!(before_expiry.is_empty());
        assert!(tc.is_trusted());

        let at_expiry = tc.tick(base + Duration::from_secs(7));
        assert!(at_expiry.iter().any(|e| e.event == "revoked"));
        assert!(at_expiry
            .iter()
            .any(|e| e.reason.as_deref() == Some("ttl_expired")));
        assert!(!tc.is_trusted());
    }

    #[test]
    fn office_mode_signal_lost_waits_for_idle_timeout() {
        let base = Instant::now();
        let mut tc = test_controller(TrustMode::Office, 300, 3);

        let _ = tc.grant(base, "t_office".to_string(), TrustMode::Office, 300);
        assert!(tc.is_trusted());

        let loss_events = tc.signal_lost(base + Duration::from_secs(1));
        assert_eq!(loss_events[0].event, "signal_lost");
        assert!(loss_events.iter().all(|e| e.event != "deadline_started"));
        assert!(tc.is_trusted());

        let before_idle = tc.tick(base + Duration::from_secs(2));
        assert!(before_idle.is_empty());
        assert!(tc.is_trusted());

        let after_idle = tc.tick(base + Duration::from_secs(4));
        assert!(after_idle.iter().any(|e| e.event == "revoked"));
        assert!(after_idle
            .iter()
            .any(|e| e.reason.as_deref() == Some("idle_timeout")));
        assert!(!tc.is_trusted());
    }
}
