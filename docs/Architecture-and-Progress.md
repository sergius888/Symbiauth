## Armadillo – Architecture, Features, and Operational Guide (as of 2025-11-13)

This document captures the current system architecture and all features implemented across the macOS Agent (Rust), macOS TLS Terminator (Swift), and the iOS app (Swift). It is written to help a new contributor understand what exists, how it works, how to run it, and how to verify it.


## High-level components

- macOS Agent (Rust): `apps/agent-macos`
  - Local vault encryption and storage
  - Pairing state and long-term wrap key management
  - Recovery skeleton: BIP-39 phrase, rekey start/commit/abort
  - UDS IPC server at `~/.armadillo/a.sock`
- macOS TLS Terminator (Swift): `apps/tls-terminator-macos/ArmadilloTLS`
  - TLS 1.3 server with client pinning and menu bar UI
  - Enrollment server (`:8444`) issuing client certs
  - BLE presence scanning (optional)
  - Structured NDJSON logging to `~/Library/Logs/ArmadilloTLS/events.ndjson`
- iOS App (Swift): `apps/app-ios/ArmadilloMobile`
  - Derives session keys (ECDH) and advertises rotating BLE UUID (optional)
  - Dev toggles for recovery phrase, presence toggle, settings


## Cryptographic model

- K_vault (32B): Random local storage key for the vault contents (AES-GCM).
- K_wrap (32B): Stable “wrap key” derived from long-term ECDH between iPhone (iOS wrap keypair) and Mac (agent wrap keypair) via HKDF.
- k_session (32B): Ephemeral session key for in-memory gating; derived via ECDH + HKDF per session (iOS ephemeral × Mac long-term).
- AES-GCM: Used for authenticated encryption of the vault (v3 format).


## Vault formats and migration

- v2: K_vault wrapped using session key (k_session).
- v3 (current): K_vault wrapped using stable K_wrap (deterministic, long-lived).
- Migration: On open, if `ARM_VAULT_MIGRATE != 0` and K_wrap is available, seamless unwrap under v2 and re-wrap under v3. Telemetry emitted.


## macOS Agent (Rust)

Files of interest:
- `src/vault.rs`: vault load/store, v2/v3 support, secure perms, rekey, telemetry.
- `src/wrap.rs`: P-256 key generation, ECDH, HKDF derivations for K_wrap and K_ble.
- `src/pairing.rs`: pairing sessions, persistence of iOS wrap pubkey (`ios_wrap_pub.sec1`), paired-device filesystem.
- `src/bridge.rs`: UDS server; routes `vault.*`, `recovery.*`, `ble.k_ble`, `trust.*` messages.
- `src/recovery.rs`: BIP-39 phrase generation (12 words), `PendingRekey` struct.

Key behaviors:
- Wrap key: Agent generates a persistent P-256 private key at `~/.armadillo/mac_wrap_sk.bin` (0600). iOS public wrap key (SEC1) is stored per device fingerprint at `~/.armadillo/paired_devices/<fp>/ios_wrap_pub.sec1` (0600).
- Opening vault: `vault.open` accepts `k_session_b64`, tries unwrap (prefers v3 with K_wrap), and may migrate from v2→v3 when K_wrap exists and migration is enabled.
- Rekey: `vault.rekey.start` (countdown + token), `vault.rekey.commit` (in-place rekey K_vault), `vault.rekey.abort`. Telemetry for started/aborted/committed.
- Secure permissions: `~/.armadillo` set to 0700; files to 0600 where applicable.
- Lock-on-sleep: `host.sleep` message locks the vault in memory.

Messages handled (subset):
- `vault.open|read|write|lock|status`
- `recovery.phrase.generate|vault.rekey.start|commit|abort`
- `ble.k_ble` → derives K_ble for BLE presence
- `trust.client.revoke` → remove paired device data (filesystem) and ack
- `trust.server.reset` → clear all paired device data and ack

Telemetry (agent):
- `vault.unwrapped` / `VAULT_UNWRAP_FAILED`
- `vault.migrated`, `vault.persisted`
- `rekey.started|aborted|committed`
- `lock.sleep`


## TLS Terminator (macOS, Swift)

