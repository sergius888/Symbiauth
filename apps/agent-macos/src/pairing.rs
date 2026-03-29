use crate::wrap::{agent_wrap_public_sec1, ensure_agent_wrap_secret};
use base64::Engine;
use chrono::Utc;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use tracing::{debug, info, warn};
use uuid::Uuid;

#[derive(Clone)]
pub struct PairingManager {
    active_sessions: HashMap<String, PairingSession>,
    paired_devices: HashMap<String, PairedDevice>,
}

#[derive(Clone, Debug)]
pub struct PairingSession {
    #[allow(dead_code)] // Kept for future pairing session introspection.
    pub session_id: String,
    pub pairing_token: String,
    pub expires_at: SystemTime,
    pub sas_code: Option<String>,
    #[allow(dead_code)] // Kept for deferred pairing diagnostics surface.
    pub agent_fingerprint: String,
}

#[derive(Clone, Debug)]
pub struct PairedDevice {
    #[allow(dead_code)] // Reserved for richer paired-device UI/diagnostics.
    pub cert_fingerprint: String,
    #[allow(dead_code)] // Reserved for richer paired-device UI/diagnostics.
    pub device_name: String,
    #[allow(dead_code)] // Reserved for richer paired-device UI/diagnostics.
    pub paired_at: SystemTime,
    #[allow(dead_code)] // Reserved for richer paired-device UI/diagnostics.
    pub last_seen: SystemTime,
    pub ios_wrap_pub_sec1: Option<Vec<u8>>, // SEC1 uncompressed public key (65 bytes)
}

impl PairingManager {
    pub fn new() -> Self {
        Self {
            active_sessions: std::collections::HashMap::new(),
            paired_devices: std::collections::HashMap::new(),
        }
    }

    /// Load persisted devices from disk on startup
    pub fn load_persisted(&mut self) {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        let base = std::path::Path::new(&home)
            .join(".armadillo")
            .join("paired_devices");
        self.load_persisted_from(&base);
    }

    fn is_hex64(s: &str) -> bool {
        s.len() == 64
            && s.bytes()
                .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f' | b'A'..=b'F'))
    }

    fn is_valid_fp_dir(name: &str) -> bool {
        if let Some(rest) = name.strip_prefix("sha256:") {
            return Self::is_hex64(rest);
        }
        name.starts_with("legacy-")
    }

    fn is_valid_sec1_pub(buf: &[u8]) -> bool {
        buf.len() == 65 && buf[0] == 0x04
    }

    pub fn load_persisted_from(&mut self, base: &std::path::Path) {
        let mut count = 0usize;
        let mut keys: Vec<String> = Vec::new();
        let mut skipped = 0usize;

        let entries = match std::fs::read_dir(base) {
            Ok(e) => e,
            Err(err) => {
                tracing::info!(
                    event = "paired_devices.loaded",
                    count = 0usize,
                    skipped = 0usize,
                    keys = ?keys,
                    path = base.display().to_string(),
                    err = %err
                );
                return;
            }
        };

        for entry in entries.flatten() {
            let meta = match entry.metadata() {
                Ok(m) => m,
                Err(err) => {
                    skipped += 1;
                    tracing::warn!(event="paired_devices.skip", reason="metadata", err=%err);
                    continue;
                }
            };
            if !meta.is_dir() {
                continue;
            }

            let fp = entry.file_name().to_string_lossy().to_string();
            if !Self::is_valid_fp_dir(&fp) {
                skipped += 1;
                tracing::warn!(event="paired_devices.skip", reason="bad_dir_name", fp=%fp);
                continue;
            }

            let pub_file = entry.path().join("ios_wrap_pub.sec1");
            let mut f = match std::fs::File::open(&pub_file) {
                Ok(f) => f,
                Err(err) => {
                    skipped += 1;
                    tracing::warn!(event="paired_devices.skip", reason="missing_pub", fp=%fp, path=%pub_file.display(), err=%err);
                    continue;
                }
            };

            let mut buf = Vec::new();
            if let Err(err) = std::io::Read::read_to_end(&mut f, &mut buf) {
                skipped += 1;
                tracing::warn!(event="paired_devices.skip", reason="read_pub", fp=%fp, err=%err);
                continue;
            }

            if !Self::is_valid_sec1_pub(&buf) {
                skipped += 1;
                tracing::warn!(event="paired_devices.skip", reason="bad_sec1", fp=%fp, len=buf.len(), first=?buf.get(0));
                continue;
            }

            let short_fp = fp.chars().take(14).collect::<String>();
            let device = PairedDevice {
                cert_fingerprint: fp.clone(),
                device_name: format!("Loaded {}", short_fp),
                paired_at: std::time::SystemTime::now(),
                last_seen: std::time::SystemTime::UNIX_EPOCH,
                ios_wrap_pub_sec1: Some(buf),
            };

            self.paired_devices.insert(fp.clone(), device);
            keys.push(short_fp);
            count += 1;
        }

        tracing::info!(
            event = "paired_devices.loaded",
            count = count,
            skipped = skipped,
            keys = ?keys,
            path = base.display().to_string()
        );
    }

