// STATUS: ACTIVE
// PURPOSE: proximity state machine — owns Near/Far/Grace transitions, intent latch, BLE timeout
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::broadcast;

/// Channel input messages for proximity state updates
#[derive(Debug, Clone)]
pub enum ProxInput {
    /// BLE beacon validated - device is near
    BleSeen {
        #[allow(dead_code)] // Reserved for per-device proximity diagnostics.
        fp: String,
        rssi: Option<i16>,
        now: Instant,
    },
}

/// Proximity behavior per machine.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProxMode {
    AutoUnlock, // unlock on NEAR, no prompt
    FirstUse,   // NEAR locked; first gated op Face ID; then unlocked
    Intent,     // NEAR locked; requires prox.intent + Face ID to unlock
}

/// High-level proximity state owned by the agent.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProxState {
    Far,          // phone not near / no valid heartbeat
    NearLocked,   // phone near but vault base session locked
    NearUnlocked, // phone near and base session unlocked
    Paused,       // proximity suppressed (timer)
}

#[derive(Clone, Debug)]
pub struct ProxStatus {
    #[allow(dead_code)] // Reserved for richer diagnostics payloads.
    pub mode: ProxMode,
    #[allow(dead_code)] // Reserved for richer diagnostics payloads.
    pub state: ProxState,
    #[allow(dead_code)] // Reserved for richer diagnostics payloads.
    pub grace_remaining_ms: Option<u64>,
    #[allow(dead_code)] // Reserved for richer diagnostics payloads.
    pub pause_remaining_s: Option<u64>,
    pub last_heartbeat_age_ms: Option<u64>,
}

#[derive(Clone, Debug)]
pub enum ProxEvent {
    Enter,
    Leave,
    Unlocked,
    Locked,
    GraceStarted {
        #[allow(dead_code)] // Reserved for event stream consumers.
        ms: u64,
    },
    GraceCleared,
    Paused {
        #[allow(dead_code)] // Reserved for event stream consumers.
        secs: u64,
    },
    Resumed,
    IntentReceived,
}

pub struct Proximity {
    mode: ProxMode,
    state: ProxState,
    grace_deadline: Option<Instant>,
    pause_until: Option<Instant>,
    last_heartbeat: Option<Instant>,
    last_ble_seen: Option<Instant>,
    last_rssi: Option<i16>,
    /// Intent latch: set when iOS widget FaceID succeeds; required for LOCKED→NEAR
    intent_deadline: Option<Instant>,
    grace: Duration,
    pause_default: Duration,

    on_event: Option<Arc<dyn Fn(ProxEvent) + Send + Sync>>,
    notify_tx: broadcast::Sender<ProxState>,
}

impl Proximity {
    pub fn new(
        mode: ProxMode,
        grace: Duration,
        pause_default: Duration,
        on_event: Option<Arc<dyn Fn(ProxEvent) + Send + Sync>>,
    ) -> Self {
        let (tx, _rx) = broadcast::channel(16);
        Self {
            mode,
            state: ProxState::Far,
            grace_deadline: None,
            pause_until: None,
            last_heartbeat: None,
            last_ble_seen: None,
            last_rssi: None,
            intent_deadline: None,
            grace,
            pause_default,
            on_event,
            notify_tx: tx,
        }
    }

    #[inline]
    fn emit(&self, ev: ProxEvent) {
        if let Some(cb) = &self.on_event {
            cb(ev);
        }
    }

    /// Called when the TLS link becomes available/healthy (proxy for "NEAR" for now).
    pub fn on_tls_up(&mut self, now: Instant) {
        self.last_heartbeat = Some(now);
        // If paused, remain paused but clear any grace countdown (we're near again).
        if matches!(self.state, ProxState::Paused) {
            self.grace_deadline = None;
            self.emit(ProxEvent::GraceCleared);
            self.emit(ProxEvent::Enter);
            return;
        }

        // Only transition to NEAR if we were FAR; otherwise preserve unlocked state.
        if matches!(self.state, ProxState::Far) {
            self.grace_deadline = None;
            self.emit(ProxEvent::GraceCleared);
            self.transition_enter_near();
            self.emit(ProxEvent::Enter);
        } else {
            // Just refresh presence without changing NearLocked/NearUnlocked.
            self.grace_deadline = None;
            self.emit(ProxEvent::GraceCleared);
            self.record_heartbeat(now);
        }
    }