Files of interest:
- `TLSServer.swift`: main TLS server (8443), client pinning, BLE scanner integration, NDJSON writer, allowed clients store, provisioning state, connection tracking, kick-on-revoke.
- `EnrollmentServer.swift`: minimal HTTP server (8444) issuing client certs from CSR; appends to `allowed_clients.json` if accepted.
- `CertificateManager.swift`: create/rotate server identity (self-signed), fingerprinting, Keychain storage.
- `AppDelegate.swift`: menu bar UI, QR code display, UDS bridge to agent, pinning lifecycle UI (flag-gated).
- `BonjourService.swift`: advertises service `_armadillo._tcp` with TXT (includes fingerprint).

Pinning lifecycle:
- `~/.armadillo/allowed_clients.json` (0600): JSON array of allowed client fingerprints (e.g., `"sha256:<hex>"`).
- TOFU hardening (Provisioning-only):
  - `~/.armadillo/pin_state.json`: `{ "provisioning": true|false, "set_at" | "first_enrolled_at": "<iso>" }`
  - On Reset Server Identity: `provisioning:true` (emits `pin.provisioning.enabled`).
  - On first successful enroll or first trust: flips to `provisioning:false` (emits `pin.provisioning.disabled`).
  - Gate: when the allow-list is empty AND `provisioning:false`, enroll and first trust are rejected (`TOFU_DISABLED`).
- Kick-on-revoke (optional): when enabled, revoking a device immediately cancels active TLS connections and locks the vault in the agent.

Menu bar UI (flag-gated: `ARM_FEATURE_PIN_UI=1`):
- Fingerprint (suffix), port, Show Pairing QR Code
- Paired Devices → `<suffix> · Revoke`
- Reset Server Identity…
- The Paired Devices submenu refreshes live on enroll/trust/revoke/reset.

Enrollment flow (8444):
1) iOS sends CSR (P-256) to `http://<mac>:8444/enroll`.
2) Server issues a client cert signed by current identity and returns DER.
3) On success, TLS app appends client fingerprint to `allowed_clients.json` (if provisioning allows it).

TLS handling:
- TLS 1.3, server identity from `CertificateManager` (Keychain + disk DER).
- Client cert verification:
  - If `ARM_TLS_PINNING=0`: disabled (dev), accept all.
  - Else: if allow-list empty AND `provisioning:true` → accept (first trust), add fingerprint and flip provisioning false.
  - Else: verify presented fingerprint ∈ allow-list; reject otherwise.

BLE scanning (optional):
- Enable via `ARM_FEATURE_BLE=1`.
- On start, fetches `K_ble` from agent for the first allowed client.
- Scans for rotating Service UUIDs derived from shared secret; emits `ble.presence` enter/keepalive/exit debounced by TTL; emits rolling presence ratio metric.

Telemetry (TLS NDJSON examples):
```json
{"event":"mtls.established","elapsed_ms":37,"resumed":true,"role":"tls"}
{"event":"pin.provisioning.enabled","role":"tls"}
{"event":"pin.provisioning.disabled","role":"tls"}
{"event":"pin.revoke.applied","fp":"aa674eb159d9","role":"tls"}
{"event":"pin.revoke.kicked","kicked":true,"role":"tls"}
{"event":"connections.kicked","reason":"revoke","role":"tls"}
{"event":"vault.lock","reason":"revoke","role":"tls"}
{"event":"pin.reset.requested","role":"tls"}
{"event":"pin.reset.applied","new_fp":"4744697fb2f5e671","role":"tls"}
{"event":"ble.scan.disabled","reason":"no_allowed_clients"}
{"event":"vault.status","unlocked":true,"entries":1,"idle_ms":12345,"role":"tls"}
```


## iOS App

Files of interest:
- `Session/WrapKeyManager.swift`: P-256 KeyAgreement private key in Keychain; public SEC1 base64.
- `Session/SessionKeyDerivation.swift`: ECDH + HKDF to derive session key.
- `Features/Pairing/PairingViewModel.swift`: pairing flow, auto-connect, dev toggles, recovery UI, BLE advertiser control.
- `Features/BLE/BLEAdvertiser.swift`: rotating Service UUID advertiser using K_ble (when enabled).
- `Features/Settings/SettingsView.swift`: toggles for dev features and BLE presence.