    /// Delete a specific paired device directory and remove it from memory.
    /// Returns true if filesystem cleanup succeeded (best-effort).
    #[allow(dead_code)] // Reserved for targeted unpair operation UI.
    pub fn delete_paired(&mut self, device_fp: &str) -> bool {
        // Remove from in-memory map
        self.paired_devices.remove(device_fp);
        // Remove on-disk artifacts
        let dir = Self::paired_device_dir(device_fp);
        let ok = match fs::remove_dir_all(&dir) {
            Ok(_) => true,
            Err(e) => {
                // It's ok if not found; consider it cleaned
                if e.kind() == std::io::ErrorKind::NotFound {
                    true
                } else {
                    warn!("failed to remove paired device dir {:?}: {}", dir, e);
                    false
                }
            }
        };
        info!(event = "pin.revoke.agent.cleaned", fp = %device_fp);
        ok
    }

    /// Delete all paired device state on disk and memory.
    pub fn delete_all_paired(&mut self) -> bool {
        self.paired_devices.clear();
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        let base = Path::new(&home).join(".armadillo").join("paired_devices");
        let ok = match fs::remove_dir_all(&base) {
            Ok(_) => true,
            Err(e) => {
                if e.kind() == std::io::ErrorKind::NotFound {
                    true
                } else {
                    warn!("failed to remove paired_devices base {:?}: {}", base, e);
                    false
                }
            }
        };
        info!(event = "pin.reset.agent.cleaned");
        ok
    }

