// STATUS: ACTIVE
// PURPOSE: agent entrypoint — wires BLE scanner, proximity watchdog, TLS bridge, vault
use std::env;
use std::error::Error;
use std::time::{Duration, Instant};
use tracing::{info, warn};
use tracing_subscriber::{self, fmt::format::FmtSpan, EnvFilter};

mod audit; // PR4a: Audit module
mod auth;
mod ble_global; // Global BLE scanner reference
mod ble_scanner;
mod bridge;
mod config;
#[allow(dead_code)] // Deferred subsystem (not in active runtime path).
mod credentials;
mod error;
mod idempotency;
mod launcher;
mod mac_idle; // Mac idle time detection for GRACE vs immediate lock
mod origin;
mod pairing;
#[allow(dead_code)] // Deferred subsystem (not in active runtime path).
mod policy;
mod proximity;
mod ratelimit;
#[allow(dead_code)] // Deferred subsystem (not in active runtime path).
mod recovery;
mod secrets;
#[allow(dead_code)] // Deferred subsystem (not in active runtime path).
mod session;
mod sinks;
mod startup; // Added startup module
mod time; // M1.5: Clock abstraction
#[allow(dead_code, unused_imports)] // Deferred subsystem (not in active runtime path).
mod totp;
mod trust;
#[allow(dead_code, deprecated)] // Deferred subsystem; generic-array migration pending.
mod vault;
#[allow(dead_code)] // Deferred subsystem (not in active runtime path).
mod webext_host;
mod wrap;

