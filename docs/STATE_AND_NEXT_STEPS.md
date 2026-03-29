# Armadillo – Current State and Next Steps

This file captures the precise state of the system, how to run and verify it, and the recommended next steps. Share this file in a new chat to transfer context.

## High‑level status

- Transport (stable & observable)
  - mTLS 1.3, server pinning (self‑signed), client certs.
  - Fixed ports: 8444 (enroll, no client auth), 8443 (main mTLS, client auth required).
  - Bonjour advertises `_armadillo._tcp` on 8443 with `fp_full` in TXT.
  - Auto‑reconnect: backoff (0.5/1/2/4s) → background Bonjour rediscovery (no auto‑QR).
  - Session resumption: OS‑managed tickets; logs `mtls.established` with `elapsed_ms` and `resumed` heuristic.
  - Structured logs (iOS/TLS/Rust), `corr_id` propagation end‑to‑end, NDJSON writer on TLS.
- Identity lifecycle
  - macOS TLS server identity persisted (Keychain + `~/.armadillo/server_identity.der`), self‑heals stale/ACL issues.
  - iOS client identity enrolls to `https://<host>:8444/enroll` with pinning; auto‑renews when <10% lifetime remains.
- Vault MVP (integrated)
  - UDS JSON API: `vault.open|read|write|lock|status` framed through TLS→UDS.
  - AES‑GCM sealed file `~/.armadillo/vault.bin`, header: `ARMV` magic (4), version (1), nonce (12), ciphertext+tag.
  - In‑memory unlocked map, 5‑min idle timeout, zeroize on lock.
  - iOS opens vault on connect, includes “Vault Test” (write/read echo).

---

## Code map (files that matter)

### iOS (Swift)
- Transport
  - `apps/app-ios/ArmadilloMobile/ArmadilloMobile/Features/Transport/TLSClient.swift`
    - mTLS connect, ALPN `armadillo/1.0`, server pinning.
    - Injects `corr_id` on all outbound frames; JSON send/recv logs when enabled.
    - Type‑based waiter system for replies; `mtls.established` logs with elapsed/resumed.
- Pairing/view model
  - `apps/app-ios/ArmadilloMobile/ArmadilloMobile/Features/Pairing/PairingViewModel.swift`
    - QR flow (discover → enroll 8444 → connect 8443); auto‑connect with backoff + Bonjour.
    - No auto‑QR during reconnect; periodic Bonjour continues.
    - Sends `pairing.complete`, waits `pairing.ack`.
    - Vault: sends `vault.open` then sanity `vault.write/read`; periodic `vault.status` (60s); `vaultTestEcho()` for UI.
- Settings & toggles
  - `apps/app-ios/ArmadilloMobile/ArmadilloMobile/Settings.bundle/Root.plist`: `ARM_JSON_LOG`, `ARM_LOG_REDACT`.
  - `apps/app-ios/ArmadilloMobile/ArmadilloMobile/Core/Env.swift`: reads Settings first, Info.plist fallback.
  - `apps/app-ios/ArmadilloMobile/ArmadilloMobile/ContentView.swift`: adds “Vault Test” button.
- Identity
  - `apps/app-ios/ArmadilloMobile/ArmadilloMobile/Session/SimpleClientIdentity.swift`: enroll & auto‑renew.

### macOS TLS (Swift)
- TLS server & enroll
  - `apps/tls-terminator-macos/ArmadilloTLS/TLSServer.swift`: listener on 8443, client auth, JSON logs, NDJSON writer at `~/Library/Logs/ArmadilloTLS/events.ndjson` when `ARM_LOG_FILE=1`.
  - `apps/tls-terminator-macos/ArmadilloTLS/EnrollmentServer.swift`: `POST /enroll` (8444) → issues client cert.
- Identity & Bonjour
  - `apps/tls-terminator-macos/ArmadilloTLS/CertificateManager.swift`: persistent server identity, diagnostics.
  - `apps/tls-terminator-macos/ArmadilloTLS/BonjourService.swift`: advertises `_armadillo._tcp` on 8443 with `fp_full`.
- UDS bridge
  - `apps/tls-terminator-macos/ArmadilloTLS/UnixSocketBridge.swift`: forwards frames to Rust via `~/.armadillo/a.sock`.

