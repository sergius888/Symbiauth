// STATUS: ACTIVE
// PURPOSE: TLS message router — handles all iOS↔Mac protocol messages, vault ops, auth flow
use serde_json::{self, json, Value};
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{unix::OwnedWriteHalf, UnixListener, UnixStream};
use tokio::sync::Mutex;
use tracing::{debug, error, info, warn};

use crate::auth::{AuthState, AuthStatus, ProofError};
use crate::launcher::{built_in_templates, KeychainSecretResolver, Launcher, LauncherManager};
use crate::pairing::PairingManager;
use crate::policy::{Decision, MatchCtx, Policy, StepUpMode, StepUpRule};
use crate::proximity::{ProxMode, ProxState, Proximity};
use crate::recovery::{generate_mnemonic_12, PendingRekey};
use crate::secrets::{
    collect_secret_refs, delete_secret, get_secret, list_registered_secret_entries,
    register_secret_name, secret_usage_map, set_secret, test_secret, unregister_secret_name,
    validate_secret_name,
};
use crate::sinks::{push_enabled, send_json, SinkRegistry, SinkRole};
use crate::trust::{save_trust_config, TrustConfig, TrustController, TrustEvent, TrustMode};
use crate::vault::VaultError;
use crate::{origin, totp};
// Unused imports removed by clippy
use std::sync::Arc;

// M1.4b C2: RAII guard for TLS presence tracking
struct TlsUpGuard {
    prox: Arc<Mutex<crate::proximity::Proximity>>,
    dropped: bool,
}

impl TlsUpGuard {
    async fn enter(prox: Arc<Mutex<crate::proximity::Proximity>>) -> Self {
        let now = Instant::now();
        {
            let mut p = prox.lock().await;
            p.on_tls_up(now);
        }
        Self {
            prox,
            dropped: false,
        }
    }
}

impl Drop for TlsUpGuard {
    fn drop(&mut self) {
        if self.dropped {
            return;
        }
        // Don't .await in Drop; fire-and-forget with detached task
        let prox = self.prox.clone();
        let when = Instant::now();
        tokio::spawn(async move {
            let mut p = prox.lock().await;
            p.on_tls_down(when, None);
        });
        self.dropped = true;
    }
}

/// Gate that allows local proximity unlocks or remote TOTP sessions when policy permits.
async fn remote_or_proximity_gate(
    prox: &Arc<Mutex<Proximity>>,
    trust: &Arc<Mutex<TrustController>>,
    auth: &Arc<Mutex<AuthState>>,
    step: Option<&StepUpRule>,
) -> Result<(), (&'static str, u16)> {
    if trust_v1_enabled() {
        let t = trust.lock().await;
        if t.is_trusted() {
            return Ok(());
        }
        return Err(("trust_locked", 401));
    }

    use ProxState::*;
    let p = prox.lock().await;
    let mode = p.mode();
    let state = p.state();

    match state {
        NearUnlocked => return Ok(()),
        Paused => return Err(("proximity_paused", 403)),
        NearLocked => {
            return match mode {
                ProxMode::Intent => Err(("prox_intent_required", 401)),
                _ => Err(("session_unlock_required", 401)),
            };
        }
        Far => {} // fallthrough to remote check
    }
    drop(p);

    if let Some(s) = step {
        if s.allow_remote && matches!(s.mode, StepUpMode::Totp) {
            let a = auth.lock().await;
            if a.is_remote_session() && a.check_session().is_ok() {
                return Ok(());
            } else {
                return Err(("step_up_totp_required", 401));
            }
        }
    }

    Err(("proximity_far", 401))
}

fn trust_v1_enabled() -> bool {
    matches!(
        std::env::var("ARM_TRUST_V1").ok().as_deref(),
        Some("1") | Some("true") | Some("TRUE")
    )
}

fn parse_trust_mode(raw: Option<&str>) -> TrustMode {
    match raw
        .unwrap_or("background_ttl")
        .to_ascii_lowercase()
        .as_str()
    {
        "strict" => TrustMode::Strict,
        "office" => TrustMode::Office,
        _ => TrustMode::BackgroundTtl,
    }
}

fn trust_config_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    std::path::PathBuf::from(format!("{}/.armadillo/trust.yaml", home))
}

fn clamp_ttl(ttl: Option<u64>) -> u64 {
    ttl.unwrap_or(300).clamp(30, 3600)
}

fn trust_id() -> String {
    use rand::{distributions::Alphanumeric, Rng};
    let s: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(10)
        .map(char::from)
        .collect();
    format!("t_{}", s.to_lowercase())
}

fn trust_event_json(ev: &TrustEvent) -> Value {
    json!({
        "type": "trust.event",
        "v": 1,
        "ts_ms": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
        "event": ev.event,
        "trust_id": ev.trust_id,
        "mode": ev.mode,
        "trust_until_ms": ev.trust_until_ms,
        "deadline_ms": ev.deadline_ms,
        "reason": ev.reason
    })
}

fn launcher_run_trust_gate(corr_id: &str, launcher_id: &str, trusted: bool) -> Option<Value> {
    if trusted {
        return None;
    }
    Some(json!({
        "type":"launcher.run",
        "corr_id": corr_id,
        "ok": false,
        "launcher_id": launcher_id,
        "error": "trust_not_active"
    }))
}

fn secret_write_trust_gate(corr_id: &str, msg_type: &str, name: &str, trusted: bool) -> Option<Value> {
    if trusted {
        return None;
    }
    Some(json!({
        "type": msg_type,
        "corr_id": corr_id,
        "ok": false,
        "name": name,
        "error": "trust_not_active"
    }))
}

async fn push_trust_events(sinks: &Arc<Mutex<SinkRegistry>>, events: Vec<TrustEvent>) {
    if events.is_empty() {
        return;
    }
    let mut guard = sinks.lock().await;
    for ev in events {
        let payload = trust_event_json(&ev);
        let sent = guard.send_to(SinkRole::Tls, &payload).await;
        info!(
            role = "agent",
            cat = "trust",
            event = "trust.event.push",
            trust_event = %ev.event,
            trust_id = ?ev.trust_id,
            sent_tls = sent
        );
    }
}

fn derive_k_ble_for_phone(pairing_manager: &PairingManager, phone_fp: &str) -> Option<[u8; 32]> {
    let ios_pub = pairing_manager.get_or_load_ios_wrap_pub_vec(phone_fp)?;
    let mut sec1_buf: Vec<u8> = Vec::new();
    if ios_pub.len() == 65 && ios_pub[0] == 0x04 {
        sec1_buf.extend_from_slice(&ios_pub);
    } else if ios_pub.len() == 64 {
        sec1_buf.push(0x04);
        sec1_buf.extend_from_slice(&ios_pub);
    } else {
        return None;
    }

    let fp_clean = phone_fp.strip_prefix("sha256:").unwrap_or(phone_fp);
    let fp_bytes = hex::decode(fp_clean).ok()?;
    if fp_bytes.len() != 32 {
        return None;
    }
    let mut hasher = Sha256::new();
    hasher.update(b"arm-ble-salt-v1");
    hasher.update(&fp_bytes);
    let salt_hash = hasher.finalize();
    let salt: [u8; 32] = salt_hash.into();
    let sk = ensure_agent_wrap_secret().ok()?;
    derive_ble_key(&sk, &sec1_buf, &salt).ok()
}
use crate::vault::Vault;
use crate::wrap::{derive_ble_key, derive_wrap_key, ensure_agent_wrap_secret};
use crate::AuthPolicy;
use base64::Engine; // for .encode() / .decode() on STANDARD engine
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

// PR1: Helper functions for rate limiting
fn should_rate_limit(msg_type: &str) -> bool {
    matches!(
        msg_type,
        "cred.get" | "cred.list" | "vault.read" | "vault.write"
    )
}

fn extract_origin(j: &Value) -> Option<String> {
    j.get("origin")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}
fn new_conn_id() -> String {
    use rand::{distributions::Alphanumeric, Rng};
    let s: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(6)
        .map(char::from)
        .collect();
    s.to_lowercase()
}

fn sanitize_origin(raw: &str) -> Option<String> {
    crate::policy::canonical_origin(raw)
}

fn error_with_corr(code: &str, message: &str, corr: Option<&String>) -> Value {
    if let Some(cid) = corr {
        json!({"type":"error","code":code,"message":message,"corr_id":cid})
    } else {
        json!({"type":"error","code":code,"message":message})
    }
}

fn auth_error_with_status(
    code: &str,
    message: &str,
    corr: Option<&String>,
    status: AuthStatus,
) -> Value {
    let mut body = json!({
        "type":"error",
        "code":code,
        "message":message,
        "auth_authorized": status.authorized,
        "auth_age_ms": status.auth_age_ms,
    });
    if let Some(exp) = status.expires_in_ms {
        body["auth_expires_in_ms"] = json!(exp);
    }
    if let Some(cid) = corr {
        body["corr_id"] = json!(cid);
    }
    body
}

async fn require_auth_if_needed(
    auth_policy: &AuthPolicy,
    auth_state: &Arc<Mutex<AuthState>>,
    policy: &Policy,
    scope: &str,
    mctx: &MatchCtx,
    corr: Option<&String>,
    sid: Option<&String>,
    _proximity: &Arc<Mutex<crate::proximity::Proximity>>,
    _now: SystemTime,
) -> Option<Value> {
    // M1.4b C1: Old proximity tick removed - stubbed gate check
    // Decide based on policy rules
    let decision = policy.decide(mctx);
    match decision {
        Decision::Deny => Some(error_with_corr("POLICY_DENY", "operation denied", corr)),
        Decision::Allow => None,
        Decision::RequireStepUp { ttl_s, .. } => {
            let mut auth = auth_state.lock().await;
            let status = auth.status();
            let scope_ok = auth.scope_authorized(scope);
            // If caller doesn't supply a sid, allow reuse of the current authorized session (extension reuse).
            let sid_match = sid
                .map(|s| auth.session_matches(Some(s.as_str())))
                .unwrap_or(true);
            let needs_auth = match auth_policy {
                AuthPolicy::PerOp => !scope_ok,
                AuthPolicy::PerSession => !(status.authorized && sid_match),
                AuthPolicy::Ttl(_) => !(status.authorized || scope_ok),
            };
            if needs_auth {
                let corr_str = corr.map(|s| s.as_str()).unwrap_or("");
                let ttl = if ttl_s == 0 {
                    std::time::Duration::from_secs(0)
                } else {
                    // avoid overflow when adding to Instant; clamp to 1 year
                    let capped = ttl_s.min(31_536_000); // 365 days
                    std::time::Duration::from_secs(capped)
                };
                auth.set_pending_scope(scope.to_string(), ttl);
                Some(json!({
                    "type": "auth.request",
                    "corr_id": corr_str,
                    "reason": "vault_locked",
                    "scope": scope,
                    "ttl_s": ttl_s
                }))
            } else {
                None
            }
        }
    }
}

async fn unlock_required_error(auth_state: &Arc<Mutex<AuthState>>, corr: Option<&String>) -> Value {
    let status = {
        let guard = auth_state.lock().await;
        guard.status()
    };
    auth_error_with_status("UNLOCK_REQUIRED", "unlock required", corr, status)
}

async fn push_auth_request(sinks: &Arc<Mutex<SinkRegistry>>, corr_id: Option<&str>) {
    let enabled = push_enabled();
    let corr = corr_id.unwrap_or("");
    info!(
        event = "auth.nudge.check",
        enabled = enabled,
        corr_id = %corr
    );
    if !enabled {
        return;
    }
    let msg = json!({
        "type":"auth.request",
        "corr_id": corr
    });
    let mut guard = sinks.lock().await;
    if guard.send_to(SinkRole::Tls, &msg).await {
        info!(event = "auth.nudge.sent", sink = "tls", corr_id = %corr);
    } else {
        info!(
            event = "auth.nudge.skipped",
            reason = "no_tls_sink",
            corr_id = %corr
        );
    }
}

async fn push_auth_ok(
    sinks: &Arc<Mutex<SinkRegistry>>,
    corr_id: Option<&str>,
    until_epoch_secs: u64,
) {
    if !push_enabled() {
        return;
    }
    let corr = corr_id.unwrap_or("");
    let msg = json!({
        "type":"auth.ok",
        "corr_id": corr,
        "until": until_epoch_secs
    });
    let mut guard = sinks.lock().await;
    let sent_tls = guard.send_to(SinkRole::Tls, &msg).await;
    let sent_nm = guard.send_to(SinkRole::Nm, &msg).await;
    info!(
        event = "auth.ok.pushed",
        tls = sent_tls,
        nm = sent_nm,
        corr_id = %corr,
        until = until_epoch_secs
    );
}

#[derive(Error, Debug)]
pub enum BridgeError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON serialization error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Frame too large: {0} bytes (max 65536)")]
    FrameTooLarge(usize),
    #[error("Invalid frame format")]
    InvalidFrame,
}

pub struct UnixBridge {
    listener: UnixListener,
    socket_path: String,
    // PR1: Agent gating components
    rate_limiter: Arc<Mutex<crate::ratelimit::RateLimiter>>,
    idempotency: Arc<crate::idempotency::Idempotency>,

    // PR4a: Optional audit writer (None in tests)
    audit: Option<Arc<crate::audit::AuditWriter>>,

