# SymbiAuth v1: Foreground GATT Implementation Plan

**Updated:** March 2026
**Canonical trust spec:** `docs/Pivot_docs/v1_product_spec_states.md`

---

## Architecture Summary

| Component | Role | Responsibility |
|-----------|------|----------------|
| **Rust agent** (`agent-macos`) | Authority | HMAC verification, trust state, policy enforcement, cleanup, push events |
| **Swift macOS** (`tls-terminator-macos`) | Transport + UI | BLE central, UDS bridge, menubar, local countdown display |
| **iOS app** (`app-ios`) | Authenticator | Face ID gate, GATT peripheral (server), proof computation |
| **Browser ext** (`webext`) | Consumer | Uses trust state via native messaging (unchanged) |

**Key rule:** Swift does NO crypto. It forwards proof to Rust over UDS. Rust verifies and replies.

---

## 1. What to DELETE

### iOS
- `Features/BLE/BLEAdvertiser.swift` — iBeacon advertiser (dead)

### macOS (Rust)
- `apps/agent-macos/src/ble_scanner.rs` — old btleplug BLE scanner (BLE central moves to Swift)
- Remove btleplug / iBeacon-specific dependencies from `Cargo.toml`

---

## 2. What to CREATE / MODIFY

### A. iOS — GATT Peripheral Server

**New file:** `apps/app-ios/.../Features/BLE/BLETrustServer.swift`

- `CBPeripheralManager` managing a single service (`SYMBIAUTH_V1_SERVICE_UUID`)
- 2 characteristics:
  - **Challenge** (Write, without response): Mac writes `[corr_id | nonce_16 | ttl_req]` to iPhone
  - **Proof** (Notify only): iPhone computes `HMAC(k_ble, "PROOF" || nonce || corr_id || phone_fp || ttl)` and notifies Mac. Mac must subscribe before sending challenge.
- **Starts advertising** only after user taps "Start Session" and Face ID succeeds. No session caching across background transitions.
- **Stops advertising** immediately on: app background, app inactive, user taps "End Session"

### B. macOS Swift — BLE Central (Transport Only)

**New file:** `apps/tls-terminator-macos/ArmadilloTLS/BLE/BLETrustCentral.swift`

> **Note:** BLETrustCentral must live in the same macOS process as the menubar UI.
> Currently the menubar is housed in `tls-terminator-macos`. If you split the menubar
> into its own app later, BLETrustCentral moves with it (not with the TLS bridge).

- `CBCentralManager` scanning for `SYMBIAUTH_V1_SERVICE_UUID`
- On discovery: connect → discover services → discover characteristics
- **Subscribe** to Proof characteristic (Notify)
- Generate 16-byte nonce, write to Challenge characteristic
- Receive proof via Notify callback
- **Forward to Rust** via `trust.verify_request` over UDS (Swift does NOT verify HMAC)
- On BLE link loss → send `trust.signal_lost` to Rust (mandatory)
- On BLE link restored → send `trust.signal_present` to Rust (mandatory)
- Listen for `trust.event` push messages from Rust to update menubar UI

### C. UDS Protocol (Swift ↔ Rust)

**Full protocol defined in** `v1_product_spec_states.md` § "V1 UDS Trust Protocol"

Messages (all framed JSON with `v`, `corr_id`, `ts_ms`):

| Message | Direction | Purpose |
|---------|-----------|---------|
| `trust.verify_request` | Swift → Rust | Forward nonce + proof + phone_fp + `mode_request` + `ttl_request` (Rust clamps and returns `mode_effective` + `ttl_effective`) |
| `trust.verify_response` | Rust → Swift | `ok:true` with grant (trust_id, trust_until_ms, ttl_secs_effective) or `ok:false` with deny reason |
| `trust.signal_lost` | Swift → Rust | **Mandatory.** BLE link to phone lost |
| `trust.signal_present` | Swift → Rust | **Mandatory.** BLE link to phone restored |
| `trust.revoke` | Swift → Rust | User clicked End Session or Mac sleep/lid close |
| `trust.revoke_ack` | Rust → Swift | Acknowledge revoke |
| `trust.event` | Rust → Swift | **Push.** State changes: granted/denied/revoked/signal_lost/signal_present/deadline_started/deadline_cancelled/cleanup_timeout |
| `trust.status` | Swift → Rust | On-demand sync only (app launch, reconnect, debug) |
| `trust.status_response` | Rust → Swift | Full current state snapshot |