use auth::{AuthPolicy, AuthState};
use bridge::UnixBridge;
use launcher::LauncherManager;
use pairing::PairingManager;
use policy::Policy;
use proximity::{ProxMode, Proximity};
use sinks::SinkRegistry;
use std::path::PathBuf;
use std::sync::Arc;
use time::SystemClock; // M1.5
use tokio::sync::Mutex;
use trust::{load_trust_config, TrustController, TrustMode};
use vault::Vault;

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    // Initialize logging with env control
    // ARMADILLO_LOG controls level (e.g., "info", "agent=info,agent::bridge=debug")
    // ARMADILLO_LOG_FORMAT=json enables JSON logs
    let filter = EnvFilter::try_from_env("ARMADILLO_LOG")
        .or_else(|_| EnvFilter::try_new("info"))
        .unwrap();

    let fmt_layer = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_span_events(FmtSpan::NEW | FmtSpan::CLOSE)
        .with_target(true);

    if std::env::var("ARMADILLO_LOG_FORMAT")
        .map(|v| v == "json")
        .unwrap_or(false)
    {
        fmt_layer.json().flatten_event(true).init();
    } else {
        fmt_layer.compact().init();
    }

    info!(
        "Starting Armadillo macOS Agent v{}",
        env!("CARGO_PKG_VERSION")
    );

    // Get socket path from environment variable, command line args, or use default ~/.armadillo/a.sock
    let socket_path = env::var("ARMADILLO_SOCKET_PATH").unwrap_or_else(|_| {
        let args: Vec<String> = env::args().collect();
        if args.len() > 1 {
            args[1].clone()
        } else {
            let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
            format!("{}/.armadillo/a.sock", home)
        }
    });

    info!(role = "agent", cat = "uds", socket = %socket_path, "using socket path");

    // Initialize core components
    let mut pairing_manager = PairingManager::new();
    pairing_manager.load_persisted();

    // M1.1: Enforce security permissions before binding socket
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let arm_dir = std::path::PathBuf::from(&home).join(".armadillo");

    // Create directory if needed
    if !arm_dir.exists() {
        std::fs::create_dir_all(&arm_dir).expect("Failed to create ~/.armadillo directory");
        // Set secure permissions immediately
        let _ = startup::fix_perms(&arm_dir, 0o700);
    }

    // Check directory permissions
    if let Err(e) = startup::ensure_secure(&arm_dir, 0o700) {
        eprintln!(
            "\n⚠️  SECURITY ERROR: Insecure permissions on {:?}",
            arm_dir
        );
        eprintln!("{}", e);
        eprintln!("\nRefusing to start. Please fix permissions and restart.");
        std::process::exit(1);
    }

    info!(
        "Security check passed: {:?} has secure permissions (0700)",
        arm_dir
    );

    // Check database file permissions if they exist
    for db_name in ["vault.db", "idempotency.db"] {
        let db_path = arm_dir.join(db_name);
        if db_path.exists() {
            if let Err(e) = startup::ensure_secure(&db_path, 0o600) {
                eprintln!(
                    "\n⚠️  SECURITY ERROR: Insecure permissions on {:?}",
                    db_path
                );
                eprintln!("{}", e);
                eprintln!("\nRefusing to start. Please fix permissions and restart.");
                std::process::exit(1);
            }
        }
    }
    // PR1: Load agent config from env
    let cfg = config::AgentConfig::from_env();
    info!(
        role = "agent",
        cat = "gating",
        rate_per_min = cfg.rate_per_origin_per_min,
        auth_max_global = cfg.auth_max_global,
        auth_max_per_origin = cfg.auth_max_per_origin,
        idem_ttl_s = cfg.idempotency_ttl_s,
        "PR1 gating config loaded"
    );

    // Initialize rate limiter
    let rate_limiter = Arc::new(tokio::sync::Mutex::new(ratelimit::RateLimiter::new(
        cfg.rate_per_origin_per_min,
        cfg.rate_per_origin_per_min, // capacity = per_min for burst allowance
        cfg.auth_max_global,
        cfg.auth_max_per_origin,
    )));

    // Initialize idempotency store
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let arm_dir = PathBuf::from(format!("{}/.armadillo", home));
    std::fs::create_dir_all(&arm_dir)?;
    let idem_path = arm_dir.join("idempotency.db");
    let idem_conn = rusqlite::Connection::open(&idem_path)?;
    let idempotency = Arc::new(idempotency::Idempotency::new(idem_conn)?);

    // Spawn idempotency GC loop
    let idem_clone = idempotency.clone();
    let ttl = cfg.idempotency_ttl_s;
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(300)).await; // GC every 5 min
            if let Err(e) = idem_clone.gc(ttl) {
                tracing::warn!(role = "agent", cat = "idem", error = %e, "idempotency GC failed");
            }
        }
    });

    // PR4a: Initialize audit writer (optional, won't fail startup)
    let audit_dir = arm_dir.join("audit");
    let audit_writer = match audit::AuditWriter::new(&audit_dir) {
        Ok(writer) => {
            info!("Audit writer initialized: {}", audit_dir.display());
            Some(Arc::new(writer))
        }
        Err(e) => {
            warn!("Failed to initialize audit writer: {}", e);
            None
        }
    };

    // Emit startup event if audit available
    if let Some(ref audit) = audit_writer {
        audit.emit(audit::AuditEvent::Startup).await;
    }

    // M1.4: Initialize proximity actor
    let prox = proximity::Proximity::new(
        cfg.prox_mode,
        Duration::from_millis(cfg.prox_grace_ms),
        Duration::from_secs(cfg.prox_pause_default_s),
        None, // event callback - audit emits done explicitly in bridge
    );
    let proximity = Arc::new(Mutex::new(prox));

    // Create channel for proximity inputs (BLE events, etc.)
    let (prox_tx, mut prox_rx) = tokio::sync::mpsc::channel::<proximity::ProxInput>(256);

    // Proximity watchdog: finalize grace/pause timeouts even if no ops are flowing.
    {
        let prox_clone = proximity.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_millis(500));
            loop {
                tokio::select! {
                    _ = interval.tick() => {
                        let now = Instant::now();
                        let idle = mac_idle::idle_secs();
                        let mut p = prox_clone.lock().await;
                        p.tick_with_idle(now, idle);
                    }
                    Some(msg) = prox_rx.recv() => {
                        match msg {
                            proximity::ProxInput::BleSeen { fp:_, rssi, now } => {
                                let mut p = prox_clone.lock().await;
                                p.note_ble_seen(now, rssi);
                                tracing::info!(event = "prox.ble_seen", rssi = ?rssi);
                            }
                        }
                    }
                }
            }
        });
    }

    // ✅ Start BLE scanner for proximity detection
    {
        let pairing_clone = Arc::new(Mutex::new(pairing_manager.clone()));

        info!("Starting BLE scanner for proximity detection");

        tokio::spawn(async move {
            // Create scanner (use anyhow to make it Send-safe)
            let scanner_result: Result<_, String> =
                match ble_scanner::BleScanner::new(prox_tx.clone()).await {
                    Ok(s) => Ok(s),
                    Err(e) => Err(format!("Failed to initialize BLE scanner: {}", e)),
                };

            match scanner_result {
                Ok(scanner) => {
                    let scanner = Arc::new(scanner);
                    info!("BLE scanner initialized successfully");

                    // Store in global for hot-reload after pairing
                    ble_global::set_ble_scanner(scanner.clone());

                    // Load paired devices and derive k_ble keys
                    {
                        let pm = pairing_clone.lock().await;
                        let paired = pm.get_all_paired();

                        if paired.is_empty() {
                            info!(
                                "No paired devices found yet, scanner will run with empty key set"
                            );
                        } else {
                            let mut ble_keys = std::collections::HashMap::new();

                            // Get agent's wrap secret key
                            if let Ok(sk) = wrap::ensure_agent_wrap_secret() {
                                for (fp_suffix, device) in paired.iter() {
                                    if let Some(ios_pub) = &device.ios_wrap_pub_sec1 {
                                        // Derive 32-byte salt: SHA256("arm-ble-salt-v1" || fp_bytes)
                                        use sha2::{Digest, Sha256};
                                        let fp_clean =
                                            fp_suffix.strip_prefix("sha256:").unwrap_or(fp_suffix);
                                        let salt = if let Ok(fp_bytes) = hex::decode(fp_clean) {
                                            if fp_bytes.len() == 32 {
                                                let mut h = Sha256::new();
                                                h.update(b"arm-ble-salt-v1");
                                                h.update(&fp_bytes);
                                                let hash = h.finalize();
                                                let arr: [u8; 32] = hash.into();
                                                arr
                                            } else {
                                                warn!(
                                                    "BLE salt: fp not 32 bytes for {}",
                                                    fp_suffix
                                                );
                                                [0u8; 32]
                                            }
                                        } else {
                                            warn!("BLE salt: hex decode failed for {}", fp_suffix);
                                            [0u8; 32]
                                        };

                                        match wrap::derive_ble_key(&sk, ios_pub, &salt) {
                                            Ok(k_ble) => {
                                                ble_keys.insert(fp_suffix.clone(), k_ble.to_vec());
                                                info!(
                                                    "Derived k_ble for device fp_suffix={}",
                                                    fp_suffix.chars().take(8).collect::<String>()
                                                );
                                            }
                                            Err(e) => {
                                                warn!(
                                                    "Failed to derive k_ble for {}: {:?}",
                                                    fp_suffix, e
                                                );
                                            }
                                        }
                                    }
                                }

                                scanner.update_paired_devices(ble_keys).await;
                                info!("BLE scanner loaded {} device keys", paired.len());
                            } else {
                                warn!("Failed to load agent wrap secret, BLE scanner will have no keys");
                            }
                        }
                    }

                    // Start scanning loop
                    if let Err(e) = scanner.start_scan().await {
                        warn!("BLE scanner exited: {}", e);
                    }
                }
                Err(e) => {
                    warn!("{}", e);
                }
            }
        });
    }

    info!(
        "Proximity mode: {:?}, grace: {}ms, pause default: {}s",
        cfg.prox_mode, cfg.prox_grace_ms, cfg.prox_pause_default_s
    );

    let trust_mode_env = match env::var("ARM_TRUST_MODE")
        .unwrap_or_else(|_| "background_ttl".to_string())
        .to_lowercase()
        .as_str()
    {
        "strict" => TrustMode::Strict,
        "office" => TrustMode::Office,
        _ => TrustMode::BackgroundTtl,
    };
    let trust_ttl_secs_env = env::var("ARM_TRUST_TTL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(300)
        .clamp(30, 3600);
    let office_idle_secs_env = env::var("ARM_TRUST_OFFICE_IDLE_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(900);
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let trust_cfg_path = std::path::PathBuf::from(format!("{}/.armadillo/trust.yaml", home));
    let persisted = load_trust_config(&trust_cfg_path).ok().flatten();
    let trust_mode = persisted.as_ref().map(|c| c.mode).unwrap_or(trust_mode_env);
    let trust_ttl_secs = persisted
        .as_ref()
        .map(|c| c.background_ttl_secs)
        .unwrap_or(trust_ttl_secs_env)
        .clamp(30, 3600);
    let office_idle_secs = persisted
        .as_ref()
        .map(|c| c.office_idle_secs)
        .unwrap_or(office_idle_secs_env)
        .max(30);
    let cleanup_timeout_secs = env::var("ARM_TRUST_CLEANUP_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(10);
    let trust = Arc::new(Mutex::new(TrustController::new(
        trust_mode,
        trust_ttl_secs,
        office_idle_secs,
        Duration::from_secs(cleanup_timeout_secs),
    )));

    let unix_bridge = UnixBridge::new(
        &socket_path,
        rate_limiter,
        idempotency,
        proximity,
        trust.clone(),
        audit_writer,
    )
    .await?;
    // Initialize Vault at ~/.armadillo/vault.bin
    let launcher_config_path = format!("{}/.armadillo/launchers.yaml", home);
    let launcher_manager = Arc::new(Mutex::new(LauncherManager::new(&launcher_config_path)));
    {
        let lm = launcher_manager.lock().await;
        info!(event = "launcher.loaded", count = lm.launcher_count());
    }
    let arm_dir = PathBuf::from(format!("{}/.armadillo", home));
    let _ = Vault::enforce_secure_perms(&arm_dir);
    let vault_path = arm_dir.join("vault.bin");
    let vault = Arc::new(Mutex::new(Vault::new(vault_path)));
    let rekey_state: Arc<Mutex<Option<recovery::PendingRekey>>> = Arc::new(Mutex::new(None));
    let auth_ttl_secs = env::var("ARM_AUTH_TTL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(300);
    // M1.5: Initialize AuthState with SystemClock and TTL config
    let clock: Arc<dyn time::Clock> = Arc::new(SystemClock::default());
    let auth_state = Arc::new(Mutex::new(AuthState::new_with_clock(
        clock.clone(),
        Duration::from_secs(cfg.auth_ttl_s),
        Duration::from_secs(cfg.skew_degraded_ttl_s),
        Duration::from_secs(cfg.skew_max_s as u64),
    )));
    let auth_policy = match env::var("ARM_AUTH_POLICY")
        .map(|v| v.to_lowercase())
        .unwrap_or_else(|_| "per_session".to_string())
        .as_str()
    {
        "per_op" => AuthPolicy::PerOp,
        "ttl" => AuthPolicy::Ttl(Duration::from_secs(auth_ttl_secs)),
        _ => AuthPolicy::PerSession,
    };
    let sink_registry = Arc::new(Mutex::new(SinkRegistry::new()));
    // M1.4a: Initialize proximity with config
    let policy = Policy::load();
    let prox_mode = env::var("ARM_PROX_MODE")
        .ok()
        .and_then(|v| match v.to_lowercase().as_str() {
            "auto_unlock" => Some(ProxMode::AutoUnlock),
            "prox_intent" => Some(ProxMode::Intent),
            "prox_first_use" => Some(ProxMode::FirstUse),
            _ => None,
        })
        .unwrap_or_else(|| match policy.proximity_mode_default().as_str() {
            "auto_unlock" => ProxMode::AutoUnlock,
            "prox_intent" => ProxMode::Intent,
            _ => ProxMode::FirstUse,
        });
    let prox_grace = env::var("ARM_PROX_GRACE_S")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(60);
    let prox_pause_max = env::var("ARM_PROX_PAUSE_MAX_S")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(1800);
    let proximity = Arc::new(Mutex::new(Proximity::new(
        prox_mode,
        Duration::from_secs(prox_grace),
        Duration::from_secs(prox_pause_max),
        None, // event callback - using None for now
    )));
    info!(
        role = "agent",
        cat = "policy",
        path = %env::var("ARM_POLICY_PATH").unwrap_or_else(|_| format!("{}/.armadillo/policy.yaml", env::var("HOME").unwrap_or_else(|_| "/tmp".into()))),
        reuse = ?policy.reuse_default(),
        prox_mode = ?prox_mode,
        rules = policy.rule_count(),
        "policy loaded"
    );

    info!(
        role = "agent",
        cat = "app",
        "agent initialized successfully"
    );
    info!(
        role = "agent",
        cat = "uds",
        "waiting for connections from Swift TLS terminator"
    );

    // Start the main event loop
    unix_bridge
        .run(
            pairing_manager,
            vault,
            launcher_manager,
            rekey_state,
            auth_state,
            auth_policy,
            policy,
            sink_registry,
            proximity,
            trust,
        )
        .await?;

    Ok(())
}
