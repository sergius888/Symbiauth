# System Overview — Updated 2026-02-01

Canonical summary of architecture, flows, and behaviors. Truth sources:
- `docs/SYSTEM_OVERVIEW.md` (this doc)
- `docs/proximity_rules.md` (proximity/session semantics)
- `docs/auth_flow.md` (UX narrative)
- `docs/progress_2025-12-30.md` (checkpoint, commands, risks)
- `docs/BLE_IMPLEMENTATION.md` (BLE proximity - fully implemented 2026-02-01)
- `docs/ble_tasks.md` (BLE checklist)

## Purpose (Goal)
Secure password/credential retrieval with proximity + user approval:
- Primary: when phone is near (BLE/mTLS), fills are allowed per policy and session TTL.
- Secondary: when phone is away, block or require explicit step-up (e.g., TOTP/Face ID).

## Architecture (Current)
- **Agent (Rust, macOS)**: core policy/gating, vault, proximity/session enforcement. Communicates via UDS. **NEW:** BLE scanner validates iBeacon tokens.
- **TLS Terminator (Swift, macOS)**: mTLS bridge to iOS; forwards messages to agent over UDS. Used for pairing and Face ID approvals (not proximity).
- **iOS App**: mTLS client, Face ID approvals, pairing. **NEW:** BLE iBeacon advertiser broadcasts HMAC-secured tokens continuously (background-stable).
- **nmhost (Rust)**: Native Messaging host for the browser extension; forwards extension messages over UDS to agent; forwards status to popup.
- **Browser Extension (MV3)**: UI for fill, TOTP, status; talks to nmhost; blocks fill when far/offline/locked; shows proximity/vault status.

Data paths (today):
- Extension → nmhost → UDS → Agent.
- iOS ↔ TLS terminator ↔ UDS ↔ Agent.

## Key Behaviors (As Implemented)
- **Proximity** ✅ **BLE-BASED (Implemented 2026-02-01)**
  - **Primary proximity source:** BLE iBeacon advertisements from iOS with HMAC-validated tokens
  - iOS advertises continuously in background using `CLBeaconRegion` (survives screen lock/backgrounding)
  - macOS agent scans for iBeacon (Apple company ID 0x004C), validates 4-byte HMAC tokens
  - Token protocol: `HMAC-SHA256(k_ble, "ARM/BLE/v1" || bucket_be_u64).prefix(4)` where bucket = floor(now/30s)
  - Validation: ±1 bucket tolerance (90 second window total)
  - **Status:** `ble.token.valid` events confirmed every 1-2 seconds at RSSI -45dBm
  - **TODO (5 min):** Wire `ble.token.valid` → `Proximity::note_ble_seen()` to drive state machine
  - **Legacy TLS heartbeats:** Still present but will become secondary/diagnostic only
- **Vault/Session**
  - Proximity, session TTL, and vault lock are separate gates; UIs may show composite states like “Near + Unlocked”.
  - `cred.list/get` hard-fail when proximity is far/offline; vault locks in that state.
  - Face ID push (`auth.nudge`) is sent on session/proximity failures when TLS is registered.
  - Session TTL is configurable (e.g., ARM_AUTH_TTL_SECS); proximity is a separate gate.
  - TLS caches `vault.open` and replays it after `auth.ok` so re-pairing is not needed.
- **Web Extension**
  - Popup: shows proximity state + heartbeat age; shows note when away/offline; shows vault lock state.
  - Badge: blank/green when OK; red “L” when blocked/locked/far/offline.
  - Client-side block: refuses fill when far/offline or vault locked.
  - Status polling every 5s keeps the popup fresh; softer logging for proximity_far.

## Commands (Runbook)
- Agent:
  - `cd /Users/zenmonkey/WORK/ArmadilloProject`
  - `ARM_PUSH_ENABLED=1 ARM_AUTH_POLICY=ttl ARM_AUTH_TTL_SECS=3600 cargo run --bin agent-macos`
- TLS build/run:
  - Build:
    ```
    xcodebuild \
      -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj \
      -scheme ArmadilloTLS \
      -configuration Debug \
      -derivedDataPath apps/tls-terminator-macos/build \
      build
    ```
  - Run:
    ```
    ARM_WEBEXT_DEV_ID=opojlcnklbhebgdnafldoinkmedgpokk \
    ARM_FEATURE_PIN_UI=1 \
    ARM_LOG_FILE=1 \
    ARM_LOG_LEVEL=info \
    ARM_TLS_KICK_ON_REVOKE=1 \
    apps/tls-terminator-macos/build/Build/Products/Debug/ArmadilloTLS.app/Contents/MacOS/ArmadilloTLS
    ```
- Status check (agent):
  ```
  python3 <<'PY'
  import socket,json,struct,os
  msg={"type":"prox.status","corr_id":"p"};d=json.dumps(msg).encode();f=struct.pack(">I",len(d))+d
  s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.connect(os.path.expanduser("~/.armadillo/a.sock"))
  s.sendall(f);n=struct.unpack(">I",s.recv(4))[0];print(s.recv(n).decode());s.close()
  PY
  ```

## Current Expected Flow
1) Pair + Face ID → proximity `near_unlocked`, vault `unlocked`.
2) Normal fills succeed while near and session valid.
3) If phone/iOS goes silent: within ~10s TLS stops heartbeats, sends `tls.down`; agent flips to far/offline and locks vault; fills blocked; extension shows far/offline + locked.
4) When phone/iOS returns and sends traffic: heartbeats resume; proximity returns to `near_unlocked`; vault can be unlocked again via Face ID.

## Known Risks / Gaps
- iOS installed build (no debugger) is subject to background limits; BLE/background modes/state restoration likely needed for robust proximity when app is backgrounded/locked.
- If TLS isn’t running/registered, `auth.nudge` can’t be pushed; Face ID prompt won’t appear.
- Per-site lock intent not implemented (vault status is global).
- Identity lifecycle (pinning/rotation) must remain stable; avoid contradicting docs.
- Today “fresh traffic” is used as a proxy for link health; long-term, add explicit iOS heartbeats to decouple idle from offline.

## Recent Key Files
- **BLE Implementation (NEW):**
  - `apps/app-ios/.../Features/BLE/BLEAdvertiser.swift` — iBeacon advertiser, HMAC token generation
  - `apps/app-ios/.../Session/SessionKeyDerivation.swift` — k_ble derivation (ECDH + HKDF)
  - `apps/agent-macos/src/ble_scanner.rs` — iBeacon scanner, token validation
  - `apps/agent-macos/src/wrap.rs` — k_ble derivation (Rust side)
  - `.gemini/.../BLE_IMPLEMENTATION_COMPLETE.md` — full technical documentation
- **Proximity & Session:**
  - `apps/agent-macos/src/proximity.rs` — state machine with `note_ble_seen()` ready
  - `apps/tls-terminator-macos/ArmadilloTLS/TLSServer.swift` — legacy heartbeats
- **Extension:**
  - `packages/webext/public/background.js`, `popup.html/js` — status UI, vault gating§
