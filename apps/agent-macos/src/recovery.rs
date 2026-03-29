use bip39::{Language, Mnemonic};
use std::time::{Duration, Instant};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub struct PendingRekey {
    pub token: Uuid,
    pub started: Instant,
    pub countdown: Duration,
    pub reason: String,
}

impl PendingRekey {
    pub fn expired(&self) -> bool {
        self.started.elapsed() > self.countdown
    }
}

pub fn generate_mnemonic_12() -> String {
    // 128-bit entropy → 12-word BIP-39 mnemonic (English)
    let m = Mnemonic::generate_in(Language::English, 12).expect("mnemonic");
    m.to_string()
}