    // M1.4: Proximity actor
    _proximity: Arc<Mutex<crate::proximity::Proximity>>,
    _trust: Arc<Mutex<TrustController>>,
}

impl UnixBridge {
    pub async fn new(
        socket_path: &str,
        rate_limiter: Arc<tokio::sync::Mutex<crate::ratelimit::RateLimiter>>,
        idempotency: Arc<crate::idempotency::Idempotency>,
        proximity: Arc<tokio::sync::Mutex<crate::proximity::Proximity>>,
        trust: Arc<tokio::sync::Mutex<TrustController>>,
        audit: Option<Arc<crate::audit::AuditWriter>>,
    ) -> Result<Self, BridgeError> {
        // Ensure parent directory exists
        if let Some(parent) = Path::new(socket_path).parent() {
            if !parent.exists() {
                std::fs::create_dir_all(parent)?;
            }
        }

        // Remove existing socket file if it exists
        if Path::new(socket_path).exists() {
            std::fs::remove_file(socket_path)?;
        }

        let listener = UnixListener::bind(socket_path)?;

        // Set socket permissions to 0600 (owner read/write only)
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(socket_path)?.permissions();
            perms.set_mode(0o600);
            std::fs::set_permissions(socket_path, perms)?;
        }

        info!(role = "agent", cat = "uds", socket = %socket_path, "uds server listening");

