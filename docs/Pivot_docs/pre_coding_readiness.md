# Pre-Coding Readiness Report — SymbiAuth v1 Pivot

**Date:** March 2026 (updated with reviewer corrections)
**Goal:** Everything you need to know before writing the first line of pivot code.

---

## 1. macOS Architecture Findings (from code inspection)

### ✅ Confirmed: ArmadilloTLS IS the menubar app

`AppDelegate.swift` L36:
```swift
NSApp.setActivationPolicy(.accessory) // No dock icon, menu bar only
```

It owns:
- `NSStatusItem` (the 🛡️ icon in menubar)
- `TLSServer` + `BonjourService` + `EnrollmentServer` (pairing)
- `QRDisplayWindow` (QR code for pairing)
- `PairingSessionManager`

**Verdict:** BLETrustCentral **can** live here. It's already the single macOS controller process. No need to create a second app.

### ✅ Confirmed: UDS bridge already works with framed JSON

`UnixSocketBridge.swift` (553 lines):
- Socket path: `~/.armadillo/agent.sock` (with app group fallback)
- Sends `uds.hello` with `role: "tls"` on connect
- Length-prefix framing (matches what Rust expects)
- Has `sendDirect()`, `send(json:completion:)`, `onAgentMessage` callback
- Already handles correlation IDs and dedup

**You can add `trust.verify_request`, `trust.signal_lost`, `trust.signal_present`, `trust.revoke` as new message types through this existing bridge.** No new transport needed.

### ⚠️ Rust `bridge.rs` is MASSIVE (2188 lines)

It handles every message type: vault ops, auth, BLE heartbeat, pairing, TOTP, etc. When adding trust messages, consider:
- Add a separate handler function (don't inline 200 lines in the match arm)
- Or: extract trust logic into a `trust.rs` module and call it from bridge

### ⚠️ Rust `proximity.rs` will be **replaced**, not modified

Current proximity state machine (`Near/Far/Grace/Paused`) is built around:
- `on_tls_up()` / `on_tls_down()` — treats TLS link = presence
- `tick_with_idle()` — BLE + idle gate (partially useful)
- Intent latch from iOS

> **MUST-FIX: Use a feature flag for the swap.** Add `ARM_TRUST_V1=1` env var.
> In `bridge.rs`, choose gating source based on flag:
> - `ARM_TRUST_V1=1` → use new `trust.rs` (trust.is_trusted())
> - unset → use old `proximity.rs` (prox.is_unlocked())
> This prevents "both systems half-on" chaos.

Your new trust state machine (`Locked/Trusted/Revoking` + `Signal Present/Lost` + modes) is different enough that you should:
- Create `trust.rs` alongside `proximity.rs`
- Keep `proximity.rs` alive but dormant until you've verified `trust.rs` works
- Then remove `proximity.rs` in cleanup

### ✅ Confirmed: `ble_scanner.rs` can be deleted

Old btleplug-based BLE scanner that ran in Rust. BLE Central moves to Swift (CoreBluetooth). This file + `ble_global.rs` are dead wood.

---

## 2. What the user asked: TLS role after pivot

### Your assessment is correct:

| Channel | Purpose | When active |
|---------|---------|-------------|
| **TLS** | Pairing only (QR → exchange identities → establish k_ble inputs) | Only during "Add Mac" / re-pair |
| **BLE GATT** | Session channel (challenge → proof → trust grant) | During trust sessions |
| **UDS** | Swift ↔ Rust bridge | Always |
| **Rust** | Authority (HMAC verify, trust state, cleanup) | Always |

### What to do with TLS at pivot time:

1. **Don't delete TLS code yet.** You still need it for pairing.
2. **Don't disable TLS on launch yet.** Keep it running until you've swapped gating off `TlsUpGuard`/proximity and verified BLE trust flow end-to-end. Otherwise the app looks "dead" (nothing passes the proximity gate).
3. **`TlsUpGuard` in bridge.rs** currently tracks "TLS connected = phone present". This needs to be replaced with BLE signal tracking via the `ARM_TRUST_V1` feature flag.
4. **Bonjour service** — once gating is swapped to trust.rs, you can stop auto-publishing. Until then, leave it.
5. **After BLE trust works end-to-end:** switch to TLS-only-on-demand ("Show Pairing QR" triggers TLS + Bonjour).

**Pivot-safe launch sequence (AFTER gating swap):**
```
AppDelegate.applicationDidFinishLaunching:
  1. setupMenuBar()               ← always
  2. connectUDSBridge()            ← always (Rust agent must be running)
  3. startBLECentral()             ← always (scan for phone's GATT service)
  4. // TLS + Bonjour: DON'T start automatically
  //   Start only when user clicks "Show Pairing QR" from menubar
```

---

## 3. Dev Workflow — Tips

### Your current workflow is fine but can be improved:

**Current:**
```
Terminal 1: cargo run --bin agent-macos (Rust)
Terminal 2: xcodebuild + manually run ArmadilloTLS binary (macOS Swift)
Terminal 3: Xcode → Run on iPhone (iOS)
```

**Tips:**

1. **Rust terminal:** Your env vars are good. Consider creating a `run-agent.sh` script:
   ```bash
   #!/bin/bash
   export ARM_PUSH_ENABLED=1
   export ARM_AUTH_POLICY=ttl
   export ARM_AUTH_TTL_SECS=3600
   cargo run --bin agent-macos
   ```
   This prevents typos and makes it easy to adjust settings.

2. **macOS Swift terminal:** Same — create a `run-tls.sh`:
   ```bash
   #!/bin/bash
   xcodebuild -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj \
     -scheme ArmadilloTLS -configuration Debug \
     -derivedDataPath apps/tls-terminator-macos/build build 2>&1 | tail -5

   ARM_WEBEXT_DEV_ID=opojlcnklbhebgdnafldoinkmedgpokk \
   ARM_FEATURE_PIN_UI=1 ARM_LOG_FILE=1 ARM_LOG_LEVEL=info \
   ARM_TLS_KICK_ON_REVOKE=1 \
   apps/tls-terminator-macos/build/Build/Products/Debug/ArmadilloTLS.app/Contents/MacOS/ArmadilloTLS
   ```

3. **iOS:** Xcode → Run is correct. Make sure you're running on a **physical device** (BLE doesn't work in Simulator).

