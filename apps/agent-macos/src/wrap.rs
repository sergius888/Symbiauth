use hkdf::Hkdf;
use p256::ecdh::diffie_hellman;
use p256::{PublicKey, SecretKey};
use sha2::Sha256;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

#[derive(thiserror::Error, Debug)]
pub enum WrapError {
    #[error("io: {0}")]
    Io(String),
    #[error("crypto")]
    Crypto,
    #[error("invalid_pubkey")]
    InvalidPubkey,
}

fn wrap_sk_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(format!("{}/.armadillo/mac_wrap_sk.bin", home))
}

/// Ensure a persistent P-256 secret key exists for the agent; returns SecretKey
pub fn ensure_agent_wrap_secret() -> Result<SecretKey, WrapError> {
    let path = wrap_sk_path();
    if path.exists() {
        let bytes = fs::read(&path).map_err(|e| WrapError::Io(e.to_string()))?;
        if bytes.len() != 32 {
            return Err(WrapError::Crypto);
        }
        let sk = SecretKey::from_slice(&bytes).map_err(|_| WrapError::Crypto)?;
        Ok(sk)
    } else {
        let sk = SecretKey::random(&mut rand::thread_rng());
        let bytes = sk.to_bytes().to_vec();
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let mut f = fs::File::create(&path).map_err(|e| WrapError::Io(e.to_string()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&path)
                .map_err(|e| WrapError::Io(e.to_string()))?
                .permissions();
            perms.set_mode(0o600);
            let _ = fs::set_permissions(&path, perms);
        }
        f.write_all(&bytes)
            .map_err(|e| WrapError::Io(e.to_string()))?;
        Ok(sk)
    }
}

/// Return agent wrap public key in SEC1 uncompressed form (65 bytes)
pub fn agent_wrap_public_sec1(sk: &SecretKey) -> [u8; 65] {
    let pk = sk.public_key();
    pk.to_sec1_bytes().to_vec().try_into().expect("65 bytes")
}

/// Derive K_wrap from agent secret and iOS public SEC1 bytes, with a stable salt
pub fn derive_wrap_key(
    sk: &SecretKey,
    ios_pub_sec1: &[u8],
    salt_bytes: &[u8],
) -> Result<[u8; 32], WrapError> {
    let ios_pk = PublicKey::from_sec1_bytes(ios_pub_sec1).map_err(|_| WrapError::InvalidPubkey)?;
    let ss = diffie_hellman(sk.to_nonzero_scalar(), ios_pk.as_affine());
    let ikm = ss.raw_secret_bytes();
    let hk = Hkdf::<Sha256>::new(Some(salt_bytes), &ikm);
    let mut okm = [0u8; 32];
    hk.expand(b"armadillo/wrap/v1", &mut okm)
        .map_err(|_| WrapError::Crypto)?;
    Ok(okm)
}

/// Derive BLE presence key using the same ECDH base with different HKDF info label
pub fn derive_ble_key(
    sk: &SecretKey,
    ios_pub_sec1: &[u8],
    salt_bytes: &[u8],
) -> Result<[u8; 32], WrapError> {
    use sha2::{Digest, Sha256 as Sha256Hash};
    use tracing::info;

    let ios_pk = PublicKey::from_sec1_bytes(ios_pub_sec1).map_err(|_| WrapError::InvalidPubkey)?;
    let ss = diffie_hellman(sk.to_nonzero_scalar(), ios_pk.as_affine());
    let ikm = ss.raw_secret_bytes();

    // Debug: log KDF components (hashes only)
    let sha256_8_hex = |bytes: &[u8]| -> String {
        let mut h = Sha256Hash::new();
        h.update(bytes);
        let out = h.finalize();
        hex::encode(&out[..8])
    };

    info!(
        event = "ble.shared",
        shared_sha256_8 = %sha256_8_hex(&ikm),
        shared_len = ikm.len()
    );
    info!(
        event = "ble.salt",
        salt_sha256_8 = %sha256_8_hex(salt_bytes),
        salt_len = salt_bytes.len()
    );
    info!(event = "ble.info", info = "arm/ble/v1");

    let hk = Hkdf::<Sha256>::new(Some(salt_bytes), &ikm);
    let mut okm = [0u8; 32];
    hk.expand(b"arm/ble/v1", &mut okm)
        .map_err(|_| WrapError::Crypto)?;

    info!(
        event = "ble.k_ble.final",
        k_sha256_8 = %sha256_8_hex(&okm),
        k_len = okm.len()
    );

    Ok(okm)
}