        Ok(UnixBridge {
            listener,
            socket_path: socket_path.to_string(),
            rate_limiter,
            idempotency,
            audit,
            _proximity: proximity,
            _trust: trust,
        })
    }

    // PR1: Structured error helper (static method, no self)
    async fn send_error(
        w_arc: &Arc<Mutex<OwnedWriteHalf>>,
        code: u16,
        reason: &str,
        message: &str,
        corr_id: Option<&str>,
        latency_ms: u64,
        extra: Option<Value>,
    ) -> std::io::Result<()> {
        let mut obj = json!({
            "type": "error",
            "err_code": code,
            "err_reason": reason,
            "message": message,
            "latency_ms": latency_ms,
        });
        if let Some(c) = corr_id {
            obj["corr_id"] = json!(c);
        }
        if let Some(extra) = extra {
            obj["extra"] = extra;
        }
        let cid = corr_id.unwrap_or("");
        info!(
            role = "agent",
            cat = "uds",
            event = "msg.send",
            msg_type = "error",
            corr_id = %cid,
            err_code = code,
            err_reason = %reason
        );
        let mut guard = w_arc.lock().await;
        let message_bytes = serde_json::to_vec(&obj)?;
        let length_bytes = (message_bytes.len() as u32).to_be_bytes();
        guard.write_all(&length_bytes).await?;
        guard.write_all(&message_bytes).await?;
        guard.flush().await?;
        Ok(())
    }

    pub async fn run(
        &self,
        pairing_manager: PairingManager,
        vault: Arc<Mutex<Vault>>,
        launcher_manager: Arc<Mutex<LauncherManager>>,
        pending_rekey: Arc<Mutex<Option<PendingRekey>>>,
        auth_state: Arc<Mutex<AuthState>>,
        auth_policy: AuthPolicy,
        policy: Policy,
        sink_registry: Arc<Mutex<SinkRegistry>>,
        proximity: Arc<Mutex<crate::proximity::Proximity>>,
        trust: Arc<Mutex<TrustController>>,
    ) -> Result<(), BridgeError> {
        let _ = &sink_registry;
        if trust_v1_enabled() {
            let trust_for_tick = trust.clone();
            let sinks_for_tick = sink_registry.clone();
            let launcher_for_tick = launcher_manager.clone();
            let audit_for_tick = self.audit.clone();
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(Duration::from_secs(1));
                loop {
                    interval.tick().await;
                    let events = {
                        let mut tstate = trust_for_tick.lock().await;
                        tstate.tick(Instant::now())
                    };
                    let revoked = events.iter().any(|e| e.event == "revoked");
                    let revoked_trust_id = events
                        .iter()
                        .find(|e| e.event == "revoked")
                        .and_then(|e| e.trust_id.clone());
                    let revoked_reason = events
                        .iter()
                        .find(|e| e.event == "revoked")
                        .and_then(|e| e.reason.clone())
                        .unwrap_or_else(|| "revoke".to_string());
                    push_trust_events(&sinks_for_tick, events).await;
                    if revoked {
                        let mut lm = launcher_for_tick.lock().await;
                        lm.cleanup_on_revoke(
                            false,
                            &audit_for_tick,
                            revoked_trust_id.as_deref(),
                            &revoked_reason,
                        )
                        .await;
                    }
                }
            });
        }
        loop {
            match self.listener.accept().await {
                Ok((stream, _)) => {
                    let conn = new_conn_id();
                    info!(role = "agent", cat = "uds", conn = %conn, "uds client connected");

                    // Handle connection in a separate task
                    let mut pairing_manager_clone = pairing_manager.clone();
                    let vault_clone = vault.clone();
                    let rekey_clone = pending_rekey.clone();
                    let auth_clone = auth_state.clone();
                    let policy_clone = policy.clone();
                    let sink_clone = sink_registry.clone();
                    let prox_clone = proximity.clone();
                    let trust_clone = trust.clone();
                    let launcher_clone = launcher_manager.clone();
                    let rl_clone = self.rate_limiter.clone();
                    let idem_clone = self.idempotency.clone();
                    let audit_clone = self.audit.clone();
                    tokio::spawn(async move {
                        let span = tracing::info_span!("uds_conn", role = "agent", cat = "uds", conn = %conn);
                        let _g = span.enter();
                        if let Err(e) = Self::handle_connection(
                            stream,
                            &mut pairing_manager_clone,
                            vault_clone,
                            rekey_clone,
                            auth_clone,
                            auth_policy,
                            policy_clone,
                            sink_clone,
                            prox_clone,
                            trust_clone,
                            launcher_clone,
                            rl_clone,
                            idem_clone,
                            audit_clone,
                        )
                        .await
                        {
                            error!(error = %e, "uds connection error");
                        }
                    });
                }
                Err(e) => {
                    error!(role = "agent", cat = "uds", error = %e, "uds accept failed");
                }
            }
        }
    }

    async fn handle_connection(
        stream: UnixStream,
        pairing_manager: &mut PairingManager,
        vault: Arc<Mutex<Vault>>,
        pending_rekey: Arc<Mutex<Option<PendingRekey>>>,
        auth_state: Arc<Mutex<AuthState>>,
        auth_policy: AuthPolicy,
        policy: Policy,
        sink_registry: Arc<Mutex<SinkRegistry>>,
        proximity: Arc<Mutex<crate::proximity::Proximity>>,
        trust: Arc<Mutex<TrustController>>,
        launcher_manager: Arc<Mutex<LauncherManager>>,
        rate_limiter: Arc<tokio::sync::Mutex<crate::ratelimit::RateLimiter>>,
        idempotency: Arc<crate::idempotency::Idempotency>,
        audit: Option<Arc<crate::audit::AuditWriter>>,
    ) -> Result<(), BridgeError> {
        let (mut reader, writer) = stream.into_split();
        let w_arc = Arc::new(Mutex::new(writer));
        let mut conn_role: Option<SinkRole> = None;

        // Only mark TLS presence after we know this connection is the TLS terminator.
        let mut tls_guard: Option<TlsUpGuard> = None;
        let mut tls_last_seen: Option<Arc<tokio::sync::Mutex<Instant>>> = None;
        let mut tls_hb_stop: Option<tokio::sync::oneshot::Sender<()>> = None;

        // M1.4: Helper to create policy context
        let result = async {
            let mut buffer = vec![0u8; 4];
            let mut sid_opt: Option<String> = None;
            let mut fp_suffix_opt: Option<String> = None;
            let mut corr_id_opt: Option<String> = None;

            loop {
                // M1.4b C1: Old tick handler removed
                // Read frame length (u32 big-endian)
                if let Err(e) = reader.read_exact(&mut buffer).await {
                    if e.kind() == std::io::ErrorKind::UnexpectedEof {
                        info!(role = "agent", cat = "uds", "uds: client disconnected");
                        break;
                    }
                    return Err(BridgeError::Io(e));
                }

                debug!(
                    role = "agent",
                    cat = "uds",
                    bytes = 4,
                    "UDS←LEN {:02x}{:02x}{:02x}{:02x}",
                    buffer[0],
                    buffer[1],
                    buffer[2],
                    buffer[3]
                );
                let frame_length =
                    u32::from_be_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]) as usize;

                // Validate frame size
                if frame_length > 65536 {
                    return Err(BridgeError::FrameTooLarge(frame_length));
                }

                if frame_length == 0 {
                    return Err(BridgeError::InvalidFrame);
                }

                // Read frame data
                let mut frame_data = vec![0u8; frame_length];
                reader.read_exact(&mut frame_data).await?;
                let dump = {
                    let hex = hex::encode(&frame_data);
                    if hex.len() > 128 {
                        format!("{}… [redacted]", &hex[..128])
                    } else {
                        hex
                    }
                };
                debug!(role = "agent", cat = "uds", bytes = frame_data.len(), dump = %dump, "UDS←BODY");

                // Parse JSON message
                let message_str = String::from_utf8_lossy(&frame_data);
                debug!(role = "agent", cat = "uds", "received message");

                let response = match serde_json::from_str::<Value>(&message_str) {
                    Ok(json_msg) => {
                        // PR1: Start latency tracking
                        let started = Instant::now();

                        // ✅ LOG EVERY INBOUND MESSAGE
                        let msg_type = json_msg.get("type").and_then(|v| v.as_str()).unwrap_or("<no_type>");
                        let msg_corr = json_msg.get("corr_id").and_then(|v| v.as_str()).unwrap_or("");
                        info!(role = "agent", cat = "uds", event = "msg.recv", msg_type = %msg_type, corr_id = %msg_corr);

                        // ✅ FIX: Update corr_id on EVERY message (not just first)
                        if let Some(cid) = json_msg.get("corr_id").and_then(|v| v.as_str()) {
                            corr_id_opt = Some(cid.to_string());
                        }

                        // PR1: Rate limiting check (before any routing)
                        if should_rate_limit(msg_type) {
                            if let Some(origin) = extract_origin(&json_msg) {
                                let mut rl = rate_limiter.lock().await;
                                if !rl.allow_origin(&origin) {
                                    let _ = Self::send_error(
                                        &w_arc,
                                        429,
                                        "too_many_requests",
                                        "Rate limit exceeded",
                                        corr_id_opt.as_deref(),
                                        started.elapsed().as_millis() as u64,
                                        Some(json!({"origin": origin, "type": msg_type}))
                                    ).await;
                                    continue;
                                }
                            }
                        }

                        // idle timeout tick
                        {
                            let mut v = vault.lock().await;
                            v.tick_idle();
                        }
                        // Update session context on first message
                        if sid_opt.is_none() {
                            if let Some(sid) = json_msg.get("sid").and_then(|v| v.as_str()) {
                                sid_opt = Some(sid.to_string());
                            }
                            if let Some(fp) = json_msg.get("fp_suffix").and_then(|v| v.as_str()) {
                                fp_suffix_opt = Some(fp.to_string());
                            }
                            if sid_opt.is_some() || fp_suffix_opt.is_some() {
                                info!(role = "agent", cat = "uds", sid = ?sid_opt, fp_suffix = ?fp_suffix_opt, corr_id = ?corr_id_opt, "context set from first message");
                            }
                        }
                        // Route messages
                        if let Some(t) = json_msg.get("type").and_then(|v| v.as_str()) {
                            if t == "uds.hello" {
                                let role_str = json_msg
                                    .get("role")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("unknown");
                                let maybe_role = match role_str {
                                    "tls" => Some(SinkRole::Tls),
                                    "nm" => Some(SinkRole::Nm),
                                    _ => None,
                                };
                                match maybe_role {
                                    Some(role) => {
                                        info!(event = "uds.hello.recv", role = %role_str, ok = true);
                                        // M1.4b C2: Create TLS presence guard only for TLS role
                                        if matches!(role, SinkRole::Tls) && tls_guard.is_none() {
                                            tls_guard = Some(TlsUpGuard::enter(proximity.clone()).await);
                                        }
                                        // Start TLS heartbeat watchdog to flip proximity to FAR when device link dies.
                                        if matches!(role, SinkRole::Tls) && tls_last_seen.is_none() {
                                        let last_seen = Arc::new(tokio::sync::Mutex::new(Instant::now()));
                                        tls_last_seen = Some(last_seen.clone());
                                        let prox_clone = proximity.clone();
                                        let vault_clone = vault.clone();
                                        let (tx, mut rx) = tokio::sync::oneshot::channel();
                                        tls_hb_stop = Some(tx);
                                        tokio::spawn(async move {
                                            let mut interval = tokio::time::interval(Duration::from_millis(1000));
                                            loop {
                                                    tokio::select! {
                                                        _ = interval.tick() => {
                                                            let now = Instant::now();
                                                            let last = {
                                                                let l = last_seen.lock().await;
                                                                *l
                                                            };
                                                            let mut p = prox_clone.lock().await;
                                                            let grace = p.grace();
                                                            if now.duration_since(last) >= grace {
                                                                p.on_tls_down(now, Some(last));
                                                                p.tick(now); // finalize to FAR if deadline reached
                                                                if matches!(p.state(), ProxState::Far) {
                                                                    // Lock vault defensively when we drop to Far
                                                                    let mut v = vault_clone.lock().await;
                                                                    let _ = v.lock();
                                                                }
                                                            }
                                                        }
                                                        _ = &mut rx => break,
                                                    }
                                                }
                                            });
                                        }
                                        let mut guard = sink_registry.lock().await;
                                        let replaced =
                                            guard.register(role, w_arc.clone());
                                        if replaced.is_some() {
                                            info!(event = "uds.role.replace", role = %role_str);
                                        }
                                        conn_role = Some(role);
                                        let _ = send_json(
                                            &w_arc,
                                            &json!({
                                                "type":"uds.hello.ack",
                                                "ok": true,
                                                "role": role_str
                                            }),
                                        )
                                        .await;
                                    }
                                    None => {
                                        info!(
                                            event = "uds.hello.recv",
                                            role = %role_str,
                                            ok = false,
                                            reason = "bad_role"
                                        );
                                        let _ = send_json(
                                            &w_arc,
                                            &json!({
                                                "type":"uds.hello.ack",
                                                "ok": false,
                                                "error":"BAD_ROLE"
                                            }),
                                        )
                                        .await;
                                    }
                                }
                                continue;
                            }
                            match t {
                            "tls.down" => {
                                // Explicit signal from TLS that link is down: force prox to Far
                                let now = Instant::now();
                                {
                                    let mut prox = proximity.lock().await;
                                    prox.on_tls_down(now, None);
                                    prox.tick(now);
                                }
                                // Hard lock vault when link is down to prevent fills
                                {
                                    let mut v = vault.lock().await;
                                    let _ = v.lock();
                                }
                                continue;
                            }
                            "prox.heartbeat" => {
                                // Only accept heartbeats from TLS role
                                if !matches!(conn_role, Some(SinkRole::Tls)) {
                                    let resp = serde_json::json!({"type":"prox.ack","op":"heartbeat","ok":false,"err_reason":"not_tls"});
                                    Self::send_message(&w_arc, &resp).await?;
                                    continue;
                                }
                                // TLS process should send this periodically while device link is healthy.
                                if let Some(ls) = tls_last_seen.as_ref() {
                                    let mut l = ls.lock().await;
                                    *l = Instant::now();
                                }
                                {
                                    let mut prox = proximity.lock().await;
                                    let now = Instant::now();
                                    match prox.state() {
                                        crate::proximity::ProxState::Far => prox.on_tls_up(now),
                                        crate::proximity::ProxState::Paused => prox.record_heartbeat(now),
                                        crate::proximity::ProxState::NearLocked | crate::proximity::ProxState::NearUnlocked => prox.record_heartbeat(now),
                                    }
                                }
                                let resp = serde_json::json!({"type":"prox.ack","op":"heartbeat","ok":true});
                                Self::send_message(&w_arc, &resp).await?;
                                continue;
                            }
                            "vault.open" => {
                                let scope = "vault.open".to_string();
                                let mctx = MatchCtx {
                                    origin: None,
                                    app: None,
                                    action: Some("vault.open".into()),
                                    cmd: None,
                                    scope: scope.clone(),
                                };
                                if let Some(auth_req) =
                                    require_auth_if_needed(
                                        &auth_policy,
                                        &auth_state,
                                        &policy,
                                        &scope,
                                        &mctx,
                                        corr_id_opt.as_ref(),
                                        sid_opt.as_ref(),
                                        &proximity,
                                        SystemTime::now(),
                                    )
                                    .await
                                {
                                    // require_auth_if_needed already returned auth.request - just send it
                                    auth_req
                                } else {
                                    let eng = base64::engine::general_purpose::STANDARD;
                                    if let Some(kb64) =
                                        json_msg.get("k_session_b64").and_then(|v| v.as_str())
                                    {
                                        match eng.decode(kb64) {
                                            Ok(bytes) if bytes.len() == 32 => {
                                                let mut k = [0u8; 32];
                                                k.copy_from_slice(&bytes);
                                                // Derive stable wrap key using agent SK and iOS wrap pub (if available)
                                                let mut v = vault.lock().await;
                                                // Require device_fp to locate paired pubkey
                                                let device_fp = json_msg
                                                    .get("device_fp")
                                                    .and_then(|v| v.as_str())
                                                    .unwrap_or("");
                                                if !device_fp.is_empty() {
                                                    if let Some(ios_pub) = pairing_manager
                                                        .get_ios_wrap_pub_by_fp(device_fp)
                                                    {
                                                        // salt = SHA256("armadillo-wrap-salt-v1" || device_fp)
                                                        let mut hasher = Sha256::new();
                                                        hasher.update(b"armadillo-wrap-salt-v1");
                                                        hasher.update(device_fp.as_bytes());
                                                        let salt = hasher.finalize();
                                                        match ensure_agent_wrap_secret() {
                                                            Ok(sk) => {
                                                                // Normalize iOS pub: accept 65-byte SEC1 (0x04||x||y) or 64-byte (x||y) and prepend 0x04
                                                                let mut sec1_buf: Vec<u8> =
                                                                    Vec::new();
                                                                if ios_pub.len() == 65
                                                                    && ios_pub[0] == 0x04
                                                                {
                                                                    sec1_buf
                                                                        .extend_from_slice(ios_pub);
                                                                } else if ios_pub.len() == 64 {
                                                                    sec1_buf.push(0x04);
                                                                    sec1_buf
                                                                        .extend_from_slice(ios_pub);
                                                                    let fp_suf = if device_fp.len()
                                                                        > 12
                                                                    {
                                                                        &device_fp
                                                                            [device_fp.len() - 12..]
                                                                    } else {
                                                                        device_fp
                                                                    };
                                                                    info!(role = "agent", cat = "wrap", fp_suffix = %fp_suf, "wrap.normalize_pub_64_to_sec1");
                                                                } else {
                                                                    let fp_suf = if device_fp.len()
                                                                        > 12
                                                                    {
                                                                        &device_fp
                                                                            [device_fp.len() - 12..]
                                                                    } else {
                                                                        device_fp
                                                                    };
                                                                    error!(role = "agent", cat = "wrap", fp_suffix = %fp_suf, len = ios_pub.len(), first = ios_pub.get(0).copied().unwrap_or(0xff), "wrap.pub_invalid_format");
                                                                    sec1_buf.clear();
                                                                }

                                                                match derive_wrap_key(
                                                                    &sk, &sec1_buf, &salt,
                                                                ) {
                                                                    Ok(k_wrap) => {
                                                                        v.set_wrap_key(k_wrap);
                                                                        let fp_suf =
                                                                            if device_fp.len() > 12
                                                                            {
                                                                                &device_fp[device_fp
                                                                                    .len()
                                                                                    - 12..]
                                                                            } else {
                                                                                device_fp
                                                                            };
                                                                        info!(role = "agent", cat = "wrap", fp_suffix = %fp_suf, "wrap.derived");
                                                                    }
                                                                    Err(e) => {
                                                                        let fp_suf =
                                                                            if device_fp.len() > 12
                                                                            {
                                                                                &device_fp[device_fp
                                                                                    .len()
                                                                                    - 12..]
                                                                            } else {
                                                                                device_fp
                                                                            };
                                                                        error!(role = "agent", cat = "wrap", fp_suffix = %fp_suf, err = ?e, "wrap.derive_failed");
                                                                    }
                                                                }
                                                            }
                                                            Err(e) => {
                                                                error!(role = "agent", cat = "wrap", err = ?e, "wrap.ensure_agent_sk_failed");
                                                            }
                                                        }
                                                    }
                                                }
                                                let ok = v.open(k).is_ok();
                                                if let Some(cid) = &corr_id_opt {
                                                    serde_json::json!({"type":"vault.ack","op":"open","ok":ok,"corr_id":cid})
                                                } else {
                                                    serde_json::json!({"type":"vault.ack","op":"open","ok":ok})
                                                }
                                            }
                                            _ => {
                                                error_with_corr(
                                                    "INVALID_KEY",
                                                    "k_session must be 32 bytes b64",
                                                    corr_id_opt.as_ref(),
                                                )
                                            }
                                        }
                                    } else {
                                        error_with_corr(
                                            "MISSING_FIELD",
                                            "k_session_b64 missing",
                                            corr_id_opt.as_ref(),
                                        )
                                    }
                                }
                            }
                            "vault.read" => {
                                let step = policy.requires_step_up("", "vault.read");
                                match remote_or_proximity_gate(&proximity, &trust, &auth_state, step).await
                                {
                                    Ok(()) => {}
                                    Err((reason, code)) => {
                                        // Push auth.request to iOS on gate failures to trigger Face ID
                                        if matches!(reason, "session_unlock_required" | "prox_intent_required" | "proximity_far" | "trust_locked") {
                                            push_auth_request(&sink_registry, corr_id_opt.as_deref()).await;
                                        }
                                        let err = serde_json::json!({
                                            "type": "error",
                                            "err_code": code,
                                            "err_reason": reason,
                                            "corr_id": corr_id_opt.clone().unwrap_or_default()
                                        });
                                        Self::send_message(&w_arc, &err).await?;
                                        continue;
                                    }
                                }

                                // M1.5: Enforce session TTL
                                let session_valid = {
                                    let auth = auth_state.lock().await;
                                    auth.check_session().is_ok()
                                };
                                if !session_valid {
                                    let err = serde_json::json!({
                                        "type": "error",
                                        "err_code": 401,
                                        "err_reason": "token_expired",
                                        "message": "Session expired, step-up required",
                                        "corr_id": corr_id_opt.as_deref().unwrap_or(""),
                                    });
                                    Self::send_message(&w_arc, &err).await?;
                                    continue;
                                }

                                let key = json_msg.get("key").and_then(|v| v.as_str());
                                if let Some(key) = key {
                                    let scope = format!("vault.read:{}", key);
                                    let mctx = MatchCtx {
                                        origin: None,
                                        app: None,
                                        action: Some("vault.read".into()),
                                        cmd: None,
                                        scope: scope.clone(),
                                    };
                                    if let Some(auth_req) =
                                        require_auth_if_needed(
                                            &auth_policy,
                                            &auth_state,
                                            &policy,
                                            &scope,
                                            &mctx,
                                            corr_id_opt.as_ref(),
                                            sid_opt.as_ref(),
                                            &proximity,
                                            SystemTime::now(),
                                        )
                                        .await
                                    {
                                        // Nudge iOS for Face ID and return auth.request
                                        push_auth_request(&sink_registry, corr_id_opt.as_deref()).await;
                                        auth_req
                                    } else {
                                        let mut v = vault.lock().await;
                                        match v.read(key) {
                                            Ok(val) => {
                                                if let Some(cid) = &corr_id_opt {
                                                    serde_json::json!({"type":"vault.value","key":key,"value_b64": base64::engine::general_purpose::STANDARD.encode(val), "corr_id": cid})
                                                } else {
                                                    serde_json::json!({"type":"vault.value","key":key,"value_b64": base64::engine::general_purpose::STANDARD.encode(val)})
                                                }
                                            }
                                            Err(VaultError::NotFound) => {
                                                // return a quiet miss instead of an error
                                                if let Some(cid) = &corr_id_opt {
                                                    serde_json::json!({"type":"vault.value","key":key,"status":"miss","corr_id":cid})
                                                } else {
                                                    serde_json::json!({"type":"vault.value","key":key,"status":"miss"})
                                                }
                                            }
                                            Err(VaultError::Locked) => {
                                                // surface locked as a status to avoid noisy errors in dev buttons
                                                if let Some(cid) = &corr_id_opt {
                                                    serde_json::json!({"type":"vault.value","key":key,"status":"locked","corr_id":cid})
                                                } else {
                                                    serde_json::json!({"type":"vault.value","key":key,"status":"locked"})
                                                }
                                            }
                                            Err(e) => error_with_corr(
                                                &format!("{:?}", e),
                                                "vault read failed",
                                                corr_id_opt.as_ref(),
                                            ),
                                        }
                                    }
                                } else {
                                    error_with_corr(
                                        "MISSING_FIELD",
                                        "key missing",
                                        corr_id_opt.as_ref(),
                                    )
                                }
                            }
                            "vault.write" => {
                                // PR1: Check idempotency key first
                                let idem_key = match json_msg.get("idempotency_key").and_then(|v| v.as_str()) {
                                    Some(k) => k,
                                    None => {
                                        info!(
                                            role = "agent",
                                            cat = "uds",
                                            event = "msg.send",
                                            msg_type = "error",
                                            corr_id = %corr_id_opt.clone().unwrap_or_default(),
                                            err_code = 400,
                                            err_reason = "bad_request",
                                            detail = "idempotency_key missing"
                                        );
                                        let _ = Self::send_error(
                                            &w_arc, 400, "bad_request", "idempotency_key required for writes",
                                            corr_id_opt.as_deref(), 0, None
                                        ).await;
                                        continue;
                                    }
                                };

                                let step = policy.requires_step_up("", "vault.write");
                                match remote_or_proximity_gate(&proximity, &trust, &auth_state, step).await
                                {
                                    Ok(()) => {}
                                    Err((reason, code)) => {
                                        // Push auth.request to iOS on gate failures to trigger Face ID
                                        if matches!(reason, "session_unlock_required" | "prox_intent_required" | "proximity_far" | "trust_locked") {
                                            push_auth_request(&sink_registry, corr_id_opt.as_deref()).await;
                                        }
                                        let err = serde_json::json!({
                                            "type": "error",
                                            "err_code": code,
                                            "err_reason": reason,
                                            "corr_id": corr_id_opt.clone().unwrap_or_default()
                                        });
                                        Self::send_message(&w_arc, &err).await?;
                                        continue;
                                    }
                                }

                                // M1.5: Enforce session TTL
                                let session_valid = {
                                    let auth = auth_state.lock().await;
                                    auth.check_session().is_ok()
                                };
                                if !session_valid {
                                    let err = serde_json::json!({
                                        "type": "error",
                                        "err_code": 401,
                                        "err_reason": "token_expired",
                                        "message": "Session expired, step-up required",
                                        "corr_id": corr_id_opt.as_deref().unwrap_or(""),
                                    });
                                    Self::send_message(&w_arc, &err).await?;
                                    continue;
                                }

                                // PR1: Replay fast-path
                                if idempotency.was_applied(idem_key).unwrap_or(false) {
                                    info!(
                                        role = "agent",
                                        cat = "idempotency",
                                        event = "replay",
                                        corr_id = %corr_id_opt.clone().unwrap_or_default(),
                                        key = %idem_key
                                    );
                                    serde_json::json!({
                                        "type":"vault.ack","op":"write","ok":true,"replayed":true,
                                        "corr_id": corr_id_opt.as_deref().unwrap_or("")
                                    })
                                } else {
                                    // Continue with existing auth + write path
                                    let scope = "vault.write".to_string();
                                    let mctx = MatchCtx {
                                        origin: None,
                                        app: None,
                                        action: Some("vault.write".into()),
                                        cmd: None,
                                        scope: scope.clone(),
                                    };
                                    if let Some(auth_req) =
                                        require_auth_if_needed(
                                            &auth_policy,
                                            &auth_state,
                                            &policy,
                                            &scope,
                                            &mctx,
                                            corr_id_opt.as_ref(),
                                            sid_opt.as_ref(),
                                            &proximity,
                                            SystemTime::now(),
                                        )
                                        .await
                                    {
                                        // Nudge iOS for Face ID and return auth.request
                                        push_auth_request(&sink_registry, corr_id_opt.as_deref()).await;
                                        auth_req
                                    } else {
                                    let key = json_msg.get("key").and_then(|v| v.as_str());
                                    let vb64 = json_msg.get("value_b64").and_then(|v| v.as_str());
                                    if let (Some(key), Some(vb64)) = (key, vb64) {
                                        match base64::engine::general_purpose::STANDARD.decode(vb64)
                                        {
                                            Ok(val) => {
                                                let mut v = vault.lock().await;
                                                match v.write(key, &val) {
                                                    Ok(_) => {
                                                        // PR1: Mark idempotency key as applied after successful write
                                                        let _ = idempotency.mark_applied(idem_key);
                                                        if let Some(cid) = &corr_id_opt {
                                                            serde_json::json!({"type":"vault.ack","op":"write","ok":true,"corr_id":cid})
                                                        } else {
                                                            serde_json::json!({"type":"vault.ack","op":"write","ok":true})
                                                        }
                                                    }
                                                    Err(VaultError::Locked) => {
                                                        if let Some(cid) = &corr_id_opt {
                                                            serde_json::json!({"type":"vault.ack","op":"write","status":"locked","corr_id":cid})
                                                        } else {
                                                            serde_json::json!({"type":"vault.ack","op":"write","status":"locked"})
                                                        }
                                                    }
                                                    Err(_) => {
                                                        if let Some(cid) = &corr_id_opt {
                                                            serde_json::json!({"type":"vault.ack","op":"write","ok":false,"corr_id":cid})
                                                        } else {
                                                            serde_json::json!({"type":"vault.ack","op":"write","ok":false})
                                                        }
                                                    }
                                                }
                                            }
                                            Err(_) => {
                                                error_with_corr(
                                                    "INVALID_VALUE",
                                                    "value_b64 invalid",
                                                    corr_id_opt.as_ref(),
                                                )
                                            }
                                        }
                                    } else {
                                        error_with_corr(
                                            "MISSING_FIELD",
                                            "key or value_b64 missing",
                                            corr_id_opt.as_ref(),
                                        )
                                    }
                                }
                            }
                            }
                            "vault.lock" => {
                                let mut v = vault.lock().await;
                                let _ = v.lock();
                                if let Some(cid) = &corr_id_opt {
                                    serde_json::json!({"type":"vault.ack","op":"lock","ok":true,"corr_id":cid})
                                } else {
                                    serde_json::json!({"type":"vault.ack","op":"lock","ok":true})
                                }
                            }
                            "vault.status" => {
                                let v = vault.lock().await;
                                let (unl, cnt, idle_ms) = v.status();
                                if let Some(cid) = &corr_id_opt {
                                    serde_json::json!({"type":"vault.ack","op":"status","ok":true,"unlocked":unl,"entries":cnt,"idle_ms":idle_ms,"corr_id":cid})
                                } else {
                                    serde_json::json!({"type":"vault.ack","op":"status","ok":true,"unlocked":unl,"entries":cnt,"idle_ms":idle_ms})
                                }
                            }
                            "host.sleep" => {
                                // * lock on sleep
                                let mut v = vault.lock().await;
                                let ok = v.lock().is_ok();
                                info!(event = "lock.sleep", ok = ok);
                                if let Some(cid) = &corr_id_opt {
                                    serde_json::json!({"type":"vault.ack","op":"host.sleep","ok":ok,"corr_id":cid})
                                } else {
                                    serde_json::json!({"type":"vault.ack","op":"host.sleep","ok":ok})
                                }
                            }
                            "recovery.phrase.generate" => {
                                // *
                                let _phrase = generate_mnemonic_12();
                                info!(event = "recovery.phrase.generated", words = 12);
                                let reason = json_msg
                                    .get("reason")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("manual");
                                let countdown = json_msg
                                    .get("countdown_secs")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(30);
                                let v = vault.lock().await;
                                if v.is_locked() {
                                    error_with_corr(
                                        "VAULT_LOCKED",
                                        "unlock required",
                                        corr_id_opt.as_ref(),
                                    )
                                } else {
                                    let tok = uuid::Uuid::new_v4();
                                    {
                                        let mut st = pending_rekey.lock().await;
                                        *st = Some(PendingRekey {
                                            token: tok,
                                            started: std::time::Instant::now(),
                                            countdown: std::time::Duration::from_secs(countdown),
                                            reason: reason.to_string(),
                                        });
                                    }
                                    info!(event = "rekey.started", token = %tok, countdown = countdown, reason = %reason);
                                    if let Some(cid) = &corr_id_opt {
                                        serde_json::json!({"type":"vault.ack","op":"rekey.start","ok":true, "token": tok.to_string(),"corr_id":cid})
                                    } else {
                                        serde_json::json!({"type":"vault.ack","op":"rekey.start","ok":true, "token": tok.to_string()})
                                    }
                                }
                            }
                            "vault.rekey.abort" => {
                                // *
                                let tok = json_msg
                                    .get("token")
                                    .and_then(|v| v.as_str())
                                    .and_then(|s| uuid::Uuid::parse_str(s).ok());
                                if let Some(tok) = tok {
                                    let mut st = pending_rekey.lock().await;
                                    if let Some(p) = st.as_ref() {
                                        if p.token == tok {
                                            *st = None;
                                            info!(event = "rekey.aborted", token = %tok, reason = "cancelled");
                                            if let Some(cid) = &corr_id_opt {
                                                serde_json::json!({"type":"vault.ack","op":"rekey.abort","ok":true,"corr_id":cid})
                                            } else {
                                                serde_json::json!({"type":"vault.ack","op":"rekey.abort","ok":true})
                                            }
                                        } else {
                                            error_with_corr(
                                                "REKEY_CONFLICT",
                                                "token mismatch",
                                                corr_id_opt.as_ref(),
                                            )
                                        }
                                    } else {
                                        error_with_corr(
                                            "REKEY_CONFLICT",
                                            "no matching rekey",
                                            corr_id_opt.as_ref(),
                                        )
                                    }
                                } else {
                                    error_with_corr("BAD_TOKEN", "token missing/invalid", corr_id_opt.as_ref())
                                }
                            }
                            "vault.rekey.commit" => {
                                // *
                                let tok_opt = json_msg
                                    .get("token")
                                    .and_then(|v| v.as_str())
                                    .and_then(|s| uuid::Uuid::parse_str(s).ok());
                                if let Some(tok) = tok_opt {
                                    let start = std::time::Instant::now();
                                    let mut st = pending_rekey.lock().await;
                                    if let Some(p) = st.clone() {
                                        if p.token != tok {
                                            error_with_corr(
                                                "REKEY_CONFLICT",
                                                "token mismatch",
                                                corr_id_opt.as_ref(),
                                            )
                                        } else if p.expired() {
                                            *st = None;
                                            info!(event = "rekey.aborted", token = %tok, reason = "timeout");
                                            error_with_corr(
                                                "REKEY_EXPIRED",
                                                "countdown elapsed",
                                                corr_id_opt.as_ref(),
                                            )
                                        } else {
                                            drop(st);
                                            let mut v = vault.lock().await;
                                            let _ = v.rekey_in_place();
                                            let elapsed = start.elapsed().as_millis();
                                            let mut st2 = pending_rekey.lock().await;
                                            *st2 = None;
                                            info!(event = "rekey.committed", token = %tok, elapsed_ms = elapsed, old_ver = 3, new_ver = 3);
                                            if let Some(cid) = &corr_id_opt {
                                                serde_json::json!({"type":"vault.ack","op":"rekey.commit","ok":true, "token": tok.to_string(),"corr_id":cid})
                                            } else {
                                                serde_json::json!({"type":"vault.ack","op":"rekey.commit","ok":true, "token": tok.to_string()})
                                            }
                                        }
                                    } else {
                                        error_with_corr(
                                            "REKEY_CONFLICT",
                                            "no pending rekey",
                                            corr_id_opt.as_ref(),
                                        )
                                    }
                                } else {
                                    error_with_corr("BAD_TOKEN", "token missing/invalid", corr_id_opt.as_ref())
                                }
                            }
                            "ble.k_ble" => {
                                // * derive BLE key for device_fp
                                if let Some(device_fp) =
                                    json_msg.get("device_fp").and_then(|v| v.as_str())
                                {
                                    if let Some(ios_pub) =
                                        pairing_manager.get_or_load_ios_wrap_pub_vec(device_fp)
                                    {
                                        // Normalize pub
                                        let mut sec1_buf: Vec<u8> = Vec::new();
                                        if ios_pub.len() == 65 && ios_pub[0] == 0x04 {
                                            sec1_buf.extend_from_slice(&ios_pub);
                                        } else if ios_pub.len() == 64 {
                                            sec1_buf.push(0x04);
                                            sec1_buf.extend_from_slice(&ios_pub);
                                        }
                                        // salt = SHA256("arm-ble-salt-v1" || fp_bytes_32)
                                        // iOS uses hex-decoded fingerprint bytes (32 bytes), not string
                                        let fp_clean = device_fp.strip_prefix("sha256:").unwrap_or(device_fp);
                                        let fp_bytes = match hex::decode(fp_clean) {
                                            Ok(bytes) if bytes.len() == 32 => bytes,
                                            _ => {
                                                warn!(
                                                   event = "ble.salt.invalid_fp",
                                                   fp = %device_fp
                                                );
                                                vec![0u8; 32]
                                            }
                                        };
                                        
                                        let mut hasher = Sha256::new();
                                        hasher.update(b"arm-ble-salt-v1");
                                        hasher.update(&fp_bytes);
                                        let salt_hash = hasher.finalize();
                                        let salt: [u8; 32] = salt_hash.into();
                                        match ensure_agent_wrap_secret() {
                                            Ok(sk) => {
                                                if let Ok(k_ble) =
                                                    derive_ble_key(&sk, &sec1_buf, &salt)
                                                {
                                                    let k_b64 =
                                                        base64::engine::general_purpose::STANDARD
                                                            .encode(k_ble);
                                                    serde_json::json!({"type":"ble.k_ble","ok":true,"k_ble_b64":k_b64})
                                                } else {
                                                    error_with_corr(
                                                        "BLE_DERIVE_FAILED",
                                                        "failed to derive k_ble",
                                                        corr_id_opt.as_ref(),
                                                    )
                                                }
                                            }
                                            Err(_) => {
                                                error_with_corr(
                                                    "AGENT_SK_MISSING",
                                                    "agent wrap secret missing",
                                                    corr_id_opt.as_ref(),
                                                )
                                            }
                                        }
                                    } else {
                                        error_with_corr(
                                            "NO_IOS_PUB",
                                            "ios wrap pub missing",
                                            corr_id_opt.as_ref(),
                                        )
                                    }
                                } else {
                                    error_with_corr(
                                        "MISSING_FIELD",
                                        "device_fp missing",
                                        corr_id_opt.as_ref(),
                                    )
                                }
                            }
                            "trust.verify_request" => {
                                if !trust_v1_enabled() {
                                    json!({
                                        "type":"trust.verify_response",
                                        "v": 1,
                                        "corr_id": corr_id_opt.clone().unwrap_or_default(),
                                        "ts_ms": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
                                        "ok": false,
                                        "deny": { "reason":"policy_reject", "detail":"ARM_TRUST_V1 disabled" }
                                    })
                                } else {
                                    let corr = corr_id_opt.clone().unwrap_or_default();
                                    let phone_fp = json_msg
                                        .get("phone_fp")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let mode_req = parse_trust_mode(json_msg.get("mode").and_then(|v| v.as_str()));
                                    let ttl_effective = clamp_ttl(json_msg.get("ttl_secs").and_then(|v| v.as_u64()));

                                    let nonce_b64 = json_msg
                                        .get("challenge")
                                        .and_then(|v| v.get("nonce_b64"))
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("");
                                    let proof_b64 = json_msg
                                        .get("proof")
                                        .and_then(|v| v.get("proof_b64"))
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("");

                                    let nonce = base64::engine::general_purpose::STANDARD
                                        .decode(nonce_b64)
                                        .unwrap_or_default();
                                    let proof = base64::engine::general_purpose::STANDARD
                                        .decode(proof_b64)
                                        .unwrap_or_default();

                                    if phone_fp.is_empty() || nonce.len() != 16 || proof.len() != 32 {
                                        json!({
                                            "type":"trust.verify_response",
                                            "v": 1,
                                            "corr_id": corr,
                                            "ts_ms": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
                                            "ok": false,
                                            "deny": { "reason":"policy_reject", "detail":"missing or invalid trust fields" }
                                        })
                                    } else if let Some(k_ble) = derive_k_ble_for_phone(pairing_manager, &phone_fp) {
                                        type HmacSha256 = Hmac<Sha256>;
                                        let mut mac = HmacSha256::new_from_slice(&k_ble).expect("HMAC init failed");
                                        mac.update(b"PROOF");
                                        mac.update(&nonce);
                                        mac.update(corr.as_bytes());
                                        mac.update(phone_fp.as_bytes());
                                        mac.update(&ttl_effective.to_be_bytes());
                                        let expected = mac.finalize().into_bytes();
                                        if &expected[..] != proof.as_slice() {
                                            json!({
                                                "type":"trust.verify_response",
                                                "v": 1,
                                                "corr_id": corr,
                                                "ts_ms": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
                                                "ok": false,
                                                "deny": { "reason":"hmac_invalid", "detail":"proof mismatch" }
                                            })
                                        } else {
                                            let tid = trust_id();
                                            let ev = {
                                                let mut tstate = trust.lock().await;
                                                tstate.grant(Instant::now(), tid.clone(), mode_req, ttl_effective)
                                            };
                                            push_trust_events(&sink_registry, ev).await;
                                            json!({
                                                "type":"trust.verify_response",
                                                "v": 1,
                                                "corr_id": corr,
                                                "ts_ms": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
                                                "ok": true,
                                                "grant": {
                                                    "trust_id": tid,
                                                    "mode": mode_req,
                                                    "trust_until_ms": Value::Null,
                                                    "ttl_secs_effective": ttl_effective,
                                                    "policy": { "ttl_cap_secs": 3600, "rssi_min_dbm": -90 }
                                                }
                                            })
                                        }
                                    } else {
                                        json!({
                                            "type":"trust.verify_response",
                                            "v": 1,
                                            "corr_id": corr,
                                            "ts_ms": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
                                            "ok": false,
                                            "deny": { "reason":"unknown_device", "detail":"phone_fp not paired or key derivation failed" }
                                        })
                                    }
                                }
                            }
                            "trust.signal_lost" => {
                                if trust_v1_enabled() {
                                    let ev = {
                                        let mut tstate = trust.lock().await;
                                        tstate.signal_lost(Instant::now())
                                    };
                                    let revoked_trust_id = ev
                                        .iter()
                                        .find(|e| e.event == "revoked")
                                        .and_then(|e| e.trust_id.clone());
                                    let revoked_reason = ev
                                        .iter()
                                        .find(|e| e.event == "revoked")
                                        .and_then(|e| e.reason.clone())
                                        .unwrap_or_else(|| "revoke".to_string());
                                    push_trust_events(&sink_registry, ev.clone()).await;
                                    if ev.iter().any(|e| e.event == "revoked") {
                                        let mut lm = launcher_manager.lock().await;
                                        lm.cleanup_on_revoke(
                                            false,
                                            &audit,
                                            revoked_trust_id.as_deref(),
                                            &revoked_reason,
                                        )
                                        .await;
                                    }
                                }
                                json!({
                                    "type":"trust.ack",
                                    "op":"signal_lost",
                                    "ok": true,
                                    "corr_id": corr_id_opt.clone().unwrap_or_default()
                                })
                            }
                            "trust.signal_present" => {
                                if trust_v1_enabled() {
                                    let ev = {
                                        let mut tstate = trust.lock().await;
                                        tstate.signal_present(Instant::now())
                                    };
                                    push_trust_events(&sink_registry, ev).await;
                                }
                                json!({
                                    "type":"trust.ack",
                                    "op":"signal_present",
                                    "ok": true,
                                    "corr_id": corr_id_opt.clone().unwrap_or_default()
                                })
                            }
                            "trust.revoke" => {
                                if trust_v1_enabled() {
                                    let reason = json_msg
                                        .get("reason")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("manual_end");
                                    let ev = {
                                        let mut tstate = trust.lock().await;
                                        tstate.revoke(Instant::now(), reason)
                                    };
                                    let revoked_trust_id = ev
                                        .iter()
                                        .find(|e| e.event == "revoked")
                                        .and_then(|e| e.trust_id.clone());
                                    push_trust_events(&sink_registry, ev.clone()).await;
                                    if ev.iter().any(|e| e.event == "revoked") {
                                        let mut lm = launcher_manager.lock().await;
                                        lm.cleanup_on_revoke(
                                            true,
                                            &audit,
                                            revoked_trust_id.as_deref(),
                                            "manual_end",
                                        )
                                        .await;
                                    }
                                }
                                json!({
                                    "type":"trust.revoke_ack",
                                    "v": 1,
                                    "corr_id": corr_id_opt.clone().unwrap_or_default(),
                                    "ts_ms": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
                                    "ok": true
                                })
                            }
                            "trust.status" => {
                                let snapshot = {
                                    let tstate = trust.lock().await;
                                    tstate.status()
                                };
                                json!({
                                    "type":"trust.status_response",
                                    "v": 1,
                                    "corr_id": corr_id_opt.clone().unwrap_or_default(),
                                    "ts_ms": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
                                    "state": snapshot.state,
                                    "mode": snapshot.mode,
                                    "signal": snapshot.signal,
                                    "trust_id": snapshot.trust_id,
                                    "trust_until_ms": snapshot.trust_until_ms,
                                    "deadline_ms": snapshot.deadline_ms,
                                    "active": { "mounted": false, "running_pids": Vec::<u32>::new() }
                                })
                            }
                            "trust.config.get" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let cfg = {
                                    let tstate = trust.lock().await;
                                    tstate.config()
                                };
                                json!({
                                    "type":"trust.config.get",
                                    "corr_id": corr,
                                    "ok": true,
                                    "mode": cfg.mode,
                                    "background_ttl_secs": cfg.background_ttl_secs,
                                    "office_idle_secs": cfg.office_idle_secs
                                })
                            }
                            "trust.config.set" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let mode = parse_trust_mode(json_msg.get("mode").and_then(|v| v.as_str()));
                                let background_ttl_secs = json_msg
                                    .get("background_ttl_secs")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(300)
                                    .clamp(30, 3600);
                                let office_idle_secs = json_msg
                                    .get("office_idle_secs")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(900)
                                    .max(30);

                                let cfg = TrustConfig {
                                    mode,
                                    background_ttl_secs,
                                    office_idle_secs,
                                };
                                let cfg_path = trust_config_path();
                                match save_trust_config(&cfg_path, &cfg) {
                                    Err(e) => json!({
                                        "type":"trust.config.set",
                                        "corr_id": corr,
                                        "ok": false,
                                        "error": e
                                    }),
                                    Ok(()) => {
                                        let events = {
                                            let mut tstate = trust.lock().await;
                                            tstate.set_config(Instant::now(), mode, background_ttl_secs, office_idle_secs)
                                        };
                                        if !events.is_empty() {
                                            push_trust_events(&sink_registry, events.clone()).await;
                                            if events.iter().any(|e| e.event == "revoked") {
                                                let revoked_trust_id = events
                                                    .iter()
                                                    .find(|e| e.event == "revoked")
                                                    .and_then(|e| e.trust_id.clone());
                                                let mut lm = launcher_manager.lock().await;
                                                lm.cleanup_on_revoke(
                                                    false,
                                                    &audit,
                                                    revoked_trust_id.as_deref(),
                                                    "policy_changed",
                                                )
                                                .await;
                                            }
                                        }
                                        json!({
                                            "type":"trust.config.set",
                                            "corr_id": corr,
                                            "ok": true,
                                            "mode": mode,
                                            "background_ttl_secs": background_ttl_secs,
                                            "office_idle_secs": office_idle_secs
                                        })
                                    }
                                }
                            }
                            "launcher.list" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let mut lm = launcher_manager.lock().await;
                                if let Err(e) = lm.reload_config() {
                                    json!({
                                        "type":"launcher.list",
                                        "corr_id": corr,
                                        "ok": false,
                                        "error": format!("config_reload_failed:{}", e)
                                    })
                                } else {
                                    let launchers = lm.launchers().to_vec();
                                    let mut rows = Vec::with_capacity(launchers.len());
                                    for launcher in launchers {
                                        let running = lm.is_running(&launcher.id);
                                        let last_error = lm.last_errors().get(&launcher.id).cloned();
                                        rows.push(json!({
                                            "id": launcher.id,
                                            "name": launcher.name,
                                            "description": launcher.description,
                                            "exec_path": launcher.exec_path,
                                            "args": launcher.args,
                                            "cwd": launcher.cwd,
                                            "secret_refs": launcher.secret_refs,
                                            "enabled": launcher.enabled,
                                            "running": running,
                                            "trust_policy": launcher.trust_policy,
                                            "single_instance": launcher.single_instance,
                                            "last_error": last_error,
                                        }));
                                    }
                                    json!({
                                        "type":"launcher.list",
                                        "corr_id": corr,
                                        "ok": true,
                                        "launchers": rows
                                    })
                                }
                            }
                            "launcher.run" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let launcher_id = json_msg
                                    .get("launcher_id")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                if launcher_id.is_empty() {
                                    json!({
                                        "type":"launcher.run",
                                        "corr_id": corr,
                                        "ok": false,
                                        "launcher_id": launcher_id,
                                        "error": "launcher_not_found"
                                    })
                                } else {
                                    let trust_id = {
                                        let tstate = trust.lock().await;
                                        tstate.status().trust_id
                                    };
                                    let trusted = {
                                        let tstate = trust.lock().await;
                                        tstate.is_trusted()
                                    };
                                    if let Some(resp) =
                                        launcher_run_trust_gate(&corr, &launcher_id, trusted)
                                    {
                                        if let Some(writer) = &audit {
                                            writer
                                                .log_launcher_event(
                                                    "launcher.run",
                                                    &launcher_id,
                                                    "",
                                                    trust_id.as_deref(),
                                                    0,
                                                    "error:trust_not_active",
                                                    None,
                                                )
                                                .await;
                                        }
                                        resp
                                    } else {
                                        let mut lm = launcher_manager.lock().await;
                                        if let Err(e) = lm.reload_config() {
                                            if let Some(writer) = &audit {
                                                writer
                                                    .log_launcher_event(
                                                        "launcher.run",
                                                        &launcher_id,
                                                        "",
                                                        trust_id.as_deref(),
                                                        0,
                                                        &format!("error:config_reload_failed:{}", e),
                                                        None,
                                                    )
                                                    .await;
                                            }
                                            json!({
                                                "type":"launcher.run",
                                                "corr_id": corr,
                                                "ok": false,
                                                "launcher_id": launcher_id,
                                                "error": format!("config_reload_failed:{}", e)
                                            })
                                        } else {
                                            let resolver = KeychainSecretResolver;
                                            match lm.run_launcher(&launcher_id, &resolver) {
                                                Ok(run) => {
                                                    if let Some(writer) = &audit {
                                                        writer
                                                            .log_launcher_event(
                                                                "launcher.run",
                                                                &launcher_id,
                                                                &run.run_id,
                                                                trust_id.as_deref(),
                                                                run.pid,
                                                                "ok",
                                                                None,
                                                            )
                                                            .await;
                                                    }
                                                    json!({
                                                        "type":"launcher.run",
                                                        "corr_id": corr,
                                                        "ok": true,
                                                        "launcher_id": launcher_id,
                                                        "run_id": run.run_id,
                                                        "pid": run.pid
                                                    })
                                                }
                                                Err(e) => {
                                                    if let Some(writer) = &audit {
                                                        writer
                                                            .log_launcher_event(
                                                                "launcher.run",
                                                                &launcher_id,
                                                                "",
                                                                trust_id.as_deref(),
                                                                0,
                                                                &format!("error:{}", e),
                                                                None,
                                                            )
                                                            .await;
                                                    }
                                                    json!({
                                                        "type":"launcher.run",
                                                        "corr_id": corr,
                                                        "ok": false,
                                                        "launcher_id": launcher_id,
                                                        "error": e
                                                    })
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            "launcher.upsert" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                match serde_json::from_value::<Launcher>(
                                    json_msg.get("launcher").cloned().unwrap_or(json!({})),
                                ) {
                                    Err(_) => json!({
                                        "type":"launcher.upsert",
                                        "corr_id": corr,
                                        "ok": false,
                                        "error": "invalid_launcher"
                                    }),
                                    Ok(launcher) => {
                                    let trust_id = {
                                        let tstate = trust.lock().await;
                                        tstate.status().trust_id
                                    };
                                    let mut lm = launcher_manager.lock().await;
                                    if let Err(e) = lm.reload_config() {
                                        json!({
                                            "type":"launcher.upsert",
                                            "corr_id": corr,
                                            "ok": false,
                                            "error": format!("config_reload_failed:{}", e)
                                        })
                                    } else {
                                        let launcher_id = launcher.id.clone();
                                        match lm.upsert_launcher(launcher) {
                                            Ok(created) => {
                                                if let Some(writer) = &audit {
                                                    writer
                                                        .log_launcher_event(
                                                            "launcher.upsert",
                                                            &launcher_id,
                                                            "",
                                                            trust_id.as_deref(),
                                                            0,
                                                            "ok",
                                                            None,
                                                        )
                                                        .await;
                                                }
                                                json!({
                                                    "type":"launcher.upsert",
                                                    "corr_id": corr,
                                                    "ok": true,
                                                    "id": launcher_id,
                                                    "created": created
                                                })
                                            }
                                            Err(e) => {
                                                let err = if e == "id_duplicate" || e.starts_with("config_write_failed:") {
                                                    e.clone()
                                                } else {
                                                    "invalid_launcher".to_string()
                                                };
                                                if let Some(writer) = &audit {
                                                    writer
                                                        .log_launcher_event(
                                                            "launcher.upsert",
                                                            &launcher_id,
                                                            "",
                                                            trust_id.as_deref(),
                                                            0,
                                                            &format!("error:{}", err),
                                                            None,
                                                        )
                                                        .await;
                                                }
                                                json!({
                                                    "type":"launcher.upsert",
                                                    "corr_id": corr,
                                                    "ok": false,
                                                    "id": launcher_id,
                                                    "error": err
                                                })
                                            }
                                        }
                                    }
                                }
                                }
                            }
                            "launcher.delete" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let launcher_id = json_msg
                                    .get("launcher_id")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .trim()
                                    .to_string();
                                if launcher_id.is_empty() {
                                    json!({
                                        "type":"launcher.delete",
                                        "corr_id": corr,
                                        "ok": false,
                                        "error": "launcher_not_found"
                                    })
                                } else {
                                    let trust_id = {
                                        let tstate = trust.lock().await;
                                        tstate.status().trust_id
                                    };
                                    let mut lm = launcher_manager.lock().await;
                                    if let Err(e) = lm.reload_config() {
                                        json!({
                                            "type":"launcher.delete",
                                            "corr_id": corr,
                                            "ok": false,
                                            "error": format!("config_reload_failed:{}", e)
                                        })
                                    } else {
                                        match lm.delete_launcher(&launcher_id) {
                                            Ok(()) => {
                                                if let Some(writer) = &audit {
                                                    writer
                                                        .log_launcher_event(
                                                            "launcher.delete",
                                                            &launcher_id,
                                                            "",
                                                            trust_id.as_deref(),
                                                            0,
                                                            "ok",
                                                            None,
                                                        )
                                                        .await;
                                                }
                                                json!({
                                                    "type":"launcher.delete",
                                                    "corr_id": corr,
                                                    "ok": true,
                                                    "launcher_id": launcher_id
                                                })
                                            }
                                            Err(e) => {
                                                if let Some(writer) = &audit {
                                                    writer
                                                        .log_launcher_event(
                                                            "launcher.delete",
                                                            &launcher_id,
                                                            "",
                                                            trust_id.as_deref(),
                                                            0,
                                                            &format!("error:{}", e),
                                                            None,
                                                        )
                                                        .await;
                                                }
                                                json!({
                                                    "type":"launcher.delete",
                                                    "corr_id": corr,
                                                    "ok": false,
                                                    "launcher_id": launcher_id,
                                                    "error": e
                                                })
                                            }
                                        }
                                    }
                                }
                            }
                            "launcher.template.list" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let templates = built_in_templates()
                                    .into_iter()
                                    .map(|tpl| {
                                        json!({
                                            "template_id": tpl.template_id,
                                            "name": tpl.name,
                                            "launcher": tpl.launcher
                                        })
                                    })
                                    .collect::<Vec<_>>();
                                json!({
                                    "type":"launcher.template.list",
                                    "corr_id": corr,
                                    "ok": true,
                                    "templates": templates
                                })
                            }
                            "secret.list" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let mut lm = launcher_manager.lock().await;
                                if let Err(e) = lm.reload_config() {
                                    json!({
                                        "type":"secret.list",
                                        "corr_id": corr,
                                        "ok": false,
                                        "error": format!("config_reload_failed:{}", e)
                                    })
                                } else {
                                    let launchers = lm.launchers().to_vec();
                                    drop(lm);

                                    let refs = collect_secret_refs(&launchers);
                                    let registered = list_registered_secret_entries().unwrap_or_default();
                                    let usage = secret_usage_map(&launchers);
                                    let mut names = std::collections::BTreeMap::<String, Option<u64>>::new();
                                    for name in refs {
                                        names.insert(name, None);
                                    }
                                    for entry in registered {
                                        names.insert(entry.name, entry.created_at_ms);
                                    }

                                    let mut rows = Vec::with_capacity(names.len());

                                    for (name, created_at_ms) in names {
                                        let used_by = usage.get(&name).cloned().unwrap_or_default();
                                        match test_secret(&name) {
                                            Ok(available) => rows.push(json!({
                                                "name": name,
                                                "available": available,
                                                "used_by": used_by,
                                                "created_at_ms": created_at_ms
                                            })),
                                            Err(e) if e == "keychain_backend_disabled" => rows.push(json!({
                                                "name": name,
                                                "available": false,
                                                "used_by": used_by,
                                                "status": "backend_disabled",
                                                "created_at_ms": created_at_ms
                                            })),
                                            Err(e) => rows.push(json!({
                                                "name": name,
                                                "available": false,
                                                "used_by": used_by,
                                                "status": e,
                                                "created_at_ms": created_at_ms
                                            })),
                                        }
                                    }

                                    json!({
                                        "type":"secret.list",
                                        "corr_id": corr,
                                        "ok": true,
                                        "secrets": rows
                                    })
                                }
                            }
                            "secret.test" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let name = json_msg
                                    .get("name")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                if name.is_empty() {
                                    json!({
                                        "type":"secret.test",
                                        "corr_id": corr,
                                        "ok": false,
                                        "name": name,
                                        "error": "invalid_secret_name"
                                    })
                                } else {
                                    match test_secret(&name) {
                                        Ok(available) => json!({
                                            "type":"secret.test",
                                            "corr_id": corr,
                                            "ok": true,
                                            "name": name,
                                            "available": available
                                        }),
                                        Err(e) if e == "keychain_backend_disabled" => json!({
                                            "type":"secret.test",
                                            "corr_id": corr,
                                            "ok": true,
                                            "name": name,
                                            "available": false,
                                            "status": "backend_disabled"
                                        }),
                                        Err(e) => json!({
                                            "type":"secret.test",
                                            "corr_id": corr,
                                            "ok": false,
                                            "name": name,
                                            "error": e
                                        }),
                                    }
                                }
                            }
                            "secret.get" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let name = json_msg
                                    .get("name")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .trim()
                                    .to_string();

                                let trusted = {
                                    let tstate = trust.lock().await;
                                    tstate.is_trusted()
                                };

                                if !trusted {
                                    if let Some(writer) = &audit {
                                        writer
                                            .log_secret_event("secret.get", &name, "error:trust_not_active")
                                            .await;
                                    }
                                    json!({
                                        "type":"secret.get",
                                        "corr_id": corr,
                                        "ok": false,
                                        "name": name,
                                        "error": "trust_not_active"
                                    })
                                } else {
                                    match get_secret(&name) {
                                        Ok(value) => {
                                            if let Some(writer) = &audit {
                                                writer.log_secret_event("secret.get", &name, "ok").await;
                                            }
                                            json!({
                                                "type":"secret.get",
                                                "corr_id": corr,
                                                "ok": true,
                                                "name": name,
                                                "value": value
                                            })
                                        }
                                        Err(e) => {
                                            if let Some(writer) = &audit {
                                                writer
                                                    .log_secret_event("secret.get", &name, &format!("error:{}", e))
                                                    .await;
                                            }
                                            json!({
                                                "type":"secret.get",
                                                "corr_id": corr,
                                                "ok": false,
                                                "name": name,
                                                "error": e
                                            })
                                        }
                                    }
                                }
                            }
                            "secret.set" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let name = json_msg
                                    .get("name")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .trim()
                                    .to_string();
                                let value = json_msg
                                    .get("value")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();

                                let trusted = {
                                    let tstate = trust.lock().await;
                                    tstate.is_trusted()
                                };
                                if let Some(resp) = secret_write_trust_gate(&corr, "secret.set", &name, trusted) {
                                    if let Some(writer) = &audit {
                                        writer
                                            .log_secret_event("secret.set", &name, "error:trust_not_active")
                                            .await;
                                    }
                                    resp
                                } else {
                                    match set_secret(&name, &value) {
                                        Ok(created) => {
                                            let _ = register_secret_name(&name);
                                            if let Some(writer) = &audit {
                                                writer.log_secret_event("secret.set", &name, "ok").await;
                                            }
                                            json!({
                                                "type":"secret.set",
                                                "corr_id": corr,
                                                "ok": true,
                                                "name": name,
                                                "created": created
                                            })
                                        }
                                        Err(e) => {
                                            if let Some(writer) = &audit {
                                                writer
                                                    .log_secret_event("secret.set", &name, &format!("error:{}", e))
                                                    .await;
                                            }
                                            json!({
                                                "type":"secret.set",
                                                "corr_id": corr,
                                                "ok": false,
                                                "name": name,
                                                "error": e
                                            })
                                        }
                                    }
                                }
                            }
                            "secret.delete" => {
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let name = json_msg
                                    .get("name")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .trim()
                                    .to_string();

                                let trusted = {
                                    let tstate = trust.lock().await;
                                    tstate.is_trusted()
                                };
                                if let Some(resp) = secret_write_trust_gate(&corr, "secret.delete", &name, trusted) {
                                    if let Some(writer) = &audit {
                                        writer
                                            .log_secret_event("secret.delete", &name, "error:trust_not_active")
                                            .await;
                                    }
                                    resp
                                } else if let Err(e) = validate_secret_name(&name) {
                                    if let Some(writer) = &audit {
                                        writer
                                            .log_secret_event("secret.delete", &name, &format!("error:{}", e))
                                            .await;
                                    }
                                    json!({
                                        "type":"secret.delete",
                                        "corr_id": corr,
                                        "ok": false,
                                        "name": name,
                                        "error": e
                                    })
                                } else {
                                    let mut lm = launcher_manager.lock().await;
                                    let _ = lm.reload_config();
                                    let usage_map = secret_usage_map(lm.launchers());
                                    let affected_launchers = usage_map.get(&name).cloned().unwrap_or_default();
                                    drop(lm);

                                    match delete_secret(&name) {
                                        Ok(()) => {
                                            let _ = unregister_secret_name(&name);
                                            if let Some(writer) = &audit {
                                                writer.log_secret_event("secret.delete", &name, "ok").await;
                                            }
                                            json!({
                                                "type":"secret.delete",
                                                "corr_id": corr,
                                                "ok": true,
                                                "name": name,
                                                "affected_launchers": affected_launchers
                                            })
                                        }
                                        Err(e) => {
                                            if let Some(writer) = &audit {
                                                writer
                                                    .log_secret_event("secret.delete", &name, &format!("error:{}", e))
                                                    .await;
                                            }
                                            json!({
                                                "type":"secret.delete",
                                                "corr_id": corr,
                                                "ok": false,
                                                "name": name,
                                                "error": e
                                            })
                                        }
                                    }
                                }
                            }
                            "trust.server.reset" => {
                                let ok = pairing_manager.delete_all_paired();
                                if let Some(cid) = &corr_id_opt {
                                    serde_json::json!({"type":"trust.ack","op":"server.reset","ok":ok,"corr_id":cid})
                                } else {
                                    serde_json::json!({"type":"trust.ack","op":"server.reset","ok":ok})
                                }
                            }
                            "prox.intent" => {
                                // M1.4b C3: Real implementation
                                {
                                    let mut prox = proximity.lock().await;
                                    prox.intent();
                                }
                                let resp = serde_json::json!({"type":"prox.ack","op":"intent","ok":true});
                                Self::send_message(&w_arc, &resp).await?;
                                continue;
                            }
                            "prox.pause" => {
                                let secs = json_msg.get("seconds").and_then(|v| v.as_u64()).unwrap_or(1800);
                                let now = Instant::now();
                                {
                                    let mut prox = proximity.lock().await;
                                    prox.pause(now, Some(Duration::from_secs(secs)));
                                }
                                let resp = serde_json::json!({
                                    "type":"prox.ack",
                                    "op":"pause",
                                    "ok":true,
                                    "seconds":secs
                                });
                                Self::send_message(&w_arc, &resp).await?;
                                continue;
                            }
                            "prox.resume" => {
                                // M1.4b C3: Real implementation
                                {
                                    let mut prox = proximity.lock().await;
                                    prox.resume();
                                }
                                let resp = serde_json::json!({"type":"prox.ack","op":"resume","ok":true});
                                Self::send_message(&w_arc, &resp).await?;
                                continue;
                            }
                            "prox.status" => {
                                // M1.4b C2: Real implementation
                                let now = Instant::now();
                                let p = proximity.lock().await;
                                
                                let mode = match p.mode() {
                                    ProxMode::AutoUnlock => "auto_unlock",
                                    ProxMode::FirstUse => "first_use",
                                    ProxMode::Intent => "intent",
                                };
                                let mut state = match p.state() {
                                    ProxState::Far => "far",
                                    ProxState::NearLocked => "near_locked",
                                    ProxState::NearUnlocked => "near_unlocked",
                                    ProxState::Paused => "paused",
                                };
                                
                                let mut is_near = !matches!(p.state(), ProxState::Far);
                                let mut is_unlocked = p.is_unlocked();
                                let grace_ms = p.grace_remaining_ms(now);
                                let pause_s = p.pause_remaining_s(now);
                                let grace_budget_ms = p.grace().as_millis() as u64;
                                let hb_age_ms = p.status(now).last_heartbeat_age_ms;

                                // If we have no heartbeat age, or it exceeded grace, present as FAR/offline
                                let mut force_lock = false;
                                if let Some(age) = hb_age_ms {
                                    if age >= grace_budget_ms {
                                        state = "far";
                                        is_near = false;
                                        is_unlocked = false;
                                        force_lock = true;
                                    }
                                } else {
                                    state = "far";
                                    is_near = false;
                                    is_unlocked = false;
                                    force_lock = true;
                                }
                                
                                drop(p); // Release lock before send
                                if force_lock {
                                    let mut v = vault.lock().await;
                                    let _ = v.lock();
                                }
                                
                                let resp = serde_json::json!({
                                    "type": "prox.status",
                                    "mode": mode,
                                    "state": state,
                                    "near": is_near,
                                    "unlocked": is_unlocked,
                                    "grace_remaining_ms": grace_ms,
                                    "pause_remaining_s": pause_s,
                                    "last_heartbeat_age_ms": hb_age_ms,
                                });
                                Self::send_message(&w_arc, &resp).await?;
                                continue;
                            }
                            "cred.list" => {
                                // If proximity is FAR, hard-fail and lock vault defensively
                                {
                                    let p = proximity.lock().await;
                                    let state = p.state();
                                    let grace_budget_ms = p.grace().as_millis() as u64;
                                    let now = Instant::now();
                                    let hb_age = p.status(now).last_heartbeat_age_ms;
                                    let far = matches!(state, ProxState::Far)
                                        || hb_age.map(|age| age >= grace_budget_ms).unwrap_or(true)
                                        || p.is_offline(now);
                                    if far {
                                        let mut v = vault.lock().await;
                                        let _ = v.lock();
                                        let err = serde_json::json!({
                                            "type": "error",
                                            "err_code": 401,
                                            "err_reason": "proximity_far",
                                            "corr_id": corr_id_opt.as_deref().unwrap_or("")
                                        });
                                        Self::send_message(&w_arc, &err).await?;
                                        continue;
                                    }
                                }
                                let origin_raw = json_msg.get("origin").and_then(|v| v.as_str());
                                if let Some(origin_raw) = origin_raw {
                                    if let Some(origin) = sanitize_origin(origin_raw) {
                                        let scope = format!("cred.list:{}", origin);
                                        let mctx = MatchCtx {
                                            origin: Some(origin.clone()),
                                            app: None,
                                            action: Some("cred.list".into()),
                                            cmd: None,
                                            scope: scope.clone(),
                                        };
                                        // Check vault status FIRST
                                        let mut v = vault.lock().await;
                                        if v.is_locked() {
                                            // Vault locked - need auth
                                            drop(v);
                                            if let Some(err) =
                                                require_auth_if_needed(
                                                    &auth_policy,
                                                    &auth_state,
                                                    &policy,
                                                    &scope,
                                                    &mctx,
                                                    corr_id_opt.as_ref(),
                                                    sid_opt.as_ref(),
                                                    &proximity,
                                                    SystemTime::now(),
                                                )
                                                .await
                                            {
                                                push_auth_request(
                                                    &sink_registry,
                                                    corr_id_opt.as_deref(),
                                                )
                                                .await;
                                                err
                                            } else {
                                                // Locked and no pending auth state recorded yet: nudge iOS for Face ID
                                                push_auth_request(
                                                    &sink_registry,
                                                    corr_id_opt.as_deref(),
                                                )
                                                .await;
                                                unlock_required_error(
                                                    &auth_state,
                                                    corr_id_opt.as_ref(),
                                                )
                                                .await
                                            }
                                        } else {
                                            // Vault already unlocked - return credentials immediately
                                            match v.list_credentials(&origin) {
                                                Ok(accounts) => {
                                                    info!(role = "agent", cat = "cred", event = "cred.listed", origin = %origin, count = accounts.len());
                                                    let list: Vec<Value> = accounts
                                                        .iter()
                                                        .map(
                                                            |u| json!({"username":u,"label":u}),
                                                        )
                                                        .collect();
                                                    if let Some(cid) = &corr_id_opt {
                                                        json!({"type":"cred.accounts","origin":origin,"accounts":list,"corr_id":cid})
                                                    } else {
                                                        json!({"type":"cred.accounts","origin":origin,"accounts":list})
                                                    }
                                                }
                                                Err(VaultError::NotFound) => {
                                                        if let Some(cid) = &corr_id_opt {
                                                            json!({"type":"cred.accounts","origin":origin,"accounts":[],"corr_id":cid})
                                                        } else {
                                                            json!({"type":"cred.accounts","origin":origin,"accounts":[]})
                                                        }
                                                    }
                                                Err(e) => error_with_corr(
                                                    "VAULT_ERROR",
                                                    &format!("{:?}", e),
                                                    corr_id_opt.as_ref(),
                                                ),
                                            }
                                        }
                                    } else {
                                        error_with_corr(
                                            "INVALID_ORIGIN",
                                            "origin malformed",
                                            corr_id_opt.as_ref(),
                                        )
                                    }
                                } else {
                                    error_with_corr(
                                        "MISSING_FIELD",
                                        "origin missing",
                                        corr_id_opt.as_ref(),
                                    )
                                }
                            }
                            "cred.write" => {
                                let origin_raw = json_msg.get("origin").and_then(|v| v.as_str());
                                let username = json_msg.get("user").and_then(|v| v.as_str());
                                let secret = json_msg.get("secret").and_then(|v| v.as_str());
                                if let (Some(origin_raw), Some(username), Some(secret)) =
                                    (origin_raw, username, secret)
                                {
                                    if let Some(origin) = sanitize_origin(origin_raw) {
                                        // dev helper: write a plain secret (no auth gate for now)
                                        let mut v = vault.lock().await;
                                        let ok = v.write_credential(&origin, username, secret, None).is_ok();
                                        if let Some(cid) = &corr_id_opt {
                                            json!({"type":"cred.ack","op":"write","origin":origin,"username":username,"ok":ok,"corr_id":cid})
                                        } else {
                                            json!({"type":"cred.ack","op":"write","origin":origin,"username":username,"ok":ok})
                                        }
                                    } else {
                                        error_with_corr(
                                            "INVALID_ORIGIN",
                                            "origin malformed",
                                            corr_id_opt.as_ref(),
                                        )
                                    }
                                } else {
                                    error_with_corr(
                                        "MISSING_FIELD",
                                        "origin/user/secret required",
                                        corr_id_opt.as_ref(),
                                    )
                                }
                            }
                            "cred.get" => {
                                // If proximity is FAR, hard-fail and lock vault defensively
                                {
                                    let p = proximity.lock().await;
                                    let state = p.state();
                                    let grace_budget_ms = p.grace().as_millis() as u64;
                                    let now = Instant::now();
                                    let hb_age = p.status(now).last_heartbeat_age_ms;
                                    let far = matches!(state, ProxState::Far)
                                        || hb_age.map(|age| age >= grace_budget_ms).unwrap_or(true)
                                        || p.is_offline(now);
                                    if far {
                                        let mut v = vault.lock().await;
                                        let _ = v.lock();
                                        let err = serde_json::json!({
                                            "type": "error",
                                            "err_code": 401,
                                            "err_reason": "proximity_far",
                                            "corr_id": corr_id_opt.as_deref().unwrap_or("")
                                        });
                                        Self::send_message(&w_arc, &err).await?;
                                        continue;
                                    }
                                }
                                let origin_raw = json_msg.get("origin").and_then(|v| v.as_str());
                                let username = json_msg.get("username").and_then(|v| v.as_str());
                                if let (Some(origin_raw), Some(username)) = (origin_raw, username) {
                                    let origin = match origin::canonicalize_origin(origin_raw) {
                                        Ok(o) => o.0,
                                        Err(_) => {
                                            let err = serde_json::json!({
                                                "type": "error",
                                                "err_code": 400,
                                                "err_reason": "INVALID_ORIGIN",
                                                "message": "origin malformed",
                                                "corr_id": corr_id_opt.clone().unwrap_or_default()
                                            });
                                            Self::send_message(&w_arc, &err).await?;
                                            continue;
                                        }
                                    };

                                    let step = policy.requires_step_up(&origin, "cred.get");
                                    match remote_or_proximity_gate(&proximity, &trust, &auth_state, step).await
                                    {
                                        Ok(()) => {}
                                        Err((reason, code)) => {
                                            // Push auth.request to iOS on gate failures to trigger Face ID
                                            if matches!(reason, "session_unlock_required" | "prox_intent_required" | "proximity_far" | "trust_locked") {
                                                push_auth_request(&sink_registry, corr_id_opt.as_deref()).await;
                                            }
                                            let err = serde_json::json!({
                                                "type": "error",
                                                "err_code": code,
                                                "err_reason": reason,
                                                "corr_id": corr_id_opt.clone().unwrap_or_default()
                                            });
                                            Self::send_message(&w_arc, &err).await?;
                                            continue;
                                        }
                                    }

                                    // M1.5: Enforce session TTL
                                    let session_valid = {
                                        let auth = auth_state.lock().await;
                                        auth.check_session().is_ok()
                                    };
                                    if !session_valid {
                                        let err = serde_json::json!({
                                            "type": "error",
                                            "err_code": 401,
                                            "err_reason": "token_expired",
                                            "message": "Session expired, step-up required",
                                            "corr_id": corr_id_opt.as_deref().unwrap_or(""),
                                        });
                                        Self::send_message(&w_arc, &err).await?;
                                        continue;
                                    }

                                    let scope =
                                        format!("cred.get:{}:{}", origin, username);
                                    let mctx = MatchCtx {
                                        origin: Some(origin.clone()),
                                        app: None,
                                        action: Some("cred.get".into()),
                                        cmd: None,
                                        scope: scope.clone(),
                                    };
                                    if let Some(err) =
                                        require_auth_if_needed(
                                            &auth_policy,
                                            &auth_state,
                                            &policy,
                                            &scope,
                                            &mctx,
                                            corr_id_opt.as_ref(),
                                            sid_opt.as_ref(),
                                            &proximity,
                                            SystemTime::now(),
                                        )
                                        .await
                                    {
                                        push_auth_request(
                                            &sink_registry,
                                            corr_id_opt.as_deref(),
                                        )
                                        .await;
                                        err
                                    } else {
                                        let mut v = vault.lock().await;
                                        if v.is_locked() {
                                            drop(v);
                                            // If still locked, nudge iOS then return unlock error
                                            push_auth_request(
                                                &sink_registry,
                                                corr_id_opt.as_deref(),
                                            )
                                            .await;
                                            unlock_required_error(
                                                &auth_state,
                                                corr_id_opt.as_ref(),
                                            )
                                            .await
                                        } else {
                                            match v.read_credential(&origin, username) {
                                                Ok(rec) => {
                                                    info!(role = "agent", cat = "cred", event = "cred.retrieved", origin = %origin, username = %username);
                                                    let pw_b64 = base64::engine::general_purpose::STANDARD
                                                        .encode(rec.secret.as_bytes());
                                                    if let Some(cid) = &corr_id_opt {
                                                        json!({"type":"cred.secret","origin":origin,"username":username,"status":"ok","password_b64":pw_b64,"corr_id":cid})
                                                    } else {
                                                        json!({"type":"cred.secret","origin":origin,"username":username,"status":"ok","password_b64":pw_b64})
                                                    }
                                                }
                                                Err(VaultError::NotFound) => {
                                                    // return a quiet miss instead of error for dev ergonomics
                                                    if let Some(cid) = &corr_id_opt {
                                                        json!({"type":"cred.secret","origin":origin,"username":username,"status":"miss","corr_id":cid})
                                                    } else {
                                                        json!({"type":"cred.secret","origin":origin,"username":username,"status":"miss"})
                                                    }
                                                }
                                                Err(e) => error_with_corr(
                                                    "VAULT_ERROR",
                                                    &format!("{:?}", e),
                                                    corr_id_opt.as_ref(),
                                                ),
                                            }
                                        }
                                    }
                                } else {
                                    error_with_corr(
                                        "MISSING_FIELD",
                                        "origin or username missing",
                                        corr_id_opt.as_ref(),
                                    )
                                }
                            }
                            "auth.totp" => {
                                let start = Instant::now();
                                let corr = corr_id_opt.clone().unwrap_or_default();
                                let origin_raw = json_msg.get("origin").and_then(|v| v.as_str());
                                let action = json_msg
                                    .get("action")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("cred.get");
                                let code_str = json_msg.get("code").and_then(|v| v.as_str());

                                let (origin_raw, code_str) = match (origin_raw, code_str) {
                                    (Some(o), Some(c)) => (o, c),
                                    _ => {
                                        let err = json!({
                                            "type":"error","err_code":400,"err_reason":"bad_request",
                                            "message":"missing origin or code","corr_id":corr,
                                            "latency_ms":start.elapsed().as_millis()
                                        });
                                        Self::send_message(&w_arc, &err).await?;
                                        continue;
                                    }
                                };

                                let origin = match origin::canonicalize_origin(origin_raw) {
                                    Ok(o) => o,
                                    Err(_) => {
                                        let err = json!({
                                            "type":"error","err_code":400,"err_reason":"bad_origin",
                                            "message":"invalid origin","corr_id":corr,
                                            "latency_ms":start.elapsed().as_millis()
                                        });
                                        Self::send_message(&w_arc, &err).await?;
                                        continue;
                                    }
                                };

                                let step = policy.requires_step_up(origin.as_ref(), action);
                                let step = match step {
                                    Some(s) if s.allow_remote && matches!(s.mode, StepUpMode::Totp) => s,
                                    _ => {
                                        let err = json!({
                                            "type":"error","err_code":403,"err_reason":"denied",
                                            "message":"remote TOTP not allowed by policy","corr_id":corr,
                                            "latency_ms":start.elapsed().as_millis()
                                        });
                                        Self::send_message(&w_arc, &err).await?;
                                        continue;
                                    }
                                };

                                let code: u32 = match code_str.parse() {
                                    Ok(c) => c,
                                    Err(_) => {
                                        let err = json!({
                                            "type":"error","err_code":400,"err_reason":"bad_request",
                                            "message":"code must be 6-digit number","corr_id":corr,
                                            "latency_ms":start.elapsed().as_millis()
                                        });
                                        Self::send_message(&w_arc, &err).await?;
                                        continue;
                                    }
                                };

                                let secret = match totp::load_totp_secret() {
                                    Ok(s) => s,
                                    Err(_) => {
                                        let err = json!({
                                            "type":"error","err_code":400,"err_reason":"totp_not_enrolled",
                                            "message":"enroll TOTP first: agent-cli totp enroll","corr_id":corr,
                                            "latency_ms":start.elapsed().as_millis()
                                        });
                                        Self::send_message(&w_arc, &err).await?;
                                        continue;
                                    }
                                };

                                let now = totp::unix_now();
                                if !totp::verify_code(&secret, code, now) {
                                    let err = json!({
                                        "type":"error","err_code":401,"err_reason":"invalid_totp",
                                        "message":"code incorrect or expired","corr_id":corr,
                                        "latency_ms":start.elapsed().as_millis()
                                    });
                                    Self::send_message(&w_arc, &err).await?;
                                    continue;
                                }

                                {
                                    let mut auth = auth_state.lock().await;
                                    let ttl = Duration::from_secs(step.ttl_s.max(30).min(3600));
                                    auth.issue_session_unlock_with_ttl(ttl);
                                    auth.mark_remote_session();
                                }

                                let ok = json!({
                                    "type":"ok","reason":"totp_verified","ttl_s":step.ttl_s,
                                    "corr_id":corr,"latency_ms":start.elapsed().as_millis()
                                });
                                Self::send_message(&w_arc, &ok).await?;
                                continue;
                            }
                            "auth.begin" => {
                                // Check if already authorized
                                let is_authorized = {
                                    let guard = auth_state.lock().await;
                                    guard.status().authorized
                                };
                                
                                if is_authorized {
                                    info!(role = "agent", cat = "auth", event = "auth.begin", status = "already_authorized");
                                    json!({"type":"auth.already_ok","corr_id":corr_id_opt})
                                } else {
                                    info!(role = "agent", cat = "auth", event = "auth.begin", status = "pushing_auth_request");
                                    push_auth_request(&sink_registry, corr_id_opt.as_deref()).await;
                                    json!({"type":"auth.ack","corr_id":corr_id_opt})
                                }
                            }
                            "intent.ok" => {
                                // iOS widget: user did FaceID, latch intent to allow next BLE unlock
                                let now = Instant::now();
                                let mut p = proximity.lock().await;
                                p.set_intent(now, 90); // 90-second unlock window
                                tracing::info!(event = "intent.ok.received");
                                if let Some(cid) = &corr_id_opt {
                                    json!({"type": "intent.ack", "ok": true, "corr_id": cid})
                                } else {
                                    json!({"type": "intent.ack", "ok": true})
                                }
                            }
                            "auth.proof" => {
                                handle_auth_proof(
                                    &json_msg,
                                    &auth_state,
                                    corr_id_opt.as_ref(),
                                    sid_opt.as_ref(),
                                    &sink_registry,
                                    Some(&proximity),
                                )
                                .await
                            }
                            "auth.request" => {
                                info!(role = "agent", cat = "auth", "auth.request received");
                                if let Some(cid) = &corr_id_opt {
                                    json!({"type":"auth.pending","corr_id":cid})
                                } else {
                                    json!({"type":"auth.pending"})
                                }
                            }
                            _ => {
                                let mut resp = pairing_manager.handle_message(json_msg).await;
                                if let Some(cid) = &corr_id_opt {
                                    if let Some(obj) = resp.as_object_mut() {
                                        if !obj.contains_key("corr_id") {
                                            obj.insert("corr_id".to_string(), serde_json::json!(cid));
                                        }
                                    }
                                }
                                resp
                            }
                        }
                    } else {
                        pairing_manager.handle_message(json_msg).await
                    }
                }
                Err(e) => {
                    error!("Failed to parse JSON message: {}", e);
                    serde_json::json!({
                        "type": "error",
                        "code": "INVALID_JSON",
                        "message": format!("Failed to parse message: {}", e)
                    })
                }
            };

            // ✅ LOG EVERY OUTBOUND MESSAGE
            let resp_type = response.get("type").and_then(|v| v.as_str()).unwrap_or("<no_type>");
            let resp_corr = response.get("corr_id").and_then(|v| v.as_str()).unwrap_or("");
            if resp_type == "error" {
                let code = response.get("code").and_then(|v| v.as_str()).unwrap_or("<no_code>");
                let msg = response.get("message").and_then(|v| v.as_str()).unwrap_or("");
                info!(role = "agent", cat = "uds", event = "msg.send", msg_type = %resp_type, corr_id = %resp_corr, code = %code, message = %msg);
            } else {
                info!(role = "agent", cat = "uds", event = "msg.send", msg_type = %resp_type, corr_id = %resp_corr);
            }

            // Send response
            Self::send_message(&w_arc, &response).await?;
        }

        Ok(())
    }
    .await;

        // Stop TLS heartbeat watchdog if running.
        if let Some(stop) = tls_hb_stop.take() {
            let _ = stop.send(());
        }

        if push_enabled() {
            if let Some(role) = conn_role {
                let mut guard = sink_registry.lock().await;
                guard.clear_role(role);
                let role_str = match role {
                    SinkRole::Tls => "tls",
                    SinkRole::Nm => "nm",
                };
                info!(event = "sink.drop", role = %role_str);
            }
        }
        // M1.4b C1: Old proximity.handle(TlsDown) removed - will add TlsUpGuard in C2
        result
    }

    async fn send_message(
        writer: &Arc<Mutex<OwnedWriteHalf>>,
        message: &Value,
    ) -> Result<(), BridgeError> {
        let message_bytes = serde_json::to_vec(message)?;
        debug!(role = "agent", cat = "uds", "sending message");

        // Send frame length (u32 big-endian)
        let length_bytes = (message_bytes.len() as u32).to_be_bytes();
        debug!(
            role = "agent",
            cat = "uds",
            bytes = 4,
            "UDS→LEN {:02x}{:02x}{:02x}{:02x}",
            length_bytes[0],
            length_bytes[1],
            length_bytes[2],
            length_bytes[3]
        );

        // Send frame data
        let dump_out = {
            let hex = hex::encode(&message_bytes);
            if hex.len() > 128 {
                format!("{}… [redacted]", &hex[..128])
            } else {
                hex
            }
        };
        debug!(role = "agent", cat = "uds", bytes = message_bytes.len(), dump = %dump_out, "UDS→BODY");

        let mut guard = writer.lock().await;
        guard.write_all(&length_bytes).await?;
        guard.write_all(&message_bytes).await?;
        guard.flush().await?;

        Ok(())
    }
}

