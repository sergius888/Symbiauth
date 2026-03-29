use aes_gcm::{
    aead::{rand_core::RngCore, Aead, OsRng},
    Aes256Gcm, KeyInit,
};
use base64::Engine;
// Temporarily allow deprecated GenericArray until aes-gcm 0.11 is stable
#[allow(deprecated)]
use generic_array::GenericArray;
use serde::{Deserialize, Serialize};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
use tracing::{error, info}; // *

#[derive(thiserror::Error, Debug)]
pub enum VaultError {
    #[error("locked")]
    Locked,
    #[error("not found")]
    NotFound,
    #[error("io: {0}")]
    Io(String),
    #[error("crypto")]
    Crypto,
}

#[derive(Serialize, Deserialize)]
struct VaultPlain {
    entries: HashMap<String, String>, // base64 values
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CredentialRecord {
    pub origin: String,
    pub user: String,
    pub secret: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub meta: Option<serde_json::Value>,
}

pub struct Vault {
    path: PathBuf,
    unlocked: bool,
    last_activity: Instant,
    idle_timeout: Duration,
    kv: HashMap<String, Vec<u8>>,
    k_vault: Option<[u8; 32]>,
    k_session: Option<[u8; 32]>,
    k_wrap: Option<[u8; 32]>,
}

const CRED_PREFIX: &str = "cred/"; // *

impl Vault {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            unlocked: false,
            last_activity: Instant::now(),
            idle_timeout: Duration::from_secs(300),
            kv: HashMap::new(),
            k_vault: None,
            k_session: None,
            k_wrap: None,
        }
    }

    // * Permissions hardening helpers
    pub fn enforce_secure_perms(dir: &Path) -> Result<(), VaultError> {
        // *
        if let Err(e) = fs::create_dir_all(dir) {
            return Err(VaultError::Io(e.to_string()));
        }
        #[cfg(unix)]
        {
            if let Ok(meta) = fs::metadata(dir) {
                let mut p = meta.permissions();
                if p.mode() & 0o777 != 0o700 {
                    p.set_mode(0o700);
                    let _ = fs::set_permissions(dir, p);
                    info!(event = "perms.fixed", what = "dir", path = %dir.display(), mode = "0700");
                } else {
                    info!(event = "perms.ok", what = "dir", path = %dir.display(), mode = "0700");
                }
            }
        }
        Ok(())
    }

    fn chmod_0600(path: &Path) -> Result<(), VaultError> {
        // *
        #[cfg(unix)]
        {
            if let Ok(meta) = fs::metadata(path) {
                let mut p = meta.permissions();
                if p.mode() & 0o777 != 0o600 {
                    p.set_mode(0o600);
                    if let Err(e) = fs::set_permissions(path, p) {
                        return Err(VaultError::Io(e.to_string()));
                    }
                }
            }
        }
        Ok(())
    }

    pub fn open(&mut self, k_session: [u8; 32]) -> Result<(), VaultError> {
        // Store current session key for persistence
        self.k_session = Some(k_session);

        if self.path.exists() {
            // Inspect header once
            let bytes = fs::read(&self.path).map_err(|e| VaultError::Io(e.to_string()))?;
            let header_ver = if bytes.len() >= 5 && &bytes[0..4] == b"ARMV" {
                Some(bytes[4])
            } else {
                None
            };
            let start = Instant::now();
            let mut loaded = false;

            // 1) Stable wrap path for v3
            if header_ver == Some(3) {
                if let Some(k_wrap) = self.k_wrap {
                    match self.try_open_v3(&bytes, &k_wrap) {
                        Ok(()) => {
                            loaded = true;
                            let elapsed = start.elapsed().as_millis();
                            info!(
                                role = "agent",
                                cat = "vault",
                                event = "vault.unwrapped",
                                ver = 3,
                                wrapped = "stable",
                                elapsed_ms = elapsed
                            );
                        }
                        Err(e) => {
                            let elapsed = start.elapsed().as_millis();
                            error!(role = "agent", cat = "vault", event = "VAULT_UNWRAP_FAILED", wrapped = "stable", err = ?e, elapsed_ms = elapsed);
                        }
                    }
                }
            }

            // 2) Legacy v2 path
            if !loaded && header_ver == Some(2) {
                if self.try_open_v2(&bytes, &k_session).is_ok() {
                    loaded = true;
                    let elapsed = start.elapsed().as_millis();
                    info!(
                        role = "agent",
                        cat = "vault",
                        event = "vault.unwrapped",
                        ver = 2,
                        wrapped = "session",
                        elapsed_ms = elapsed
                    );
                    // Auto-migrate to v3 if wrap key available and not disabled
                    let migrate_enabled = std::env::var("ARM_VAULT_MIGRATE")
                        .map(|v| v != "0")
                        .unwrap_or(true);
                    if migrate_enabled {
                        if let Some(_k_wrap) = self.k_wrap {
                            // persist() will use v3 if k_wrap is set
                            if let Err(e) = self.persist() {
                                let _ = e;
                            } else {
                                info!(
                                    role = "agent",
                                    cat = "vault",
                                    event = "vault.migrated",
                                    from = 2,
                                    to = 3
                                );
                            }
                        }
                    }
                }
            }

            // 3) Unknown/other or both attempts failed → initialize
            if !loaded {
                self.k_vault = Some(rand::random());
                self.kv.clear();
                self.persist()?;
            }
        } else {
            // Fresh vault: create new K_vault and persist v2 envelope
            self.k_vault = Some(rand::random());
            self.kv.clear();
            self.persist()?;
        }

        self.unlocked = true;
        self.touch();
        Ok(())
    }

    pub fn set_wrap_key(&mut self, k_wrap: [u8; 32]) {
        self.k_wrap = Some(k_wrap);
    }

    pub fn status(&self) -> (bool, usize, u128) {
        (
            self.unlocked,
            self.kv.len(),
            self.last_activity.elapsed().as_millis(),
        )
    }

    pub fn read(&mut self, key: &str) -> Result<Vec<u8>, VaultError> {
        self.ensure_unlocked()?;
        self.touch();
        self.kv.get(key).cloned().ok_or(VaultError::NotFound)
    }

    pub fn write(&mut self, key: &str, value: &[u8]) -> Result<(), VaultError> {
        self.ensure_unlocked()?;
        self.touch();
        self.kv.insert(key.to_string(), value.to_vec());
        self.persist()
    }

    pub fn lock(&mut self) -> Result<(), VaultError> {
        self.zeroize();
        Ok(())
    }

    // *
    pub fn list_credentials(&mut self, origin: &str) -> Result<Vec<String>, VaultError> {
        self.ensure_unlocked()?;
        self.touch();
        let prefix = format!("{}{}/", CRED_PREFIX, origin);
        let mut accounts: Vec<String> = self
            .kv
            .keys()
            .filter_map(|k| k.strip_prefix(&prefix).map(|u| u.to_string()))
            .collect();
        accounts.sort();
        accounts.dedup();
        Ok(accounts)
    }

    // *
    pub fn read_credential(
        &mut self,
        origin: &str,
        username: &str,
    ) -> Result<CredentialRecord, VaultError> {
        self.ensure_unlocked()?;
        self.touch();
        let key = format!("{}{}/{}", CRED_PREFIX, origin, username);
        let raw = self.kv.get(&key).cloned().ok_or(VaultError::NotFound)?;
        serde_json::from_slice(&raw).map_err(|e| VaultError::Io(e.to_string()))
    }

    /// Write a credential record under the cred namespace.
    pub fn write_credential(
        &mut self,
        origin: &str,
        username: &str,
        secret: &str,
        meta: Option<serde_json::Value>,
    ) -> Result<(), VaultError> {
        self.ensure_unlocked()?;
        self.touch();
        let key = format!("{}{}/{}", CRED_PREFIX, origin, username);
        let rec = CredentialRecord {
            origin: origin.to_string(),
            user: username.to_string(),
            secret: secret.to_string(),
            meta,
        };
        let raw = serde_json::to_vec(&rec).map_err(|e| VaultError::Io(e.to_string()))?;
        self.write(&key, &raw)
    }

    pub fn tick_idle(&mut self) {
        if self.unlocked && self.last_activity.elapsed() >= self.idle_timeout {
            let _ = self.lock();
        }
    }

    fn try_open_v2(&mut self, bytes: &[u8], k_session: &[u8; 32]) -> Result<(), VaultError> {
        // File format v2:
        // [0..4]  = "ARMV"
        // [4]     = version (2)
        // [5..7]  = reserved (2 bytes) currently unused (set to 0)
        // [7..9]  = kvault_ct_len (u16 BE)
        // [9..21] = kvault_nonce (12 bytes)
        // [21..21+L] = kvault_ct (L bytes)
        // [..+12] = content_nonce (12 bytes)
        // [..end] = content_ct

        if bytes.len() < 4 + 1 + 2 + 2 + 12 + 12 + 16 {
            return Err(VaultError::Crypto);
        }
        if &bytes[0..4] != b"ARMV" {
            return Err(VaultError::Crypto);
        }
        let ver = bytes[4];
        if ver != 2 {
            return Err(VaultError::Crypto);
        }
        let kv_len = u16::from_be_bytes([bytes[7], bytes[8]]) as usize;
        let kv_nonce_start = 9;
        let kv_ct_start = kv_nonce_start + 12;
        let kv_ct_end = kv_ct_start + kv_len;
        if bytes.len() < kv_ct_end + 12 + 16 {
            return Err(VaultError::Crypto);
        }

        let kv_nonce = &bytes[kv_nonce_start..kv_nonce_start + 12];
        let kv_ct = &bytes[kv_ct_start..kv_ct_end];

        // Unwrap K_vault using k_session
        let ks_cipher = Aes256Gcm::new(GenericArray::from_slice(k_session));
        let kvault_bytes = ks_cipher
            .decrypt(GenericArray::from_slice(kv_nonce), kv_ct)
            .map_err(|_| VaultError::Crypto)?;
        if kvault_bytes.len() != 32 {
            return Err(VaultError::Crypto);
        }
        let mut kvault = [0u8; 32];
        kvault.copy_from_slice(&kvault_bytes);
        self.k_vault = Some(kvault);

        // Decrypt content using K_vault
        let content_nonce_start = kv_ct_end;
        let content_ct_start = content_nonce_start + 12;
        if content_ct_start > bytes.len() {
            return Err(VaultError::Crypto);
        }
        let content_nonce = &bytes[content_nonce_start..content_nonce_start + 12];
        let content_ct = &bytes[content_ct_start..];

        let cipher = Aes256Gcm::new(GenericArray::from_slice(&kvault));
        let pt = cipher
            .decrypt(GenericArray::from_slice(content_nonce), content_ct)
            .map_err(|_| VaultError::Crypto)?;
        let plain: VaultPlain =
            serde_json::from_slice(&pt).map_err(|e| VaultError::Io(e.to_string()))?;
        self.kv.clear();
        for (k, v_b64) in plain.entries.into_iter() {
            if let Ok(v) = base64::engine::general_purpose::STANDARD.decode(v_b64) {
                self.kv.insert(k, v);
            }
        }
        Ok(())
    }

    fn try_open_v3(&mut self, bytes: &[u8], k_wrap: &[u8; 32]) -> Result<(), VaultError> {
        // File format v3 (stable wrap):
        // [0..4]  = "ARMV"
        // [4]     = version (3)
        // [5..7]  = reserved (2)
        // [7..9]  = kvault_ct_len (u16 BE)
        // [9..21] = kvault_nonce (12)
        // [21..21+L] = kvault_ct (L)
        // [..+12] = content_nonce (12)
        // [..end] = content_ct
        if bytes.len() < 4 + 1 + 2 + 2 + 12 + 12 + 16 {
            return Err(VaultError::Crypto);
        }
        if &bytes[0..4] != b"ARMV" {
            return Err(VaultError::Crypto);
        }
        let ver = bytes[4];
        if ver != 3 {
            return Err(VaultError::Crypto);
        }
        let kv_len = u16::from_be_bytes([bytes[7], bytes[8]]) as usize;
        let kv_nonce_start = 9;
        let kv_ct_start = kv_nonce_start + 12;
        let kv_ct_end = kv_ct_start + kv_len;
        if bytes.len() < kv_ct_end + 12 + 16 {
            return Err(VaultError::Crypto);
        }

        let kv_nonce = &bytes[kv_nonce_start..kv_nonce_start + 12];
        let kv_ct = &bytes[kv_ct_start..kv_ct_end];

        // Unwrap K_vault using k_wrap
        let wrap_cipher = Aes256Gcm::new(GenericArray::from_slice(k_wrap));
        let kvault_bytes = wrap_cipher
            .decrypt(GenericArray::from_slice(kv_nonce), kv_ct)
            .map_err(|_| VaultError::Crypto)?;
        if kvault_bytes.len() != 32 {
            return Err(VaultError::Crypto);
        }
        let mut kvault = [0u8; 32];
        kvault.copy_from_slice(&kvault_bytes);
        self.k_vault = Some(kvault);

        // Decrypt content using K_vault
        let content_nonce_start = kv_ct_end;
        let content_ct_start = content_nonce_start + 12;
        if content_ct_start > bytes.len() {
            return Err(VaultError::Crypto);
        }
        let content_nonce = &bytes[content_nonce_start..content_nonce_start + 12];
        let content_ct = &bytes[content_ct_start..];

        let cipher = Aes256Gcm::new(GenericArray::from_slice(&kvault));
        let pt = cipher
            .decrypt(GenericArray::from_slice(content_nonce), content_ct)
            .map_err(|_| VaultError::Crypto)?;
        let plain: VaultPlain =
            serde_json::from_slice(&pt).map_err(|e| VaultError::Io(e.to_string()))?;
        self.kv.clear();
        for (k, v_b64) in plain.entries.into_iter() {
            if let Ok(v) = base64::engine::general_purpose::STANDARD.decode(v_b64) {
                self.kv.insert(k, v);
            }
        }
        Ok(())
    }

    fn persist(&self) -> Result<(), VaultError> {
        // Build plaintext map
        let mut map: HashMap<String, String> = HashMap::new();
        for (k, v) in &self.kv {
            map.insert(
                k.clone(),
                base64::engine::general_purpose::STANDARD.encode(v),
            );
        }
        let plain = VaultPlain { entries: map };
        let pt = serde_json::to_vec(&plain).map_err(|e| VaultError::Io(e.to_string()))?;

        let kvault = self.k_vault.ok_or(VaultError::Crypto)?;

        // Encrypt content with K_vault
        let content_cipher = Aes256Gcm::new(GenericArray::from_slice(&kvault));
        let mut content_nonce = [0u8; 12];
        OsRng.fill_bytes(&mut content_nonce);
        let content_ct = content_cipher
            .encrypt(GenericArray::from_slice(&content_nonce), pt.as_ref())
            .map_err(|_| VaultError::Crypto)?;

        // Decide wrap mode: stable (v3) if k_wrap present; else legacy session (v2)
        if let Some(k_wrap) = self.k_wrap {
            // Wrap K_vault with k_wrap
            let wrap_cipher = Aes256Gcm::new(GenericArray::from_slice(&k_wrap));
            let mut kv_nonce = [0u8; 12];
            OsRng.fill_bytes(&mut kv_nonce);
            let kv_ct = wrap_cipher
                .encrypt(GenericArray::from_slice(&kv_nonce), &kvault[..])
                .map_err(|_| VaultError::Crypto)?;

            // Assemble v3 file
            let mut out =
                Vec::with_capacity(4 + 1 + 2 + 2 + 12 + kv_ct.len() + 12 + content_ct.len());
            out.extend_from_slice(b"ARMV");
            out.push(3u8); // version 3 (stable wrap)
            out.extend_from_slice(&[0u8; 2]);
            out.extend_from_slice(&(kv_ct.len() as u16).to_be_bytes());
            out.extend_from_slice(&kv_nonce);
            out.extend_from_slice(&kv_ct);
            out.extend_from_slice(&content_nonce);
            out.extend_from_slice(&content_ct);
            if let Some(parent) = self.path.parent() {
                let _ = fs::create_dir_all(parent);
            }
            // atomic write: write to tmp then rename
            let tmp = self.path.with_extension("bin.tmp");
            fs::write(&tmp, &out).map_err(|e| VaultError::Io(e.to_string()))?;
            fs::rename(&tmp, &self.path).map_err(|e| VaultError::Io(e.to_string()))?;
            // set 0600
            let _ = Self::chmod_0600(&self.path);
            info!(role = "agent", cat = "vault", ver = 3, "vault.persisted");
            Ok(())
        } else {
            // Legacy session-wrap path (v2) — requires k_session in-memory
            let ksession = self.k_session.ok_or(VaultError::Crypto)?;
            let wrap_cipher = Aes256Gcm::new(GenericArray::from_slice(&ksession));
            let mut kv_nonce = [0u8; 12];
            OsRng.fill_bytes(&mut kv_nonce);
            let kv_ct = wrap_cipher
                .encrypt(GenericArray::from_slice(&kv_nonce), &kvault[..])
                .map_err(|_| VaultError::Crypto)?;
            let mut out =
                Vec::with_capacity(4 + 1 + 2 + 2 + 12 + kv_ct.len() + 12 + content_ct.len());
            out.extend_from_slice(b"ARMV");
            out.push(2u8); // version 2 (session wrap)
            out.extend_from_slice(&[0u8; 2]);
            out.extend_from_slice(&(kv_ct.len() as u16).to_be_bytes());
            out.extend_from_slice(&kv_nonce);
            out.extend_from_slice(&kv_ct);
            out.extend_from_slice(&content_nonce);
            out.extend_from_slice(&content_ct);
            if let Some(parent) = self.path.parent() {
                let _ = fs::create_dir_all(parent);
            }
            let tmp = self.path.with_extension("bin.tmp");
            fs::write(&tmp, &out).map_err(|e| VaultError::Io(e.to_string()))?;
            fs::rename(&tmp, &self.path).map_err(|e| VaultError::Io(e.to_string()))?;
            let _ = Self::chmod_0600(&self.path);
            info!(role = "agent", cat = "vault", ver = 2, "vault.persisted");
            Ok(())
        }
    }

    fn ensure_unlocked(&self) -> Result<(), VaultError> {
        if self.unlocked {
            Ok(())
        } else {
            Err(VaultError::Locked)
        }
    }
    fn touch(&mut self) {
        self.last_activity = Instant::now();
    }
    fn zeroize(&mut self) {
        self.unlocked = false;
        self.k_vault = self.k_vault.map(|mut k| {
            for b in &mut k {
                *b = 0;
            }
            k
        });
        self.k_session = self.k_session.map(|mut k| {
            for b in &mut k {
                *b = 0;
            }
            k
        });
        self.k_wrap = self.k_wrap.map(|mut k| {
            for b in &mut k {
                *b = 0;
            }
            k
        });
        self.kv.clear();
    }

    // * Status helpers for recovery
    pub fn is_locked(&self) -> bool {
        !self.unlocked
    } // *

    // * Rekey in place: generate a new K_vault and persist under current wrap/session mode
    pub fn rekey_in_place(&mut self) -> Result<(), VaultError> {
        // *
        self.ensure_unlocked()?;
        self.k_vault = Some(rand::random());
        self.persist()?;
        Ok(())
    }
}