4. **Start order matters:**
   - Start Rust agent **first** (creates the UDS socket)
   - Start ArmadilloTLS **second** (connects to UDS)
   - Start iOS app **last** (needs BLE which needs the Mac to be scanning)

5. **Watch the UDS socket:** If Rust crashes and restarts, you need to restart ArmadilloTLS too (it won't auto-reconnect cleanly in most cases). The bridge has retry logic in `connectToRustAgent()` but only on initial connect.

---

## 4. Things to Know Before You Start (Gotchas)

### A) CoreBluetooth on macOS requires specific permissions

When you add `BLETrustCentral.swift` to ArmadilloTLS:
- Add `NSBluetoothAlwaysUsageDescription` to the macOS app's `Info.plist`
- The app needs Bluetooth entitlement
- On first run, macOS will prompt "ArmadilloTLS wants to use Bluetooth"

### B) CoreBluetooth on iOS: Foreground-only is your friend

- `CBPeripheralManager` advertising works great in foreground
- It stops automatically when the app backgrounds (iOS enforces this — you don't even need code for it)
- But: you DO need to call `stopAdvertising()` explicitly before the system does, to update your UI state properly

### C) BLE GATT Characteristic gotcha: Subscribe BEFORE Write

On the Mac (Central) side:
1. Discover service → discover characteristics
2. **Subscribe** to Proof characteristic (setNotifyValue:true) FIRST
3. **Wait** for `didUpdateNotificationState` callback
4. THEN write challenge to Challenge characteristic
5. Receive proof via `didUpdateValueFor:` notification

If you write the challenge before subscribing to proof, you'll miss the notification.

### D) Face ID on iPhone — LAContext behavior

- `LAContext().evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` works
- But each `LAContext` instance is single-use. Create a new one for each authentication
- If you call `evaluatePolicy` from a background thread, the system UI might not show. Always call on main thread
- Face ID prompt appears instantly (< 1s for the user)

### E) UDS socket path — VERIFIED ✅

Both sides use `~/.armadillo/a.sock`:
- **Rust** (`main.rs` L81): `format!("{}/.armadillo/a.sock", home)`
- **Swift** (`UnixSocketBridge.swift` L19): `.appendingPathComponent("a.sock")`

Both also support `ARMADILLO_SOCKET_PATH` env override.
**No mismatch. You're good.**

### F) Don't hardcode k_ble on both sides unless you *also* hardcode phone_fp

Safer quick slice:
- Hardcode `k_ble` AND hardcode `phone_fp` acceptance in Rust verifier ("accept fp X")
- Or better: keep real derivation and just stub the Rust verifier policy to `ok:true`

This prevents "unknown phone" vs "bad HMAC" confusion when debugging.

### G) "Stop advertising explicitly before system does"

On iOS: call `stopAdvertising()` on background to update UI + internal state. But don't fight the OS: treat background as **session revoked** and clear local state.

### H) `k_ble` derivation — where does the shared secret come from?

You already have `SessionKeyDerivation.swift` (iOS) and `derive_ble_key()` in `wrap.rs` (Rust). Both derive `k_ble` from the pairing material. Make sure:
- Both sides derive the **same** key from the **same** inputs
- Write a test that derives on both sides and compares (you probably already have this)
- If the HMAC fails, 99% chance it's a derivation mismatch, not a crypto bug

### I) Don't break pairing while building trust

While implementing BLE trust:
- Keep TLS pairing working (you need it to pair new test devices)
- Don't remove the QR scanner flow
- Test in this order: pair first → then test BLE trust session

### J) Existing `proximity.rs` fires through `bridge.rs`

The current proximity system is deeply integrated into `bridge.rs`:
- `TlsUpGuard` fires `on_tls_up()` / `on_tls_down()`
- `bridge.rs` checks `prox.is_unlocked()` for gating vault/credential operations
- `bridge_prox_gate.rs` wraps proximity gating logic

When you build the new trust system, you'll need to replace these gates with checks against the new `trust.rs` state. Don't try to run both systems simultaneously — it'll be confusing. Pick a switchover point.

### H) Duplicate pairings in `PairedMacStore`

You noticed the same Mac listed multiple times. This is because `PairedMacStore` adds a new entry on every QR scan without checking if the `macId` already exists. Quick fix: dedup on `macId` when adding. Not urgent but will annoy you during testing.

---

## 5. Recommended First Session (Vertical Slice)

When you start coding, aim for this minimal proof-of-life:

1. **iOS:** `BLETrustServer.swift` — advertise a service, host Challenge (Write) + Proof (Notify) chars
2. **macOS:** `BLETrustCentral.swift` — scan, connect, discover, write challenge, receive proof notification
3. **Both:** Hardcode a test `k_ble` on both sides (skip real derivation for first test)
4. **UDS:** Swift sends `trust.verify_request` → Rust prints it → Rust sends back hardcoded `trust.verify_response` → Swift shows "Trusted" in console

This proves the full pipeline works: iPhone ↔ BLE ↔ Mac Swift ↔ UDS ↔ Rust. Then you plug in real crypto, Face ID, and the state machine.

---

## 6. Source of Truth Recap

| What | Document |
|------|----------|
| Trust modes, state machine, UDS messages, all contracts | `v1_product_spec_states.md` |
| What to build, what to delete, coding phases | `PIVOT_IMPLEMENTATION_PLAN.md` |
| iPhone state machine + logs | `V1_direction.md` (iPhone section only) |
| Features: launchers, vault, cleanup, use cases | `V1_Product_spec.md` (features only) |
| iOS screen structure + navigation | `ios_ui_architecture.md` |
| Post-pivot cleanup sequence | `after_pivot_stable_next.md` |
