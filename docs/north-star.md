Awesome—here’s a **clean, revised single doc** with your requested edits baked in. You can drop it in as `docs/north-star.md` (it supersedes the previous version).

---

# Armadillo (working name) — North Star, Proximity Model & MVP Plan

*Last updated: 2025-11-15 (rev B)*

This file is the source of truth for what we’re building, why, and how it behaves in v1/v2. It combines the **product north star**, the **proximity & transport model**, **MVP scope for the browser extension**, and the **OS auto-lock decision** so we don’t drift.

---

## 0) Naming & branding

* Internal code and bundle names may still say **Armadillo**.
* Final branding (e.g., “DreiGlaser”) is **not locked**.
* Keep product strings behind config/consts; do a final rebrand pass before public beta.

---

## 1) North Star — what we’re building

**Local-first, proximity-trusted security for desktops.**
If you’re not physically there (phone nearby), your computer **cannot** perform sensitive actions. When you are, it’s fast and frictionless.

**Outcomes**

* Gate secrets (passwords/passkeys/SSH/GPG) and sensitive actions (autofill, code pushes, payments) by **proximity + mTLS + vault**.
* Enforce presence and biometric approval **without any cloud dependency**.

**Non-negotiable principles**

* Local-first (no cloud hot path).
* Mutual TLS with pinning (phone ↔ Mac).
* Proximity is a **hint**, not the key (BLE gates attempts; mTLS + vault authorize).
* Secrets never leave devices unencrypted (Vault v3 + stable wrap).
* Revocation/reset must be first-class (TOFU hardened; optional kick-on-revoke).
* Observability without leaking secrets (redaction + NDJSON).

---

## 2) Current foundation (already implemented)

* **Transport & trust**: QR/CSR enrollment, pinned **mTLS**, **SAS** (Short Authentication String) — planned/optional, not required for v1 — for human-verifiable pairing, auto-reconnect/backoff.
* **Presence**: BLE Phase-1 (rotating beacon), RSSI threshold, presence TTL, metrics.
* **Vault**: v3 stable wrap (long-term ECDH), atomic writes, perms (0700/0600), sleep-lock, recovery skeleton (dev-only BIP-39).
* **Lifecycle**: TOFU hardened (provisioning-only), **kick-on-revoke** flag, server identity reset, allow-list persisted.
* **Observability**: NDJSON logs to `~/Library/Logs/ArmadilloTLS/events.ndjson`, redaction, corr_id propagation, presence ratio, TLS resume heuristic.
* **UX/dev toggles (iOS)**: Settings bundle (dev mode, JSON logs, redact, BLE toggle, disable auto-connect, forget endpoint).

Key paths (macOS):

```
~/.armadillo/vault.bin                 # Vault (ARMV 03)
~/.armadillo/server_identity.der       # Server cert (pinned by iOS)
~/.armadillo/allowed_clients.json      # Allow-list of client certs (pinned)
~/.armadillo/pin_state.json            # provisioning mode (TOFU) flag
~/.armadillo/paired_devices/<fp>/ios_wrap_pub.sec1  # iOS wrap pub (SEC1)
~/Library/Logs/ArmadilloTLS/events.ndjson           # NDJSON logs
```

---

## 3) Proximity & transport — finalized model

**Sensitive actions require:**
`mTLS (session up & pinned)` **AND** `BLE presence (valid & fresh)` **AND** `Vault unlocked (session active)` **AND** `Origin/policy OK`.

### BLE presence (proves “physically here”)

* iOS emits a **rotating beacon** derived from shared secret `K_ble` (pairing ECDH + HKDF).
* macOS validates rotation + freshness + **RSSI ≥ threshold**.
* No secrets over BLE; **gate only**.
* **Reminder:** BLE is **flag-gated** (can be disabled for debugging) and is a *hint*, not authorization.

### Pinned mTLS (authenticated pipe)