### D. Rust Agent — Trust State Machine

**Modify:** `apps/agent-macos/src/proximity.rs` (or new `trust.rs`) + `bridge.rs`

State variables:
- `mode: Strict | BackgroundTTL { ttl_secs } | OfficeMode { idle_secs }`
- `trust: Locked | Trusted { until: Option<Instant> } | Revoking { started_at }`
- `signal: Present | Lost`
- `deadline: Option<Instant>` (Background TTL countdown on signal loss)

Responsibilities:
1. Handle `trust.verify_request` → verify HMAC with `k_ble` → reply `trust.verify_response`
2. Handle `trust.signal_lost` → apply mode rules (Strict: revoke immediately, BackgroundTTL: start deadline, Office: track signal state)
3. Handle `trust.signal_present` → update signal state, do NOT cancel deadline (only `E_TRUST_GRANTED` cancels deadline)
4. 1s tick: check deadline expiry, office idle gate, cleanup timeout, max session duration
5. Push `trust.event` to Swift on every state transition
6. On revoke: kill tracked processes, unmount secrets volume, clear temp files
7. Cleanup timeout: if `Revoking` exceeds `cleanup_timeout_secs` → force to `Locked`

---

## 3. Execution Phases

### PHASE 1: Protocol + Rust Trust State

1. Delete `ble_scanner.rs`, remove from `main.rs`
2. Define all UDS message types in Rust (structs + serde)
3. Update `bridge.rs` to route new message types
4. Implement trust state machine in `proximity.rs` or new `trust.rs`
5. Implement 1s tick loop for deadline/idle/cleanup checks
6. Implement `trust.event` push over UDS

### PHASE 2: iOS GATT Peripheral

1. Delete `BLEAdvertiser.swift`
2. Create `BLETrustServer.swift` with `CBPeripheralManager`
3. Implement Service + Challenge (Write) / Proof (Notify) characteristics
4. Wire to Face ID: start advertising when user taps "Start Session" + Face ID succeeds
5. Stop advertising on: app background, app inactive, user taps "End Session"
6. Each session start requires Face ID (no caching across background transitions)

### PHASE 3: macOS Swift BLE Central

1. Create `BLETrustCentral.swift` with `CBCentralManager`
2. Implement scan → connect → discover → challenge → proof flow
3. Forward proof to Rust via `trust.verify_request`
4. Implement `trust.signal_lost` / `trust.signal_present` reporting
5. Listen for `trust.event` pushes from Rust

### PHASE 4: UI + Orchestration

1. Menubar: show Locked/Trusted/Signal Lost states with mode context
2. Local countdown timer (from `deadline_ms` / `trust_until_ms` in push events)
3. Trust mode selector (Strict / Background TTL / Office)
4. Launchers + cleanup framework in Rust

---

## 4. Reference Documents

| Document | What to use it for |
|----------|-------------------|
| **`v1_product_spec_states.md`** | **SOURCE OF TRUTH** — trust modes, state machine, UDS protocol, all contracts |
| **`V1_direction.md`** | iPhone state machine (IOS_IDLE → IOS_AUTHED_FOREGROUND → IOS_REVOKED) + iPhone logs |
| **`V1_Product_spec.md`** | Feature descriptions (launchers, secret injection, secrets volume, cleanup, use cases) |
| **`Pivot_foreground_gatt.md`** | Narrative/history of why we pivoted (context for new devs) |
| **`after_pivot_stable_next.md`** | Post-pivot sequencing (cleanup → rename → repo → UI) |
| **`pre_pivot_map.md`** | Historical codebase map (pre-pivot file tree) |