Notable behaviors:
- Auto-pairs and stores server fingerprint; performs mutual TLS.
- Dev options: generate recovery phrase, start/commit/abort rekey, copy phrase with 60s expiry to clipboard.
- BLE advertiser toggled via settings; logs state; uses rotating UUID seeded by K_ble.


## Message contracts (UDS → Agent)

Examples (length-prefixed JSON over UDS):

- Vault
```json
{"type":"vault.open","k_session_b64":"<base64>","device_fp":"sha256:...","corr_id":"..."} 
{"type":"vault.read","key":"sample_test","corr_id":"..."}
{"type":"vault.write","key":"sample_test","value_b64":"aGVsbG8=","corr_id":"..."}
{"type":"vault.lock","corr_id":"..."}
{"type":"vault.status","corr_id":"..."}
```

- Recovery
```json
{"type":"recovery.phrase.generate"}
{"type":"vault.rekey.start","reason":"manual","countdown_secs":30,"corr_id":"..."}
{"type":"vault.rekey.commit","token":"<uuid>","corr_id":"..."}
{"type":"vault.rekey.abort","token":"<uuid>","corr_id":"..."}
```

- BLE
```json
{"type":"ble.k_ble","device_fp":"sha256:..."} 
```

- Trust lifecycle
```json
{"type":"trust.client.revoke","device_fp":"sha256:..."}
{"type":"trust.server.reset"}
```


## Operational paths

Run the Agent (Rust):
```bash
cd /Users/zenmonkey/WORK/ArmadilloProject/apps/agent-macos
cargo run
```

Build the TLS app once:
```bash
cd /Users/zenmonkey/WORK/ArmadilloProject
xcodebuild \
  -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj \
  -scheme ArmadilloTLS -configuration Debug \
  -derivedDataPath apps/tls-terminator-macos/build \
  -quiet build
```

Run TLS with env vars (recommended from Terminal):
```bash
ARM_FEATURE_PIN_UI=1 ARM_LOG_FILE=1 ARM_LOG_LEVEL=info ARM_LOG_FORMAT=json \
ARM_TLS_KICK_ON_REVOKE=1 \
# Optional BLE:
# ARM_FEATURE_BLE=1 ARM_BLE_RSSI_MIN=-65 ARM_BLE_PRESENCE_TTL=8 \
/Users/zenmonkey/WORK/ArmadilloProject/apps/tls-terminator-macos/build/Build/Products/Debug/ArmadilloTLS.app/Contents/MacOS/ArmadilloTLS
```

Tail NDJSON logs:
```bash
tail -F ~/Library/Logs/ArmadilloTLS/events.ndjson
```

Environment variables:
- `ARM_FEATURE_PIN_UI=1`: enable pinning menu (Paired Devices, Reset).
- `ARM_LOG_FILE=1`: enable NDJSON file logging.
- `ARM_LOG_FORMAT=json|text`: log format (json recommended).
- `ARM_LOG_LEVEL=error|warn|info|debug` (default info).
- `ARM_TLS_KICK_ON_REVOKE=1`: drop active connections on revoke + lock vault.
- `ARM_TLS_PINNING=0`: disable client pinning (dev only).
- `ARM_FEATURE_BLE=1`: enable BLE scanner; also requires K_ble.
- `ARM_BLE_RSSI_MIN`, `ARM_BLE_PRESENCE_TTL`: BLE debounce tuning.

Filesystem layout:
- `~/.armadillo/a.sock` (0600): UDS for Agent.
- `~/.armadillo/vault.bin` (0600): encrypted vault.
- `~/.armadillo/mac_wrap_sk.bin` (0600): agent wrap private key (P-256).
- `~/.armadillo/paired_devices/<device_fp>/ios_wrap_pub.sec1` (0600): iOS wrap pubkey.
- `~/.armadillo/allowed_clients.json` (0600): TLS allow-list of fingerprints.
- `~/.armadillo/pin_state.json` (0600): provisioning state for TOFU hardening.
- `~/Library/Logs/ArmadilloTLS/events.ndjson`: NDJSON logs.