* iOS ↔ macOS over **standard IP** (Wi-Fi/Ethernet), discovered with **Bonjour** (fallback cached IP:port from QR).
* TLS 1.3 **mutual auth** with **pinning** and allow-list of client certs.

### Vault (explicit consent)

* Vault v3 sealed by a **stable wrap key** (long-term ECDH from pairing).
* Unlock is ephemeral (session key, Face ID gated).
* Auto-lock on sleep or presence loss.

### Why not AWDL (v1)

* Apple-only, harder to support at scale, opaque to enterprise networking, and battery heavier for always-available channels.
* **Primary everywhere** is IP mTLS; BLE is presence only.
* **Future fallback (Phase-3)**: add optional P2P carriers per platform (AWDL/MPC on Apple, Wi-Fi Direct on Windows, Wi-Fi P2P on Linux) carrying the same mTLS.

### VPN stance & detection

* Split-tunnel / “Allow local LAN” → **works** (presence + mTLS).
* Full-tunnel blocking local peers → presence works but **no mTLS** → **deny** (fail closed).
* Emit an explicit NDJSON hint when we suspect VPN is blocking local peers:

  ```json
  {"event":"mtls.connect.fail","reason":"connect_timeout","vpn.local_blocked":true,"iface":"utun2"}
  ```
* Workarounds now: enable local-LAN in VPN client or join iPhone Personal Hotspot.
* Planned: P2P fallback + user hinting.

**Quick matrix**

| BLE | IP path | VPN policy               | Result                                 |
| --- | ------- | ------------------------ | -------------------------------------- |
| ✔   | ✔       | Split-tunnel / LAN OK    | **Allowed** (presence + mTLS + vault). |
| ✔   | ✔       | mDNS blocked only        | **Allowed** (uses cached IP fallback). |
| ✔   | ✖       | Full-tunnel blocks peers | **Denied** (no mTLS pipe).             |
| ✖   | ✔       | Any                      | **Denied** (no proximity).             |
| ✔   | Hotspot | N/A                      | **Allowed** (same link IP + mTLS).     |

### Security properties (v1)

* Anti-spoof BLE: rotating derivation from `K_ble`; RSSI + freshness window.
* Anti-relay (BLE): Phase-1 raises bar; **Phase-2** plan adds signed foreground GATT payload per epoch (anti-relay), see `/docs/ble_phase2.md`.
* mTLS MITM-resistance: mutual TLS + pinning + allow-list.
* Lifecycle: TOFU only **immediately after** reset; revoke doesn’t re-enable TOFU; optional **kick-on-revoke** drops live session.
* Fail-closed defaults: if any gate fails → no secret leaves agent; extension sees reason codes only.

---

## 4) Logging env vars — standardized

Use these **canonical names in docs and code** (support legacy aliases where needed):

* `ARM_LOG_FORMAT=json|text`
* `ARM_LOG_LEVEL=error|warn|info|debug|trace`
* `ARM_LOG_FILE=0|1` (when `1`, write NDJSON to `~/Library/Logs/ArmadilloTLS/events.ndjson`)

**Legacy alias (still accepted):** `ARMADILLO_LOG_FORMAT` → treated as `ARM_LOG_FORMAT`.

**Example run (quiet, file-based logs + BLE):**

```bash
ARM_LOG_FORMAT=json ARM_LOG_FILE=1 ARM_LOG_LEVEL=info \
ARM_FEATURE_BLE=1 ARM_BLE_RSSI_MIN=-65 ARM_BLE_PRESENCE_TTL=8 \
/path/to/ArmadilloTLS.app/Contents/MacOS/ArmadilloTLS
```

**Tail logs:**

```bash
tail -F ~/Library/Logs/ArmadilloTLS/events.ndjson | jq .
```

---

## 5) MVP objective — Browser Extension “aha”

