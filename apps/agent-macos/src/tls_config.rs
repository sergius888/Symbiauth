// TLS certificate rotation configuration
// Supports dual-pin rotation with staged certificates

use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use tracing::info;

const DEFAULT_ROTATION_WINDOW_DAYS: u32 = 7;
const MIN_ROTATION_WINDOW_DAYS: u32 = 1;
const MAX_ROTATION_WINDOW_DAYS: u32 = 30;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TlsConfig {
    /// Current certificate fingerprint (sha256:hex format)
    pub fp_current: String,

    /// Next certificate fingerprint during rotation (optional)
    pub fp_next: Option<String>,

    /// Path to current active certificate (PEM)
    pub cert_path: String,

    /// Path to staged certificate for rotation (optional)
    pub staged_cert_path: Option<String>,

    /// Timestamp when rotation was started (Unix epoch seconds)
    pub rotation_started_at: Option<u64>,

    /// Rotation window duration in days (default: 7, min: 1, max: 30)
    pub rotation_window_days: u32,
}

impl TlsConfig {
    /// Create new config with current certificate
    pub fn new(cert_path: impl Into<String>, fp_current: impl Into<String>) -> Self {
        Self {
            fp_current: fp_current.into(),
            fp_next: None,
            cert_path: cert_path.into(),
            staged_cert_path: None,
            rotation_started_at: None,
            rotation_window_days: DEFAULT_ROTATION_WINDOW_DAYS,
        }
    }

    /// Check if rotation is currently in progress
    pub fn is_rotating(&self) -> bool {
        self.fp_next.is_some()
    }

    /// Check if rotation window has expired
    pub fn window_expired(&self) -> bool {
        if let Some(started) = self.rotation_started_at {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs();
            let window_seconds = (self.rotation_window_days as u64) * 86400;
            now > started + window_seconds
        } else {
            false
        }
    }

    /// Get days remaining in rotation window
    pub fn days_remaining(&self) -> Option<u32> {
        if let Some(started) = self.rotation_started_at {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs();
            let window_seconds = (self.rotation_window_days as u64) * 86400;
            let elapsed = now.saturating_sub(started);
            if elapsed < window_seconds {
                Some(((window_seconds - elapsed) / 86400) as u32)
            } else {
                Some(0) // Expired
            }
        } else {
            None
        }
    }

    /// Load config from JSON file
    pub fn load(path: impl AsRef<Path>) -> io::Result<Self> {
        let data = fs::read_to_string(path)?;
        serde_json::from_str(&data).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }

    /// Save config to JSON file (atomic write via temp + rename)
    pub fn save(&self, path: impl AsRef<Path>) -> io::Result<()> {
        let path = path.as_ref();

        // Ensure parent directory exists
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;

            // Set directory permissions to 0700
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
            }
        }

        // Write to temp file
        let temp_path = path.with_extension("json.tmp");
        let mut temp_file = File::create(&temp_path)?;
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        temp_file.write_all(json.as_bytes())?;
        temp_file.sync_all()?;

        // Set file permissions to 0600
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&temp_path, fs::Permissions::from_mode(0o600))?;
        }

        // Atomic rename
        fs::rename(&temp_path, path)?;

        info!("TLS config saved to {:?}", path);
        Ok(())
    }

    /// Get default config path
    pub fn default_path() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        Path::new(&home)
            .join("Library")
            .join("Application Support")
            .join("Symbiauth")
            .join("tls.json")
    }

    /// Set rotation window (validates range)
    pub fn set_rotation_window_days(&mut self, days: u32) -> Result<(), String> {
        if days < MIN_ROTATION_WINDOW_DAYS {
            return Err(format!(
                "Window must be at least {} days",
                MIN_ROTATION_WINDOW_DAYS
            ));
        }
        if days > MAX_ROTATION_WINDOW_DAYS {
            return Err(format!(
                "Window must be at most {} days",
                MAX_ROTATION_WINDOW_DAYS
            ));
        }
        self.rotation_window_days = days;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_config_not_rotating() {
        let config = TlsConfig::new("/path/to/cert.pem", "sha256:abc123");
        assert!(!config.is_rotating());
        assert_eq!(config.fp_current, "sha256:abc123");
        assert_eq!(config.rotation_window_days, DEFAULT_ROTATION_WINDOW_DAYS);
    }

    #[test]
    fn test_rotation_state() {
        let mut config = TlsConfig::new("/path/to/cert.pem", "sha256:abc123");

        // Stage rotation
        config.fp_next = Some("sha256:def456".to_string());
        config.rotation_started_at = Some(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs(),
        );

        assert!(config.is_rotating());
        assert!(!config.window_expired());
        assert!(config.days_remaining().unwrap() > 0);
    }

    #[test]
    fn test_window_validation() {
        let mut config = TlsConfig::new("/path/to/cert.pem", "sha256:abc123");

        assert!(config.set_rotation_window_days(0).is_err());
        assert!(config.set_rotation_window_days(31).is_err());
        assert!(config.set_rotation_window_days(7).is_ok());
        assert_eq!(config.rotation_window_days, 7);
    }
}