async fn handle_auth_proof(
    json_msg: &Value,
    auth_state: &Arc<Mutex<AuthState>>,
    corr: Option<&String>,
    sid: Option<&String>,
    sinks: &Arc<Mutex<SinkRegistry>>,
    proximity: Option<&Arc<Mutex<crate::proximity::Proximity>>>,
) -> Value {
    let ts_val = match json_msg.get("ts").and_then(|v| v.as_i64()) {
        Some(v) if v >= 0 => v as u64,
        _ => {
            return error_with_corr("MISSING_FIELD", "ts missing", corr);
        }
    };
    let ts = UNIX_EPOCH + Duration::from_secs(ts_val);
    let nonce_b64 = match json_msg.get("nonce_b64").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s,
        _ => {
            return error_with_corr("MISSING_FIELD", "nonce_b64 missing", corr);
        }
    };
    let sig_b64 = match json_msg.get("sig_b64").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s,
        _ => {
            warn!(role = "agent", cat = "auth", "auth.proof missing sig_b64");
            ""
        }
    };
    if let Err(e) = base64::engine::general_purpose::STANDARD.decode(nonce_b64) {
        warn!(role = "agent", cat = "auth", err = ?e, "auth.proof nonce decode failed");
        return error_with_corr("INVALID_FIELD", "nonce_b64 invalid", corr);
    }
    if sig_b64.is_empty() {
        warn!(role = "agent", cat = "auth", "auth.proof signature missing");
    }
    let (status, until_unix) = {
        let mut guard = auth_state.lock().await;
        match guard.apply_proof(ts, nonce_b64, sid.map(|s| s.as_str())) {
            Ok(status) => {
                let until = guard.expires_at_unix();
                (status, until)
            }
            Err(ProofError::MissingField(field)) => {
                return error_with_corr("MISSING_FIELD", field, corr);
            }
            Err(ProofError::ClockSkew) => {
                return error_with_corr(
                    "AUTH_CLOCK_SKEW",
                    "timestamp outside allowed window",
                    corr,
                );
            }
            Err(ProofError::NonceReplay) => {
                return error_with_corr("AUTH_REPLAY", "nonce replayed", corr);
            }
        }
    };
    // M1.4b/M1.5: Mark proximity session unlock and start monotonic session TTL
    if let Some(prox) = proximity {
        let mut prox = prox.lock().await;
        prox.mark_session_unlocked();
    }
    {
        let mut auth = auth_state.lock().await;
        auth.issue_session_unlock();
    }
    info!(
        role = "agent",
        cat = "auth",
        event = "auth.proof.accepted",
        until = until_unix
    );
    let until_secs = until_unix.unwrap_or_else(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_else(|_| Duration::from_secs(0))
            .as_secs()
    });
    push_auth_ok(sinks, corr.map(|s| s.as_str()), until_secs).await;

    // Return auth.ack (not auth.ok) since push_auth_ok already sent auth.ok to sinks
    let mut body = json!({
        "type":"auth.ack",
        "auth_authorized": status.authorized,
        "auth_age_ms": status.auth_age_ms,
    });
    if let Some(until) = until_unix {
        body["until"] = json!(until);
    }
    if let Some(exp) = status.expires_in_ms {
        body["auth_expires_in_ms"] = json!(exp);
    }
    if let Some(cid) = corr {
        body["corr_id"] = json!(cid);
    }
    body
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_run_requires_trust() {
        let denied = launcher_run_trust_gate("c123", "demo-launcher", false).expect("must deny");
        assert_eq!(denied["type"], "launcher.run");
        assert_eq!(denied["corr_id"], "c123");
        assert_eq!(denied["launcher_id"], "demo-launcher");
        assert_eq!(denied["error"], "trust_not_active");

        let allowed = launcher_run_trust_gate("c123", "demo-launcher", true);
        assert!(allowed.is_none());
    }
}

impl Drop for UnixBridge {
    fn drop(&mut self) {
        // Clean up socket file
        if Path::new(&self.socket_path).exists() {
            if let Err(e) = std::fs::remove_file(&self.socket_path) {
                error!("Failed to remove socket file {}: {}", self.socket_path, e);
            }
        }
    }
}
