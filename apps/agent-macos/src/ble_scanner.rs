//! BLE scanner for proximity detection - iBeacon format
//!
//! Scans for iOS iBeacon advertisements with 4-byte HMAC token in major+minor

use btleplug::api::{Central, Manager as _, Peripheral as _, ScanFilter};
use btleplug::platform::{Adapter, Manager};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, info};

type HmacSha256 = Hmac<Sha256>;

/// iBeacon company ID (Apple = 0x004C)
const APPLE_COMPANY_ID: u16 = 0x004C;

/// iBeacon ProximityUUID (must match iOS)
const BEACON_UUID: &str = "8E7F0B31-4B6E-4F2A-9E3A-6F1B2D7C9A10";

/// BLE bucket period in seconds (must match iOS)
const BUCKET_PERIOD_SECS: u64 = 30;

/// BLE scanner state
pub struct BleScanner {
    adapter: Adapter,
    /// Paired devices with their k_ble keys: fp_suffix -> k_ble
    paired_devices: Arc<RwLock<std::collections::HashMap<String, Vec<u8>>>>,
    /// Channel for sending proximity events
    prox_tx: tokio::sync::mpsc::Sender<crate::proximity::ProxInput>,
    /// Epoch ms of the last received iBeacon matching our UUID
    last_seen_ms: std::sync::atomic::AtomicU64,
    /// Epoch ms of the last validated iBeacon token
    last_valid_ms: std::sync::atomic::AtomicU64,
}

impl BleScanner {
    /// Create a new BLE scanner
    pub async fn new(
        prox_tx: tokio::sync::mpsc::Sender<crate::proximity::ProxInput>,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let manager = Manager::new().await?;

        // Get the first Bluetooth adapter
        let adapters = manager.adapters().await?;
        let adapter = adapters
            .into_iter()
            .next()
            .ok_or("No Bluetooth adapter found")?;

        info!(event = "ble.scanner.init");

        Ok(Self {
            adapter,
            paired_devices: Arc::new(RwLock::new(std::collections::HashMap::new())),
            prox_tx,
            last_seen_ms: std::sync::atomic::AtomicU64::new(0),
            last_valid_ms: std::sync::atomic::AtomicU64::new(0),
        })
    }

    /// Update paired devices with their BLE keys
    pub async fn update_paired_devices(&self, devices: std::collections::HashMap<String, Vec<u8>>) {
        let mut guard = self.paired_devices.write().await;

        // Log k_ble fingerprints (hash prefix only, never log key)
        for (fp, k_ble) in devices.iter() {
            use sha2::{Digest, Sha256};
            let mut h = Sha256::new();
            h.update(k_ble);
            let out = h.finalize();
            let k_hash_8 = hex::encode(&out[..8]);
            info!(
                event = "ble.k_ble",
                fp = %fp,
                k_len = k_ble.len(),
                k_sha256_8 = %k_hash_8
            );
        }

        *guard = devices;
        info!(event = "ble.scanner.devices_updated", count = guard.len());
    }

    /// Start scanning for BLE advertisements
    pub async fn start_scan(self: Arc<Self>) -> Result<(), Box<dyn std::error::Error>> {
        info!(event = "ble.scan.start");

        // Start scanning (no filter)
        self.adapter.start_scan(ScanFilter::default()).await?;

        info!(
            event = "ble.scan.active",
            msg = "Scanning for iBeacon advertisements..."
        );

        // Poll for peripherals periodically
        let mut count = 0;
        loop {
            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
            count += 1;

            if count % 15 == 0 {
                let now_ms = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_millis() as u64;
                let seen = self.last_seen_ms.load(std::sync::atomic::Ordering::Relaxed);
                let valid = self
                    .last_valid_ms
                    .load(std::sync::atomic::Ordering::Relaxed);

                let seen_age = if seen > 0 {
                    now_ms.saturating_sub(seen)
                } else {
                    0
                };
                let valid_age = if valid > 0 {
                    now_ms.saturating_sub(valid)
                } else {
                    0
                };

                info!(
                    event = "ble.scan.heartbeat",
                    iterations = count,
                    last_seen_age_ms = seen_age,
                    last_valid_age_ms = valid_age
                );
            }

            let peripherals = self.adapter.peripherals().await?;
            debug!(event = "ble.scan.poll", peripherals = peripherals.len());

            for peripheral in peripherals {
                self.handle_device_discovered(peripheral.id()).await;
            }
        }
    }

