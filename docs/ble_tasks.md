# BLE Proximity Implementation - Task Checklist

**Status:** ✅ Core Implementation Complete - Token Validation Working  
**Date:** February 1, 2026

## Phase 1: Protocol Design ✅
- [x] Choose BLE advertising method (iBeacon selected after rotating UUID/service data failures)
- [x] Define HMAC protocol (ARM/BLE/v1)
- [x] Specify k_ble derivation (ECDH + HKDF)
- [x] Define bucket period (30 seconds)
- [x] Define token format (4 bytes in major/minor)

## Phase 2: iOS Implementation ✅
- [x] Implement BLEAdvertiser using CLBeaconRegion
- [x] Derive k_ble from ECDH shared secret + HKDF
- [x] Generate 4-byte HMAC tokens
- [x] Encode tokens into iBeacon major/minor
- [x] Test background advertising reliability
- [x] **FIX:** Hex-decode device fingerprint for salt derivation (was using UTF-8 string bytes)

## Phase 3: macOS Scanner Implementation ✅
- [x] Implement btleplug-based BLE scanner
- [x] Parse iBeacon manufacturer data
- [x] Extract major/minor → reconstruct token
- [x] Load paired device keys on startup
- [x] Hot-reload keys after new pairing

## Phase 4: Token Validation ✅
- [x] Implement HMAC validation with ±1 bucket tolerance
- [x] Derive k_ble matching iOS implementation
- [x] **FIX:** Use 32-byte salt (was 4 bytes in 3 locations: main.rs, pairing.rs, bridge.rs)
- [x] **FIX:** Hex-decode fingerprint for salt (was using ASCII string bytes)
- [x] **FIX:** Explicit [u8; 32] conversion from GenericArray
- [x] Achieve `ble.token.valid` events

## Phase 5: Integration (TODO - 5 minutes) ⏳
- [ ] Pass Proximity Arc to BleScanner
- [ ] Call `proximity.note_ble_seen(Instant::now(), rssi)` on token validation
- [ ] Test near/far state transitions
- [ ] Verify vault gating responds to BLE proximity

## Phase 6: Documentation ✅
- [x] Document complete implementation journey
- [x] Record all bugs and fixes
- [x] Create protocol specification
- [x] Update SYSTEM_OVERVIEW.md
- [x] Write lessons learned
- [x] Create self-contained technical doc

## Testing ⏳
- [x] Verify continuous beacon detection
- [x] Confirm HMAC validation passes
- [x] Check RSSI measurements
- [ ] Test walk-away → far detection
- [ ] Test return → near detection
- [ ] Test background app stability
- [ ] Test network independence

## Known Issues (Resolved) ✅
- ~~Salt length mismatch (4 vs 32 bytes)~~ → Fixed in all 3 call sites
- ~~iOS using UTF-8 string bytes instead of hex-decoded~~ → Fixed with manual hex decode
- ~~GenericArray conversion issues~~ → Fixed with explicit type conversion
- ~~Fingerprint suffix confusion~~ → Removed from protocol (k_ble already binds identity)

## Current Status

**Working:**
- ✅ iOS iBeacon advertising (background-stable)
- ✅ macOS scanning and detection
- ✅ k_ble derivation matches both sides
- ✅ HMAC validation passes
- ✅ Continuous `ble.token.valid` events at ~1-2s intervals
- ✅ RSSI measurements available (-45dBm typical)

**Remaining:**
- ⏳ Wire BLE events to Proximity module (5 min)
- ⏳ Test state machine transitions
- ⏳ Remove TLS heartbeat dependency

**Next Session:**
1. Add `proximity: Arc<Mutex<Proximity>>` to BleScanner
2. Call `note_ble_seen()` on validation
3. Test near/far transitions
4. Verify vault behavior