    /// Called when TLS goes away / presence lost. If `last_seen` is provided and we're already past
    /// grace, we lock immediately.
    pub fn on_tls_down(&mut self, now: Instant, last_seen: Option<Instant>) {
        self.last_heartbeat = None;

        // If already FAR, nothing to do.
        if matches!(self.state, ProxState::Far) {
            return;
        }

        // Start a grace window measured from the last heartbeat (if any). If we've already
        // exceeded grace, force the deadline to now so the next tick locks immediately.
        let mut deadline = now + self.grace;
        if let Some(ls) = last_seen {
            let elapsed = now.saturating_duration_since(ls);
            if elapsed >= self.grace {
                deadline = now;
            } else {
                deadline = ls + self.grace;
            }
        }
        self.grace_deadline = Some(deadline);
        self.emit(ProxEvent::GraceStarted {
            ms: self.grace.as_millis() as u64,
        });
        self.emit(ProxEvent::Leave);
    }

    /// Periodic timer tick; advance timers and finalize grace/pause timeouts.
    pub fn tick(&mut self, now: Instant) {
        // Handle pause timeout
        if let Some(until) = self.pause_until {
            if now >= until {
                self.pause_until = None;
                self.emit(ProxEvent::Resumed);
                // After resume, recompute state based on presence + mode:
                self.recompute_after_resume();
            }
        }

        // Handle grace deadline → lock to FAR
        if let Some(deadline) = self.grace_deadline {
            if now >= deadline {
                self.grace_deadline = None;
                if !matches!(self.state, ProxState::Far) {
                    self.state = ProxState::Far;
                    let _ = self.notify_tx.send(self.state);
                    self.emit(ProxEvent::Locked);
                }
            }
        }

        // BLE timeout check (idle-unaware fallback — prefer tick_with_idle from main loop)
        self.tick_with_idle(now, 0);
    }

    /// Idle-aware tick: decides GRACE vs immediate lock when BLE leash breaks.
    /// mac_idle_secs: seconds since last keyboard/mouse input (0 = treat as active).
    pub fn tick_with_idle(&mut self, now: Instant, mac_idle_secs: u64) {
        const MAC_IDLE_THRESHOLD_SECS: u64 = 180; // 3 minutes = user left desk

        // Handle pause timeout
        if let Some(until) = self.pause_until {
            if now >= until {
                self.pause_until = None;
                self.emit(ProxEvent::Resumed);
                self.recompute_after_resume();
            }
        }

        // Grace deadline expired → lock
        if let Some(deadline) = self.grace_deadline {
            if now >= deadline {
                self.grace_deadline = None;
                if !matches!(self.state, ProxState::Far) {
                    self.state = ProxState::Far;
                    let _ = self.notify_tx.send(self.state);
                    self.emit(ProxEvent::Locked);
                    let age_ms = self
                        .last_ble_seen
                        .map(|t| now.saturating_duration_since(t).as_millis())
                        .unwrap_or(0);
                    tracing::info!(
                        event = "prox.grace_expired",
                        ble_age_ms = age_ms,
                        msg = "Transitioned Near -> Far due to grace timeout"
                    );
                }
            }
        }

        // BLE timeout: Near → GRACE or LOCKED depending on Mac activity
        if self.pause_until.is_none() && self.grace_deadline.is_none() {
            if matches!(self.state, ProxState::NearLocked | ProxState::NearUnlocked) {
                if let Some(last_ble) = self.last_ble_seen {
                    let age = now.saturating_duration_since(last_ble);
                    if age >= Duration::from_secs(15) {
                        tracing::info!(
                            event = "prox.ble_timeout",
                            last_seen_age_ms = age.as_millis()
                        );
                        if mac_idle_secs >= MAC_IDLE_THRESHOLD_SECS {
                            // User left desk — lock immediately, no grace
                            self.state = ProxState::Far;
                            let _ = self.notify_tx.send(self.state);
                            self.emit(ProxEvent::Locked);
                            tracing::info!(
                                event = "prox.ble_timeout.immediate_lock",
                                ble_age_ms = age.as_millis(),
                                mac_idle_secs = mac_idle_secs
                            );
                        } else {
                            // User active — enter GRACE, give 30s to re-tap widget
                            let grace_secs = self.grace.as_secs().max(30);
                            self.grace_deadline = Some(now + Duration::from_secs(grace_secs));
                            self.emit(ProxEvent::GraceStarted {
                                ms: grace_secs * 1000,
                            });
                            tracing::info!(
                                event = "prox.ble_timeout.grace",
                                ble_age_ms = age.as_millis(),
                                mac_idle_secs = mac_idle_secs,
                                grace_secs = grace_secs
                            );
                        }
                    }
                }
            }
        }
    }

