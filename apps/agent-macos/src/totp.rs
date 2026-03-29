//! TOTP engine + storage (Keychain on macOS, file fallback elsewhere)
// RFC 6238 (HMAC-SHA1, 30s step, ±1 step tolerance)

use data_encoding::BASE32_NOPAD;
use hmac::{Hmac, Mac};
use rand::RngCore;
use sha1::Sha1;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha1 = Hmac<Sha1>;

#[derive(thiserror::Error, Debug)]
pub enum TotpError {
    #[error("keychain error: {0}")]
    Keychain(String),
    #[error("io error: {0}")]
    Io(String),
    #[error("not enrolled")]
    NotEnrolled,
    #[error("invalid code")]
    InvalidCode,
}

const SERVICE: &str = "com.armadillo.totp";
const ACCOUNT: &str = "default";
const FILE_NAME: &str = "totp.secret";
const SECRET_LEN: usize = 20; // 160-bit per RFC 4226
const STEP: u64 = 30; // seconds
const SKEW: i64 = 1; // ±1 step tolerance

// -------- Secret generation / encode -----------------------------------------

pub fn generate_secret() -> [u8; SECRET_LEN] {
    let mut s = [0u8; SECRET_LEN];
    rand::thread_rng().fill_bytes(&mut s);
    s
}

pub fn secret_b32(secret: &[u8]) -> String {
    BASE32_NOPAD.encode(secret)
}

// -------- Code generation / verify -------------------------------------------

fn hotp(secret: &[u8], counter: u64) -> u32 {
    let mut mac = HmacSha1::new_from_slice(secret).unwrap();
    mac.update(&counter.to_be_bytes());
    let digest = mac.finalize().into_bytes();
    let offset = (digest[19] & 0x0f) as usize;
    let bin_code = ((digest[offset] as u32 & 0x7f) << 24)
        | ((digest[offset + 1] as u32) << 16)
        | ((digest[offset + 2] as u32) << 8)
        | (digest[offset + 3] as u32);
    bin_code % 1_000_000
}

pub fn totp_now(secret: &[u8], unix_time: u64) -> u32 {
    let counter = unix_time / STEP;
    hotp(secret, counter)
}

pub fn verify_code(secret: &[u8], user_code: u32, unix_time: u64) -> bool {
    for off in -SKEW..=SKEW {
        let ct = ((unix_time as i64 + (off * STEP as i64)) / STEP as i64) as u64;
        if hotp(secret, ct) == user_code {
            return true;
        }
    }
    false
}

// -------- Storage (Keychain on macOS; file on others) ------------------------

#[cfg(all(target_os = "macos", feature = "mac-keychain"))]
mod store {
    use super::*;
    use security_framework::passwords;

    pub fn store(secret: &[u8]) -> Result<(), TotpError> {
        passwords::set_generic_password(SERVICE, ACCOUNT, secret)
            .map_err(|e| TotpError::Keychain(format!("{e}")))?;
        Ok(())
    }

    pub fn load() -> Result<Vec<u8>, TotpError> {
        passwords::get_generic_password(SERVICE, ACCOUNT).map_err(|_| TotpError::NotEnrolled)
    }

    pub fn revoke() -> Result<(), TotpError> {
        passwords::delete_generic_password(SERVICE, ACCOUNT)
            .map_err(|e| TotpError::Keychain(format!("{e}")))?;
        Ok(())
    }
}

#[cfg(not(all(target_os = "macos", feature = "mac-keychain")))]
mod store {
    use super::*;
    fn path() -> PathBuf {
        let dir = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
        dir.join(".armadillo").join(FILE_NAME)
    }
    pub fn store(secret: &[u8]) -> Result<(), TotpError> {
        let p = path();
        if let Some(parent) = p.parent() {
            fs::create_dir_all(parent).map_err(|e| TotpError::Io(e.to_string()))?;
        }
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&p)
            .map_err(|e| TotpError::Io(e.to_string()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&p, fs::Permissions::from_mode(0o600));
        }
        f.write_all(secret)
            .map_err(|e| TotpError::Io(e.to_string()))
    }
    pub fn load() -> Result<Vec<u8>, TotpError> {
        let p = path();
        fs::read(&p).map_err(|_| TotpError::NotEnrolled)
    }
    pub fn revoke() -> Result<(), TotpError> {
        let p = path();
        if p.exists() {
            fs::remove_file(&p).map_err(|e| TotpError::Io(e.to_string()))?;
        }
        Ok(())
    }
}

// Re-export storage API
pub fn store_totp_secret(secret: &[u8]) -> Result<(), TotpError> {
    store::store(secret)
}
pub fn load_totp_secret() -> Result<Vec<u8>, TotpError> {
    store::load()
}
pub fn revoke_totp_secret() -> Result<(), TotpError> {
    store::revoke()
}

// -------- otpauth:// URL + ASCII QR -----------------------------------------

pub fn otpauth_url(label: &str, secret: &[u8]) -> String {
    let s = secret_b32(secret);
    // issuer fixed to "Armadillo" for now
    format!(
        "otpauth://totp/{}?secret={}&issuer=Armadillo",
        urlencoding::encode(label),
        s
    )
}

pub fn ascii_qr(s: &str) -> String {
    use qrcode::QrCode;
    let code = QrCode::new(s.as_bytes()).unwrap();
    code.render::<qrcode::render::unicode::Dense1x2>()
        .quiet_zone(true)
        .module_dimensions(1, 2)
        .build()
}

// -------- Helpers ------------------------------------------------------------

pub fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

// -------- Tests --------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // RFC test secret (20 bytes)
    const TEST_SECRET: &[u8] = b"12345678901234567890";

    #[test]
    fn totp_vector_matches() {
        // Known vector time
        let t = 1234567890u64;
        // Generate code at that time
        let code = totp_now(TEST_SECRET, t);
        // Verify same
        assert!(verify_code(TEST_SECRET, code, t));
        // Within skew window
        assert!(verify_code(TEST_SECRET, code, t + 25));
        assert!(verify_code(TEST_SECRET, code, t - 25));
        // Outside skew window
        assert!(!verify_code(TEST_SECRET, code, t + 70));
    }

    #[test]
    fn secret_roundtrip_b32() {
        let s = generate_secret();
        let enc = secret_b32(&s);
        let dec = BASE32_NOPAD.decode(enc.as_bytes()).unwrap();
        assert_eq!(dec, s);
    }
}