**User story**
Sit down → phone near → mTLS connects → vault session alive → click **“Fill with Armadillo”** in the browser → credentials autofill **only** on the correct origin. If any gate fails, nothing leaks and the user sees a precise reason.

### Protocol compatibility (explicit handshake)

**Handshake (extension → native host)**

```json
{ "type":"nm.hello", "proto":"armadillo.webext", "version":1, "min_compatible":1 }
```

**Ack (native host → extension)**

```json
{
  "type":"nm.hello.ack",
  "proto":"armadillo.webext",
  "version":1,
  "min_compatible":1,
  "channel_token":"<opaque>",
  "schema_version":1
}
```

* If `version < min_compatible` on either side → return `{"type":"error","code":"PROTO_INCOMPATIBLE","hint":"update extension/app"}`.
* **Schema**: see `/docs/message_schema.md` (`schema_version=1`); new fields must be optional and ignored safely.

### Scope

**Extension (MV3)**

* `content.ts`: detect login forms (minimal iframe/shadow-DOM support), inject **Fill with Armadillo** button.
* `background.ts`: establish **Native Messaging** channel, handshake, forward `cred.request` / `vault.status`.
* Permission: `"nativeMessaging"`.
* Error UI: concise infobar (Phone required / Vault locked / Not found / Untrusted site). **Never** log secrets.

**Native Messaging host (Rust)**

* Single stdio JSON bridge (one process, multiple browser ports).
* Handshake: verify **Extension ID**, issue per-session **channel_token**.
* Forward to agent over UDS; enforce **timeouts & backpressure** (bounded queue per port).
* Install/uninstall manifest **programmatically** from the macOS app bundle (user scope).

**Agent handlers (Rust)**

* `webext.vault.status`, `webext.cred.request`.
* **Gate order**: `session` → `presence` (if BLE flag on) → `vault unlocked` → **origin/eTLD+1 match**.
* Keys by `cred:<etld1>`; redact secrets in logs.
* Concurrency cap (e.g., 16 in-flight per connection); return `BUSY_RETRY` quickly if saturated.

**Packaging**

* macOS `.app` bundles TLS terminator + agent + native host; signed & notarized.
* Autostart via `SMAppService` (Login Item).
* Manifest install on first run; clean uninstall path.

**Acceptance tests (must pass)**

* Happy path: p95 round-trip < ~60 ms after TLS ready; fills correct form fields.
* Gate failures:

  * No mTLS → “Phone required.”
  * No presence → “Phone required.”
  * Vault locked → “Vault locked.”
  * Origin mismatch → “No credential found.”
* Revocation (kick on): session drops immediately; reconnect fails until re-enrolled.
* Reset server identity: pairing required again; failure states are clear.
* Kill/restart any single process (extension/host/TLS/agent): flow **recovers** without re-pairing.
* **Operational checks**:

  * iOS logs show **no “background thread publishing” warnings**.
  * NDJSON shows periodic `vault.status` every ~60s.

**Metrics to collect from day 1**

* Pairing success rate; TLS resume ratio.
* Presence ratio.
* Autofill latency p95/p99.
* Error distribution: `NO_SESSION`, `NO_PRESENCE`, `VAULT_LOCKED`, `NOT_FOUND`, `TOFU_DISABLED`, `PROTO_INCOMPATIBLE`.
* Crash/exit counts for host/agent/TLS.

---

## 6) Auto-lock the Mac on away (decision & plan)

**Decision**: Ship **after** the browser-extension MVP (locking the OS breaks Xcode/iOS debugging).
We **will** auto-LOCK; we **will not** auto-UNLOCK the OS.

**Behavior to ship (later)**

* Vault locks **immediately** on presence loss.
* OS locks after **grace** (default 10–15s), with jitter guards:

  * Presence TTL + grace hysteresis.
  * Optional suppression in fullscreen.
  * Optional “require idle ≥ N sec” before OS lock.
* macOS lock via `CGSession -suspend`.
* User unlock remains **Touch ID / password / Apple Watch** (we do not bypass system auth).