    /// For Intent mode: user tapped "Use this Mac".
    pub fn intent(&mut self) {
        if matches!(self.state, ProxState::NearLocked) && matches!(self.mode, ProxMode::Intent) {
            self.emit(ProxEvent::IntentReceived);
            // We don't unlock here—gating will run Face ID. On success, call `mark_session_unlocked`.
        }
    }

    /// Gating should call this after the base session Face ID succeeds.
    pub fn mark_session_unlocked(&mut self) {
        // Only unlock when NEAR (or Paused lifted).
        if matches!(self.state, ProxState::NearLocked) {
            self.state = ProxState::NearUnlocked;
            let _ = self.notify_tx.send(self.state);
            self.emit(ProxEvent::Unlocked);
        }
    }

    /// Explicitly force lock (used on FAR finalization or user lock).
    #[allow(dead_code)] // Reserved for explicit external lock endpoint.
    pub fn force_lock(&mut self) {
        if !matches!(self.state, ProxState::Far | ProxState::NearLocked) {
            self.state = ProxState::NearLocked;
            let _ = self.notify_tx.send(self.state);
            self.emit(ProxEvent::Locked);
        }
    }

    /// Pause proximity (no auto-unlock) for a duration.
    pub fn pause(&mut self, now: Instant, dur: Option<Duration>) {
        let secs = dur.unwrap_or(self.pause_default);
        self.pause_until = Some(now + secs);
        self.state = ProxState::Paused;
        self.grace_deadline = None; // paused suppresses grace logic
        let _ = self.notify_tx.send(self.state);
        self.emit(ProxEvent::Paused {
            secs: secs.as_secs(),
        });
    }

    /// Resume from pause.
    pub fn resume(&mut self) {
        self.pause_until = None;
        self.emit(ProxEvent::Resumed);
        self.recompute_after_resume();
    }

    fn recompute_after_resume(&mut self) {
        // If we're near (we treat "near" as: grace_deadline is None AND last_heartbeat is Some),
        // apply mode rules, else remain FAR.
        let near = self.last_heartbeat.is_some();
        if !near {
            self.state = ProxState::Far;
            let _ = self.notify_tx.send(self.state);
            return;
        }
        self.transition_enter_near();
    }

    fn transition_enter_near(&mut self) {
        self.state = match self.mode {
            ProxMode::AutoUnlock => ProxState::NearUnlocked,
            ProxMode::FirstUse => ProxState::NearLocked,
            ProxMode::Intent => ProxState::NearLocked,
        };
        let _ = self.notify_tx.send(self.state);
        if matches!(self.state, ProxState::NearUnlocked) {
            self.emit(ProxEvent::Unlocked);
        }
    }

