//! Global BLE scanner reference for hot-reload after pairing

use crate::ble_scanner::BleScanner;
use once_cell::sync::OnceCell;
use std::sync::Arc;

/// Global BLE scanner instance (set once at startup)
static BLE_SCANNER: OnceCell<Arc<BleScanner>> = OnceCell::new();

/// Set the global BLE scanner (call once at startup)
pub fn set_ble_scanner(scanner: Arc<BleScanner>) {
    let _ = BLE_SCANNER.set(scanner);
}

/// Get the global BLE scanner reference
pub fn get_ble_scanner() -> Option<&'static Arc<BleScanner>> {
    BLE_SCANNER.get()
}