## Flows

Pairing / First Trust (Provisioning mode):
1) Admin resets server identity → `pin.provisioning.enabled` and empty allow-list.
2) iOS scans QR and connects; TLS accepts first trust or `/enroll` success.
3) TLS appends client fp to allow-list, disables provisioning → `pin.provisioning.disabled`.

Steady state:
- Client TLS handshakes are accepted only if fingerprint ∈ allow-list.
- Vault open persists in memory if session is live; lock on sleep or on manual lock.

Revoke (with kick):
1) Admin menu → Revoke `<suffix>` → TLS removes fp from allow-list.
2) If `ARM_TLS_KICK_ON_REVOKE=1`, TLS cancels active connections and locks vault (`vault.lock` via agent).
3) Future handshakes from that device are rejected.

Reset server identity:
1) Menu → Reset: new identity/fingerprint; allow-list cleared; provisioning=true; BLE disabled (`ble.scan.disabled`).
2) All clients must re-pair/enroll.

Recovery:
- Generate BIP-39 (12 words) in dev mode; not persisted; clipboard copy guarded with 60s expiry.
- Rekey K_vault: start (countdown + token), commit (re-encrypt), abort.

BLE presence (optional):
- iOS advertises rotating Service UUID derived from K_ble; macOS scans and logs presence transitions and metrics; log level gating reduces noise.


## Acceptance test checklist

Pinning lifecycle:
- Reset → NDJSON shows `pin.provisioning.enabled`.
- First successful enroll or trust → `pin.provisioning.disabled`.
- Revoke while connected (with kick on): TLS logs `pin.revoke.applied`, `connections.kicked`, `pin.revoke.kicked`, `vault.lock`; device cannot reconnect.
- Revoke the last device: enroll attempts fail with `TOFU_DISABLED` until next reset.

Vault:
- v2→v3 migration under K_wrap occurs when `ARM_VAULT_MIGRATE` enabled; `vault.migrated` and `vault.unwrapped` telemetry.
- File perms: `~/.armadillo` 0700; sensitive files 0600.

Recovery:
- Phrase generation works (12 English words); not persisted; copy expires after 60s.
- Rekey start/commit/abort telemetry emitted; vault content remains accessible after rekey.

BLE (if enabled):
- `ble.scan.enabled` only when K_ble available and allow-list non-empty.
- Presence emits enter/keepalive/exit and rolling ratio.


## Known constraints and toggles

- TOFU is allowed only immediately after Reset (provisioning=true). It is disabled automatically on first trust; revoking the last device does not re-enable TOFU.
- `ARM_TLS_PINNING=0` should only be used for dev convenience; never in test/production.
- Kick-on-revoke is opt-in (`ARM_TLS_KICK_ON_REVOKE=1`).
- BLE requires a derived `K_ble` for at least one allowed device; scanner stays off without it.


## Next candidates (not yet implemented)

- iOS UX for TOFU_DISABLED and revoke push: friendly error and auto-stop BLE for that Mac.
- “Enable provisioning (10 min)” dev-only toggle for admin.
- BLE Phase‑2: signed foreground beacon to raise presence assurance against relays.
- Browser extension MVP via Native Messaging (Chrome/Firefox) gated by proximity + session.


## Appendix: Quick commands

Build TLS:
```bash
xcodebuild -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj \
  -scheme ArmadilloTLS -configuration Debug \
  -derivedDataPath apps/tls-terminator-macos/build -quiet build
```

Run TLS:
```bash
ARM_FEATURE_PIN_UI=1 ARM_LOG_FILE=1 ARM_LOG_LEVEL=info \
ARM_TLS_KICK_ON_REVOKE=1 \
/Users/zenmonkey/WORK/ArmadilloProject/apps/tls-terminator-macos/build/Build/Products/Debug/ArmadilloTLS.app/Contents/MacOS/ArmadilloTLS
```

Tail logs:
```bash
tail -F ~/Library/Logs/ArmadilloTLS/events.ndjson
```

Run Agent:
```bash
cd apps/agent-macos && cargo run
```