### Rust agent (UDS server + vault)
- `apps/agent-macos/src/main.rs`: tracing init (`ARMADILLO_LOG[_FORMAT]`), starts UDS, initializes Vault at `~/.armadillo/vault.bin`.
- `apps/agent-macos/src/bridge.rs`: routes `pairing.*`; handles `vault.*` (open/write/read/lock/status) with base64 payloads.
- `apps/agent-macos/src/vault.rs`: AES‑GCM sealed store, idle lock, re‑init empty vault when file exists but cannot be decrypted.

---

## How to run & verify

### 1) Rust agent
```bash
cd apps/agent-macos
ARMADILLO_LOG=info ARMADILLO_LOG_FORMAT=json cargo run
```
- UDS at `~/.armadillo/a.sock` (default) and JSON logs to stdout.

### 2) macOS TLS terminator
```bash
xcodebuild -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj \
  -scheme ArmadilloTLS -configuration Debug \
  -derivedDataPath build -quiet build && \
ARMADILLO_LOG_FORMAT=json ARM_LOG_FILE=1 NSUnbufferedIO=YES \
  build/Build/Products/Debug/ArmadilloTLS.app/Contents/MacOS/ArmadilloTLS
```
- Expect: startup, `TLS server listening on port 8443`, `logfile` JSON with NDJSON path, then recv/send JSON lines.
- Persisted logs:
```bash
tail -F ~/Library/Logs/ArmadilloTLS/events.ndjson
```

### 3) iOS app
- Open `apps/app-ios/ArmadilloMobile/ArmadilloMobile.xcodeproj`, run on device.
- First run: scan QR; subsequent runs auto‑connect to 8443.
- Settings → ArmadilloMobile: toggle JSON/Redact as needed.

Verification checklist
- iOS console: `TLS state = ✅ ready`, `Ping test successful`.
- TLS stdout/NDJSON: `mtls.established` with `elapsed_ms` and `resumed`.
- Vault round‑trip:
  - TLS logs: `vault.open → vault.ack → vault.write → vault.ack → vault.read → vault.value`.
  - iOS “Vault Test” shows: `Vault test OK (sample_test=hello)`.

---

## Env flags (quick reference)
- TLS: `ARMADILLO_LOG_FORMAT=json`, `ARM_LOG_FILE=1`, `ARMADILLO_SOCKET_PATH`.
- Agent: `ARMADILLO_LOG`, `ARMADILLO_LOG_FORMAT=json`.
- iOS Settings: `ARM_JSON_LOG`, `ARM_LOG_REDACT`.

---

## Known behaviors & tips
- Resumption is OS‑managed; we mark `resumed=true` if handshake < ~80 ms.
- Reconnect never auto‑opens QR; if no Bonjour candidates, it keeps rediscovering in background and shows “No agent nearby”.
- TLS identity self‑heals stale Keychain/DER; logs clearly when re‑creating.
- Vault open: if the sealed file cannot be decrypted (fresh system), the agent re‑initializes an empty vault and persists it.

### Hard reset TLS identity (if signing/ACL changes)
```bash
rm -f ~/.armadillo/server_identity.der
security delete-certificate -c "Armadillo TLS Dev Identity" ~/Library/Keychains/login.keychain-db || true
cat <<'SWIFT' | swift
import Foundation, Security
let q:[String:Any] = [
  kSecClass as String: kSecClassKey,
  kSecAttrApplicationTag as String: "com.armadillo.tls.identity.dev".data(using: .utf8)!
]
print(SecItemDelete(q as CFDictionary))
SWIFT
```

---

## Next steps (prioritized)
1) Key hierarchy hardening (wrap `K_vault` with `k_session`)
- Derive `k_session` via ECDH during Face ID handshake.
- Wrap/unwrap `K_vault` (AES‑GCM) at open/lock; store only wrapped form.
- Telemetry: `wrapped=true` and unwrap failures.

2) Recovery design
- Define recovery material (printed phrase or secondary device) and rekey flow.
- Implement `vault.rekey(start|commit)` guarded by presence & auth.

3) Observability polish
- (Optional) periodic `tls_resume_ratio` metric; surface vault status (`unsealed`, `entries`, `idle_ms`).

4) Presence / Browser bridge
- BLE presence beacons (rotating signed hints; not an auth factor).
- WebExtension host → `vault.read` gated by TLS session.

---

Last updated: 2025‑11‑01