**Planned config keys**

```
ARM_LOCK_ON_AWAY=true|false
ARM_LOCK_GRACE_SEC=15
ARM_LOCK_SUPPRESS_FULLSCREEN=true
ARM_LOCK_REQUIRE_IDLE=false
ARM_LOCK_IDLE_MIN_SEC=15
```

**Telemetry**

* `lock.policy.triggered` (reason, grace_ms, fullscreen, idle_sec)
* `lock.os.invoked` / `lock.os.failed`
* `lock.false_positive` (unlock within X sec)

---

## 7) Scale & reliability guardrails

* **Protocol compatibility**: versioned hello (`proto`, `version`, `min_compatible`) for extension ↔ host ↔ agent. Reject on mismatch with a single-line hint.
* **Schema validation**: strict JSON schema; ignore unknowns at debug level.
* **Origin hardening**: https-only, normalize to eTLD+1, internal HSTS denylist for `http`.
* **No secret logging**: redaction enabled by default; test logs for leaks.
* **Backpressure/timeouts**: host and agent must not block the browser’s service worker; return `BUSY_RETRY` quickly.
* **Packaging**: one signed+notarized app; login item; NM manifest installed/removed by the app (no orphan plists).
* **Multiple browsers/profiles**: host multiplexes cleanly across ports/profiles.

---

## 8) Near-term roadmap (post-MVP, in order)

1. **Auto-lock on away** (with guards, defaults off in dev).
2. **BLE Phase-2**: signed, foreground GATT payload per epoch (anti-relay).
3. **Multi-account chooser** in extension (same eTLD+1, user selects).
4. **Peer-to-peer transport fallback** (AWDL/MPC on Apple; Wi-Fi Direct on Windows; Wi-Fi P2P on Linux).
5. **Windows agent parity** (shared Rust core).
6. **Passkey/WebAuthn relay** (bigger lift, high value).

---

## 9) Glossary

* **SAS (Short Authentication String)** — 6-digit string derived (e.g., via TLS exporter) to let users confirm pairing matches on both devices. (Planned/optional for a later iteration; not required for v1.)
* **K_ble** — Pairing-derived secret used to rotate BLE beacons.
* **Stable wrap key** — Long-term ECDH-derived key that encrypts the vault’s master key on disk (v3).
* **Session key** — Ephemeral ECDH+Face ID-gated key authorizing in-memory unlocks.
* **Provisioning mode (TOFU)** — Allowed only right after **Reset Server Identity**; disabled after first enroll.
* **Kick-on-revoke** — Optional; immediately closes current mTLS session of the revoked device.

---

## 10) Quick commands & flags

**Run TLS with quiet, file-based logs and BLE on:**

```bash
ARM_LOG_FORMAT=json ARM_LOG_FILE=1 ARM_LOG_LEVEL=info \
ARM_FEATURE_BLE=1 ARM_BLE_RSSI_MIN=-65 ARM_BLE_PRESENCE_TTL=8 \
/path/to/ArmadilloTLS.app/Contents/MacOS/ArmadilloTLS
```

**Tail logs:**

```bash
tail -F ~/Library/Logs/ArmadilloTLS/events.ndjson | jq .
```

---

## 11) “Done” definition for the MVP

* Install `.app` + install extension → scan QR → **autofill works reliably** on standard sites.
* All gates enforced; error states are correct and non-leaky.
* Revoke/reset behaviors pass tests; recovery (dev-only) works.
* Observability sufficient to debug user issues without collecting secrets.
* Packaging clean: autostart and native-host manifest install/uninstall are reliable.
* **Operational checks**:

  * iOS logs contain **no background thread publishing warnings**.
  * NDJSON shows periodic `vault.status` events (~60s).

---

If you want, I can also generate a one-page sequence diagram (BLE presence + mTLS + vault unlock + browser fill) to sit alongside this doc.
