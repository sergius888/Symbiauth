# SymbiAuth Core Engine — Spec v1.0

**Local-only. Fail-closed. Intent-driven unlock. Proximity-leashed session.**
**Mac = gatekeeper / source of truth. iPhone = biometric trigger.**
**Transport:** BLE iBeacon for proximity. TLS for pairing + FaceID approvals only.

---

## 0) Goals and Non-Goals

### Goals
1. Unlock requires **explicit user intent** (widget tap + FaceID on iPhone)
2. Stay unlocked only while iPhone is **physically near** (valid BLE token received)
3. **Fail closed**: BLE leash breaks → vault locks, memory purged
4. **No auto-unlock** when beacon returns after lock — new FaceID intent always required
5. Must work on installed iOS app, phone locked, backgrounded

### Non-Goals (v1)
- System-level macOS unlock
- Cloud / push notifications / remote approvals
- RSSI-based boundary enforcement (RSSI is telemetry only)
- UI polish beyond minimal menu bar + iOS widget

---

## 1) System Components

| Component | Role |
|-----------|------|
| **macOS agent (Rust)** | Scans BLE, validates tokens, owns state machine, gates vault |
| **iOS app (Swift)** | Lock screen widget button → FaceID → start/refresh iBeacon |
| **Pairing (existing)** | QR + local TLS to establish k_ble material |

---

## 2) States

```
LOCKED ←───────────────────────────────────────────┐
   │                                                │
   │ IntentAuthorized                               │
   │ + valid BLE token                              │ GraceExpired / Mac idle
   ▼                                                │
UNLOCKED ──── BLE timeout + Mac active ──→ GRACE ──┘
   │
   └── BLE timeout + Mac IDLE ──→ LOCKED (immediate)
```

---

## 3) Transitions

### LOCKED → UNLOCKED
- Requires: valid BLE token seen **AND** `IntentAuthorized` (widget tap + FaceID) within session window
- Action: unseal vault into RAM, emit `vault.unlocked`

### UNLOCKED → GRACE
- Condition: `now - last_ble_seen > LEASH_TIMEOUT_SECS`
- AND `mac_idle_age < MAC_IDLE_THRESHOLD_SECS` (user is active)
- Action: show warning notification + menu bar blinking, start grace timer

### UNLOCKED → LOCKED (immediate)
- Condition: BLE timeout AND `mac_idle_age >= MAC_IDLE_THRESHOLD_SECS`
- Action: purge vault from RAM, `vault.locked`

### GRACE → UNLOCKED
- Condition: valid BLE token received before grace expires
- Action: cancel timer, stay unlocked (no re-decrypt needed)

### GRACE → LOCKED
- Condition: grace timer expires with no BLE token
- Action: purge vault, `vault.locked`

### ⚠️ CRITICAL: beacon return after LOCKED → stays LOCKED
- Must require new widget tap + FaceID to restart

---

## 4) Config (all tunable, no hardcoding)

| Variable | Default | Description |
|----------|---------|-------------|
| `LEASH_TIMEOUT_SECS` | 15s | BLE silence before entering GRACE or LOCKED |
| `MAC_IDLE_THRESHOLD_SECS` | 180s | Mac inactivity = assume user left room |
| `GRACE_PERIOD_SECS` | 30s | Time to re-auth before vault locks |
| `BUCKET_PERIOD_SECS` | 30 | iBeacon token rotation period |

---

## 5) BLE Protocol (unchanged from current implementation)

- iBeacon UUID: fixed
- Token: `HMAC-SHA256(k_ble, "ARM/BLE/v1" || bucket_be_u64)[0..4]`
- Encoded into: `major = token[0..2]`, `minor = token[2..4]`
- Verification: accept `bucket ∈ {bucket-1, bucket, bucket+1}`

---

## 6) Mac Idle Detection (NEW - Rust, macOS-specific)

Query macOS `HIDIdleTime` via IOKit:

```rust
// apps/agent-macos/src/mac_idle.rs
pub fn mac_idle_secs() -> u64 {
    // IOServiceGetMatchingService("IOHIDSystem")
    // IORegistryEntryCreateCFProperty("HIDIdleTime")
    // Returns nanoseconds, convert to seconds
}
```

Called by proximity tick to decide GRACE vs immediate LOCK.

---

## 7) iOS Widget (NEW - App Intent)

```swift
// ArmadilloMobile/Widget/AuthorizeIntent.swift
import AppIntents
import LocalAuthentication

struct AuthorizeIntent: AppIntent {
    static var title: LocalizedStringResource = "Authorize Mac"
    
    func perform() async throws -> some IntentResult {
        // 1. FaceID
        let ok = await FaceIDAuthenticator.shared.authenticate()
        guard ok else { throw AuthError.faceIDFailed }
        
        // 2. Start/refresh iBeacon advertising
        BLEAdvertiser.shared.refreshSession()
        
        return .result()
    }
}
```

---

## 8) Required Logging

**macOS:**
- `ble.token.valid fp bucket bucket_delta rssi`
- `prox.ble_seen age_ms rssi`
- `prox.ble_timeout ble_age_ms`
- `prox.state from=X to=Y reason=Z`
- `vault.locked reason` / `vault.unlocked`
- `mac.idle_secs`

**iOS:**
- `ble.bucket bucket period`
- `ble.token token_hex`
- `ble.ibeacon major minor`
- `intent.authorized` / `intent.failed reason`

---

## 9) Acceptance Tests

| Test | Pass Condition |
|------|----------------|
| **A: Happy path** | Widget tap → FaceID → Mac sees token → UNLOCKED |
| **B: Walk away** | BLE lost + Mac idle → LOCKED within `LEASH_TIMEOUT + MAC_IDLE` |
| **C: Active work BLE drop** | BLE drops while typing → GRACE → re-tap widget → stays UNLOCKED |
| **D: No auto-unlock** | BLE returns after LOCKED → stays LOCKED |
| **E: Force quit** | App swiped away → BLE stops → vault locks after timeout |
| **F: Background overnight** | Phone locked 8h → no crash, beacon resumes on next widget tap |

---

## 10) What Force-Quit Means (and why it's OK)

Force-quit = BLE stops = vault locks after `LEASH_TIMEOUT_SECS`.
This is **correct security behavior**, not a bug.
User re-opens app and taps widget to restore access.
Document this honestly in UX: "Closing the app locks the vault."