    // Helper method to process a discovered device
    async fn handle_device_discovered(&self, id: btleplug::platform::PeripheralId) {
        if let Ok(peripheral) = self.adapter.peripheral(&id).await {
            if let Ok(Some(props)) = peripheral.properties().await {
                // Look for Apple manufacturer data (iBeacon)
                for (company_id, data) in props.manufacturer_data.iter() {
                    if *company_id == APPLE_COMPANY_ID && data.len() >= 23 {
                        // iBeacon format:
                        // byte 0-1: type (0x02, 0x15)
                        // byte 2-17: ProximityUUID (16 bytes)
                        // byte 18-19: major (2 bytes)
                        // byte 20-21: minor (2 bytes)
                        // byte 22: measured power

                        if data[0] == 0x02 && data[1] == 0x15 {
                            let uuid_bytes = &data[2..18];
                            let major = u16::from_be_bytes([data[18], data[19]]);
                            let minor = u16::from_be_bytes([data[20], data[21]]);

                            // Check if this is our ProximityUUID
                            let uuid_str = format!(
                                "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
                                uuid_bytes[0], uuid_bytes[1], uuid_bytes[2], uuid_bytes[3],
                                uuid_bytes[4], uuid_bytes[5],
                                uuid_bytes[6], uuid_bytes[7],
                                uuid_bytes[8], uuid_bytes[9],
                                uuid_bytes[10], uuid_bytes[11], uuid_bytes[12], uuid_bytes[13], uuid_bytes[14], uuid_bytes[15]
                            );

                            if uuid_str == BEACON_UUID {
                                let now_secs = std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap()
                                    .as_secs();
                                let bucket = now_secs / BUCKET_PERIOD_SECS;

                                self.last_seen_ms.store(
                                    std::time::SystemTime::now()
                                        .duration_since(std::time::UNIX_EPOCH)
                                        .unwrap()
                                        .as_millis() as u64,
                                    std::sync::atomic::Ordering::Relaxed,
                                );

                                info!(
                                    event = "ble.ibeacon.found",
                                    name = ?props.local_name,
                                    rssi = ?props.rssi,
                                    major = major,
                                    minor = minor,
                                    now_secs = now_secs,
                                    bucket = bucket
                                );

                                // Reconstruct 4-byte token from major+minor
                                let token4 = [
                                    (major >> 8) as u8,
                                    (major & 0xFF) as u8,
                                    (minor >> 8) as u8,
                                    (minor & 0xFF) as u8,
                                ];

                                self.validate_token(&token4, props.rssi).await;
                            }
                        }
                    }
                }
            }
        }
    }

    /// Validate a 4-byte token against paired devices
    async fn validate_token(&self, token_bytes: &[u8; 4], rssi: Option<i16>) {
        let devices = self.paired_devices.read().await;

        info!(
            event = "ble.validate_token.start",
            token = %hex::encode(token_bytes),
            paired_devices = devices.len()
        );

        let now_secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();

        let bucket_now = now_secs / BUCKET_PERIOD_SECS;
        info!(
            event = "ble.validate_token.before_loop",
            now_secs = now_secs,
            bucket_now = bucket_now,
            devices_count = devices.len(),
            devices_keys = ?devices.keys().collect::<Vec<_>>()
        );
        info!(
            event = "ble.validate_token.loop_start",
            devices_len = devices.len()
        );

        let mut tried = 0usize;
        // Try to validate against each paired device (±1 bucket)
        for (fp_suffix, k_ble) in devices.iter() {
            tried += 1;
            info!(
                event = "ble.trying_device_V3_2026_01_30",
                fp_suffix = %fp_suffix,
                k_ble_len = k_ble.len()
            );

            for bucket_delta in [-4i64, -3, -2, -1, 0, 1, 2, 3, 4] {
                let bucket = ((now_secs as i64 + bucket_delta * BUCKET_PERIOD_SECS as i64) as u64)
                    / BUCKET_PERIOD_SECS;

                if self.validate_token_for_device(token_bytes, k_ble, fp_suffix, bucket) {
                    self.last_valid_ms.store(
                        std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap()
                            .as_millis() as u64,
                        std::sync::atomic::Ordering::Relaxed,
                    );
                    info!(
                        event = "ble.token.valid",
                        fp_suffix = %fp_suffix,
                        rssi = ?rssi,
                        bucket_delta = bucket_delta,
                        bucket = bucket
                    );

                    // Send proximity update event (non-blocking)
                    let _ = self.prox_tx.try_send(crate::proximity::ProxInput::BleSeen {
                        fp: fp_suffix.to_string(),
                        rssi,
                        now: std::time::Instant::now(),
                    });

                    return;
                }
            }
        }

        info!(event = "ble.validate_token.loop_end", tried = tried);

        // Only log if we have paired devices
        if !devices.is_empty() {
            info!(event = "ble.token.no_match", token = %hex::encode(token_bytes));
        }
    }

    fn validate_token_for_device(
        &self,
        token_bytes: &[u8; 4],
        k_ble: &[u8],
        _fp_full: &str,
        bucket: u64,
    ) -> bool {
        // ARM/BLE/v1 protocol: HMAC(k_ble, "ARM/BLE/v1" || bucket_be_u64)
        // No suffix needed - k_ble already binds device

        let mut msg = Vec::with_capacity(11 + 8);
        msg.extend_from_slice(b"ARM/BLE/v1");
        msg.extend_from_slice(&bucket.to_be_bytes());

        info!(
            event = "ble.hmac.preimage",
            protocol = "ARM/BLE/v1",
            bucket = bucket,
            msg_hex = %hex::encode(&msg)
        );

        // HMAC-SHA256
        let mut mac = HmacSha256::new_from_slice(k_ble).expect("HMAC creation failed");
        mac.update(&msg);
        let result = mac.finalize().into_bytes();

        // Compare first 4 bytes
        &result[..4] == token_bytes
    }
}