    // —— Getters ——
    pub fn status(&self, now: Instant) -> ProxStatus {
        let grace_remaining_ms = self
            .grace_deadline
            .and_then(|dl| dl.checked_duration_since(now))
            .map(|d| d.as_millis() as u64);

        let last_heartbeat_age_ms = self
            .last_heartbeat
            .map(|ts| now.saturating_duration_since(ts).as_millis() as u64);

        let pause_remaining_s = self
            .pause_until
            .and_then(|dl| dl.checked_duration_since(now))
            .map(|d| d.as_secs());

        ProxStatus {
            mode: self.mode,
            state: self.state,
            grace_remaining_ms,
            pause_remaining_s,
            last_heartbeat_age_ms,
        }
    }

    pub fn is_unlocked(&self) -> bool {
        matches!(self.state, ProxState::NearUnlocked)
    }

    pub fn mode(&self) -> ProxMode {
        self.mode
    }
    pub fn state(&self) -> ProxState {
        self.state
    }

    #[allow(dead_code)] // Reserved for runtime mode switching API.
    pub fn set_mode(&mut self, mode: ProxMode) {
        self.mode = mode;
        // Re-derive state if NEAR and not paused.
        if !matches!(self.state, ProxState::Far | ProxState::Paused) {
            self.transition_enter_near();
        }
    }

    #[allow(dead_code)] // Reserved for deferred subscribers outside bridge loop.
    pub fn subscribe(&self) -> broadcast::Receiver<ProxState> {
        self.notify_tx.subscribe()
    }

    /// Expose grace duration for watchdogs.
    pub fn grace(&self) -> Duration {
        self.grace
    }

    /// Return true if last heartbeat age exceeds grace (or missing entirely).
    pub fn is_offline(&self, now: Instant) -> bool {
        match self.last_heartbeat {
            Some(ts) => now.duration_since(ts) >= self.grace,
            None => true,
        }
    }

    /// Record a device heartbeat without changing state transitions.
    pub fn record_heartbeat(&mut self, now: Instant) {
        self.last_heartbeat = Some(now);
        self.grace_deadline = None;
    }

    /// Set intent latch: allows next BLE-seen to unlock. Called when iOS sends intent.ok.
    pub fn set_intent(&mut self, now: Instant, window_secs: u64) {
        self.intent_deadline = Some(now + Duration::from_secs(window_secs));
        self.emit(ProxEvent::IntentReceived);
        tracing::info!(event = "intent.latched", window_secs = window_secs);
    }

    /// True if intent was set and has not expired.
    pub fn intent_valid(&self, now: Instant) -> bool {
        self.intent_deadline.map(|d| now < d).unwrap_or(false)
    }