    fn paired_device_dir(fp: &str) -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        Path::new(&home)
            .join(".armadillo")
            .join("paired_devices")
            .join(fp.replace('/', "_"))
    }

    fn persist_ios_wrap_pub(fp: &str, sec1: &[u8]) {
        let dir = Self::paired_device_dir(fp);
        if let Err(e) = fs::create_dir_all(&dir) {
            warn!("failed to create paired device dir {:?}: {}", dir, e);
            return;
        }
        // Best-effort permissions: 0700 on dir
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
        }

        let file_path = dir.join("ios_wrap_pub.sec1");
        match fs::File::create(&file_path) {
            Ok(mut f) => {
                if let Err(e) = f.write_all(sec1) {
                    warn!("failed to write ios_wrap_pub to {:?}: {}", file_path, e);
                } else {
                    // 0600 on file
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        let _ = fs::set_permissions(&file_path, fs::Permissions::from_mode(0o600));
                    }
                    info!("persisted ios wrap pub for fp {}", fp);
                }
            }
            Err(e) => {
                warn!("failed to create ios_wrap_pub file {:?}: {}", file_path, e);
            }
        }
    }

    fn load_ios_wrap_pub(fp: &str) -> Option<Vec<u8>> {
        let file_path = Self::paired_device_dir(fp).join("ios_wrap_pub.sec1");
        let mut f = fs::File::open(&file_path).ok()?;
        let mut buf = Vec::new();
        if f.read_to_end(&mut buf).is_ok() && (!buf.is_empty()) {
            Some(buf)
        } else {
            None
        }
    }

    pub fn get_or_load_ios_wrap_pub_vec(&self, device_fp: &str) -> Option<Vec<u8>> {
        if let Some(bytes) = self
            .paired_devices
            .get(device_fp)
            .and_then(|d| d.ios_wrap_pub_sec1.as_ref())
        {
            return Some(bytes.clone());
        }
        Self::load_ios_wrap_pub(device_fp)
    }

    pub async fn handle_message(&mut self, message: Value) -> Value {
        let msg_type = message.get("type").and_then(|t| t.as_str());

        match msg_type {
            Some("pairingRequest") => self.handle_pairing_request(message).await,
            Some("sasConfirm") => self.handle_sas_confirm(message).await,
            Some("pairing.complete") => self.handle_pairing_complete(message).await,
            Some("ping") => self.handle_ping(message).await,
            Some(unknown_type) => {
                warn!("Unknown message type: {}", unknown_type);
                json!({
                    "type": "error",
                    "code": "UNKNOWN_MESSAGE_TYPE",
                    "message": format!("Unknown message type: {}", unknown_type)
                })
            }
            None => {
                warn!("Message missing type field");
                json!({
                    "type": "error",
                    "code": "MISSING_TYPE",
                    "message": "Message must include a 'type' field"
                })
            }
        }
    }

    async fn handle_pairing_request(&mut self, message: Value) -> Value {
        debug!("Handling pairing request: {:?}", message);

        // Extract required fields
        let sid = match message.get("sid").and_then(|s| s.as_str()) {
            Some(s) => s,
            None => return self.error_response("MISSING_FIELD", "Missing session ID"),
        };

        let tok = match message.get("tok").and_then(|t| t.as_str()) {
            Some(t) => t,
            None => return self.error_response("MISSING_FIELD", "Missing pairing token"),
        };

        let device_id = match message.get("deviceId").and_then(|d| d.as_str()) {
            Some(d) => d,
            None => return self.error_response("MISSING_FIELD", "Missing device ID"),
        };

        let _client_fp = match message.get("clientFp").and_then(|f| f.as_str()) {
            Some(f) => f,
            None => return self.error_response("MISSING_FIELD", "Missing client fingerprint"),
        };

        // Validate session exists and token matches
        let session = match self.active_sessions.get(sid) {
            Some(s) => s,
            None => return self.error_response("INVALID_SESSION", "Session not found or expired"),
        };

        if session.pairing_token != tok {
            return self.error_response("INVALID_TOKEN", "Invalid pairing token");
        }

        // Check if session has expired
        if SystemTime::now() > session.expires_at {
            self.active_sessions.remove(sid);
            return self.error_response("SESSION_EXPIRED", "Pairing session has expired");
        }

        // Generate SAS code (6-digit)
        let sas_code = format!("{:06}", rand::random::<u32>() % 1000000);

        // Update session with SAS code
        if let Some(session) = self.active_sessions.get_mut(sid) {
            session.sas_code = Some(sas_code.clone());
        }

        info!("Pairing request accepted for device: {}", device_id);

        json!({
            "type": "pairingResponse",
            "success": true,
            "sasRequired": true,
            "sasCode": sas_code
        })
    }

    async fn handle_sas_confirm(&mut self, message: Value) -> Value {
        debug!("Handling SAS confirmation: {:?}", message);

        let confirmed = match message.get("confirmed").and_then(|c| c.as_bool()) {
            Some(c) => c,
            None => return self.error_response("MISSING_FIELD", "Missing confirmation field"),
        };

        if confirmed {
            info!("SAS confirmed - pairing complete");
            // In a real implementation, we would store the paired device here
            json!({
                "type": "pairingResponse",
                "success": true,
                "sasRequired": false
            })
        } else {
            info!("SAS rejected - pairing failed");
            json!({
                "type": "pairingResponse",
                "success": false,
                "sasRequired": false,
                "error": "SAS verification failed"
            })
        }
    }

    async fn handle_pairing_complete(&mut self, message: Value) -> Value {
        debug!("Handling pairing.complete: {:?}", message);

        let sid = match message.get("sid").and_then(|v| v.as_str()) {
            Some(v) => v.to_string(),
            None => return self.error_response("MISSING_FIELD", "Missing sid"),
        };
        let device_fp = match message.get("device_fp").and_then(|v| v.as_str()) {
            Some(v) => v.to_string(),
            None => return self.error_response("MISSING_FIELD", "Missing device_fp"),
        };
        let agent_fp = match message.get("agent_fp").and_then(|v| v.as_str()) {
            Some(v) => v.to_string(),
            None => return self.error_response("MISSING_FIELD", "Missing agent_fp"),
        };
        let _sas = message
            .get("sas")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        // Optional: iOS wrap public key in base64 (SEC1 uncompressed 65 bytes)
        let ios_wrap_pub_sec1 = message
            .get("wrap_pub_ios_b64")
            .and_then(|v| v.as_str())
            .and_then(|b64| base64::engine::general_purpose::STANDARD.decode(b64).ok());

        // Persist a minimal trust record
        let now = SystemTime::now();
        let device_name = format!(
            "ios-{}",
            &device_fp.chars().rev().take(6).collect::<String>()
        );
        // Log wrap pubkey length if present
        if let Some(ref bytes) = ios_wrap_pub_sec1 {
            let len = bytes.len();
            if len == 65 && bytes.get(0) == Some(&0x04) {
                info!(
                    wrap_pub_len = len,
                    "pairing: received ios wrap pubkey (SEC1 uncompressed)"
                );
            } else {
                info!(
                    wrap_pub_len = len,
                    first = bytes.get(0).copied().unwrap_or(0xff),
                    "pairing: ios wrap pubkey invalid format"
                );
            }
            // Persist for robustness across restarts
            Self::persist_ios_wrap_pub(&device_fp, bytes);
        } else {
            info!("pairing: ios wrap pubkey not provided");
        }

        let entry = PairedDevice {
            cert_fingerprint: device_fp.clone(),
            device_name,
            paired_at: now,
            last_seen: now,
            ios_wrap_pub_sec1: ios_wrap_pub_sec1.clone(),
        };
        self.paired_devices.insert(device_fp.clone(), entry);

        info!(
            sid = %sid,
            agent_fingerprint = %agent_fp,
            device_fingerprint = %device_fp,
            "pairing complete stored"
        );

        // ✅ Hot-reload BLE scanner with this device's k_ble key
        if let Some(ref ios_pub) = ios_wrap_pub_sec1 {
            Self::reload_ble_keys_for_device(&device_fp, ios_pub);
        }

        json!({
            "type": "pairing.ack",
            "status": "ok",
            "ts": chrono::Utc::now().to_rfc3339(),
            // Expose agent wrap public key (SEC1 uncompressed) so iOS can derive k_session via ECDH
            "wrap_pub_mac_b64": (|| {
                if let Ok(sk) = ensure_agent_wrap_secret() {
                    let sec1 = agent_wrap_public_sec1(&sk);
                    base64::engine::general_purpose::STANDARD.encode(sec1)
                } else { String::new() }
            })()
        })
    }

    async fn handle_ping(&self, message: Value) -> Value {
        debug!("Handling ping request: {:?}", message);

        // Echo back the timestamp if provided, otherwise use current time
        let timestamp = match message.get("timestamp").and_then(|t| t.as_str()) {
            Some(ts) => ts.to_string(),
            None => Utc::now().to_rfc3339(),
        };
        let corr_id = message
            .get("corr_id")
            .and_then(|c| c.as_str())
            .unwrap_or("");

        json!({
            "type": "pong",
            "v": 1,
            "timestamp": timestamp,
            "corr_id": corr_id
        })
    }

    #[allow(dead_code)] // Reserved for legacy pairing flow compatibility.
    pub fn create_pairing_session(&mut self, agent_fingerprint: String) -> PairingSession {
        let session_id = Uuid::new_v4().to_string();
        let pairing_token = Uuid::new_v4().to_string();
        let expires_at = SystemTime::now() + std::time::Duration::from_secs(300); // 5 minutes

        let session = PairingSession {
            session_id: session_id.clone(),
            pairing_token,
            expires_at,
            sas_code: None,
            agent_fingerprint,
        };

        self.active_sessions
            .insert(session_id.clone(), session.clone());

        info!("Created pairing session: {}", session_id);
        session
    }

    #[allow(dead_code)] // Reserved for long-lived session cleanup in deferred flow.
    pub fn cleanup_expired_sessions(&mut self) {
        let now = SystemTime::now();
        let expired_sessions: Vec<String> = self
            .active_sessions
            .iter()
            .filter(|(_, session)| now > session.expires_at)
            .map(|(id, _)| id.clone())
            .collect();

        for session_id in expired_sessions {
            self.active_sessions.remove(&session_id);
            info!("Removed expired session: {}", session_id);
        }
    }

    fn error_response(&self, code: &str, message: &str) -> Value {
        json!({
            "type": "error",
            "code": code,
            "message": message
        })
    }

    pub fn get_ios_wrap_pub_by_fp(&self, device_fp: &str) -> Option<&[u8]> {
        self.paired_devices
            .get(device_fp)
            .and_then(|d| d.ios_wrap_pub_sec1.as_deref())
    }

    /// Get all paired devices
    pub fn get_all_paired(&self) -> &HashMap<String, PairedDevice> {
        &self.paired_devices
    }

    /// Hot-reload BLE scanner keys after pairing (synchronous - spawns task)
    fn reload_ble_keys_for_device(fp_suffix: &str, ios_pub_sec1: &[u8]) {
        use crate::wrap::{derive_ble_key, ensure_agent_wrap_secret};

        let fp = fp_suffix.to_string();
        let ios_pub = ios_pub_sec1.to_vec();

        // Spawn task to reload keys asynchronously
        tokio::spawn(async move {
            if let Some(scanner) = crate::ble_global::get_ble_scanner() {
                if let Ok(sk) = ensure_agent_wrap_secret() {
                    // Derive 32-byte salt: SHA256("arm-ble-salt-v1" || fp_bytes)
                    use sha2::{Digest, Sha256};
                    let fp_clean = fp.strip_prefix("sha256:").unwrap_or(&fp);
                    let salt = if let Ok(fp_bytes) = hex::decode(fp_clean) {
                        if fp_bytes.len() == 32 {
                            let mut h = Sha256::new();
                            h.update(b"arm-ble-salt-v1");
                            h.update(&fp_bytes);
                            let hash = h.finalize();
                            let arr: [u8; 32] = hash.into();
                            arr
                        } else {
                            tracing::warn!(event="ble.salt.bad_fp", fp=%fp, reason="not 32 bytes");
                            [0u8; 32]
                        }
                    } else {
                        tracing::warn!(event="ble.salt.bad_fp", fp=%fp, reason="hex decode failed");
                        [0u8; 32]
                    };

                    match derive_ble_key(&sk, &ios_pub, &salt) {
                        Ok(k_ble) => {
                            let mut keys = std::collections::HashMap::new();
                            keys.insert(fp.clone(), k_ble.to_vec());
                            scanner.update_paired_devices(keys).await;
                            tracing::info!(
                                fp_suffix = %fp.chars().take(8).collect::<String>(),
                                "ble.keys.reloaded after pairing"
                            );
                        }
                        Err(e) => {
                            tracing::warn!("Failed to derive k_ble after pairing: {:?}", e);
                        }
                    }
                } else {
                    tracing::warn!("No agent wrap secret for BLE key derivation");
                }
            } else {
                tracing::warn!("BLE scanner not initialized, cannot reload keys");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn loads_valid_sec1_pubkey() {
        let dir = tempdir().unwrap();
        let paired = dir.path().join("paired_devices");
        let dev =
            paired.join("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        fs::create_dir_all(&dev).unwrap();

        // 65 bytes, 0x04 prefix
        let mut sec1 = vec![0u8; 65];
        sec1[0] = 0x04;
        fs::write(dev.join("ios_wrap_pub.sec1"), sec1).unwrap();

        let mut pm = PairingManager::new();
        pm.load_persisted_from(&paired);
        assert_eq!(pm.paired_devices.len(), 1);
    }

    #[test]
    fn skips_invalid_short_pubkey() {
        let dir = tempdir().unwrap();
        let paired = dir.path().join("paired_devices");
        let dev =
            paired.join("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        fs::create_dir_all(&dev).unwrap();

        // 10 bytes, too short
        let mut sec1 = vec![0u8; 10];
        sec1[0] = 0x04;
        fs::write(dev.join("ios_wrap_pub.sec1"), sec1).unwrap();

        let mut pm = PairingManager::new();
        pm.load_persisted_from(&paired);
        assert_eq!(pm.paired_devices.len(), 0);
    }
}