    // M1.4b C2: Helper methods for prox.status
    pub fn grace_remaining_ms(&self, now: Instant) -> u64 {
        self.grace_deadline
            .and_then(|dl| dl.checked_duration_since(now))
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    pub fn pause_remaining_s(&self, now: Instant) -> u64 {
        self.pause_until
            .and_then(|dl| dl.checked_duration_since(now))
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }

    // ✅ BLE PROXIMITY METHODS

    /// Called when BLE scanner validates a beacon.
    /// Far→Near only happens when a valid intent latch exists (widget tap + FaceID).
    /// GRACE→UNLOCKED does NOT require new intent (session already active).
    pub fn note_ble_seen(&mut self, now: Instant, rssi: Option<i16>) {
        self.last_ble_seen = Some(now);
        self.last_rssi = rssi;

        // BLE during GRACE: session was active, restore without new intent
        if self.grace_deadline.is_some() {
            self.grace_deadline = None;
            self.emit(ProxEvent::GraceCleared);
            // State stays NearLocked/NearUnlocked (already Near, just restoring)
            return;
        }

        // Far→Near: requires valid intent (widget tap + FaceID)
        if matches!(self.state, ProxState::Far) {
            if self.intent_valid(now) {
                self.intent_deadline = None; // consume intent (one-shot)
                self.transition_enter_near();
                self.emit(ProxEvent::Enter);
                tracing::info!(event = "prox.unlocked", reason = "ble+intent");
            } else {
                // BLE seen but no intent — stays locked, log it
                tracing::debug!(
                    event = "prox.ble_no_intent",
                    reason = "token valid but intent not set"
                );
            }
        }
    }

    /// Compute BLE-based proximity state for gating
    /// Returns true if BLE indicates device is near (within 8s)
    #[allow(dead_code)] // Reserved for future diagnostics/reporting.
    pub fn ble_is_near(&self, now: Instant) -> bool {
        match self.last_ble_seen {
            Some(ts) => {
                let age = now.saturating_duration_since(ts);
                age <= Duration::from_secs(8)
            }
            None => false,
        }
    }

    /// Get BLE age in milliseconds
    #[allow(dead_code)] // Reserved for future diagnostics/reporting.
    pub fn ble_age_ms(&self, now: Instant) -> Option<u64> {
        self.last_ble_seen
            .map(|ts| now.saturating_duration_since(ts).as_millis() as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::time::{self, Duration};

    fn now() -> Instant {
        Instant::now()
    }

    #[tokio::test]
    async fn auto_unlock_basic_flow() {
        time::pause();
        let start = now();
        let mut prox = Proximity::new(
            ProxMode::AutoUnlock,
            Duration::from_millis(2000),
            Duration::from_secs(1800),
            None,
        );

        assert_eq!(prox.state(), ProxState::Far);

        prox.on_tls_up(start);
        assert_eq!(prox.state(), ProxState::NearUnlocked);
        assert!(prox.is_unlocked());

        prox.on_tls_down(start, None);
        // before grace ends → still not FAR
        prox.tick(start + Duration::from_millis(1999));
        assert!(!matches!(prox.state(), ProxState::Far));

        prox.tick(start + Duration::from_millis(2001));
        assert_eq!(prox.state(), ProxState::Far);
        assert!(!prox.is_unlocked());
    }

    #[tokio::test]
    async fn first_use_unlock_once() {
        time::pause();
        let start = now();
        let mut prox = Proximity::new(
            ProxMode::FirstUse,
            Duration::from_millis(1000),
            Duration::from_secs(1800),
            None,
        );

        prox.on_tls_up(start);
        assert_eq!(prox.state(), ProxState::NearLocked);

        // Simulate Face ID success for base session:
        prox.mark_session_unlocked();
        assert_eq!(prox.state(), ProxState::NearUnlocked);

        // Lose presence → grace → lock to FAR
        prox.on_tls_down(start, None);
        prox.tick(start + Duration::from_millis(1001));
        assert_eq!(prox.state(), ProxState::Far);
    }

    #[tokio::test]
    async fn intent_requires_explicit_action() {
        time::pause();
        let start = now();
        let mut prox = Proximity::new(
            ProxMode::Intent,
            Duration::from_millis(1000),
            Duration::from_secs(1800),
            None,
        );

        prox.on_tls_up(start);
        assert_eq!(prox.state(), ProxState::NearLocked);

        prox.intent(); // user tapped "Use this Mac" on phone
                       // still locked until Face ID approval succeeds:
        assert_eq!(prox.state(), ProxState::NearLocked);

        prox.mark_session_unlocked();
        assert_eq!(prox.state(), ProxState::NearUnlocked);
    }

    #[tokio::test]
    async fn pause_blocks_unlocks() {
        time::pause();
        let start = now();
        let mut prox = Proximity::new(
            ProxMode::AutoUnlock,
            Duration::from_millis(1000),
            Duration::from_secs(60),
            None,
        );

        prox.on_tls_up(start);
        assert_eq!(prox.state(), ProxState::NearUnlocked);

        prox.pause(start, Some(Duration::from_secs(30)));
        assert_eq!(prox.state(), ProxState::Paused);

        // Resume later: should recompute based on presence + mode
        prox.resume();
        assert!(matches!(prox.state(), ProxState::NearUnlocked));
    }

    #[tokio::test]
    async fn restart_defaults_locked() {
        time::pause();
        let mut prox = Proximity::new(
            ProxMode::FirstUse,
            Duration::from_millis(1000),
            Duration::from_secs(1800),
            None,
        );

        assert_eq!(prox.state(), ProxState::Far);
        prox.on_tls_up(now());
        assert_eq!(prox.state(), ProxState::NearLocked); // needs Face ID path
    }
}
