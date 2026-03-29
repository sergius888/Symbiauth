# SymbiAuth v1 Trust Specification

> This is the consolidated trust contract. It defines trust modes, the Mac state machine,
> and the UDS protocol between Swift macOS and the Rust agent.
> 
> **Last updated:** 2026-03-03 — applied review fixes A–E.

---

## Trust Modes (v1 Contract)

SymbiAuth v1 has **user-selected trust presets**. The Mac is the **trust authority** and must **notify the user** whenever phone signal is lost and how long remains until revoke (if applicable).

### Definitions

* **Trusted**: Mac may execute sensitive actions (launchers, secrets mount/inject) within current policy.
* **Transport signal** (`signal: Present | Lost`): BLE reachability — whether the Mac can currently reach the phone's GATT service.
  * `signal = Present` does **not** mean trust is granted. It means "we can attempt a challenge."
  * `signal = Lost` means BLE link is down. This triggers mode-specific behavior (see § Signal loss).
* **Grant**: A Rust-verified proof. Mac performs BLE challenge → iPhone returns proof → Rust verifies HMAC → `trust.granted`. This is the **only** event that establishes or restores trust.
* **Re-grant**: Requires **Face ID** on iPhone. Always.

### Mode A — Strict

**Intent:** Maximum safety, most friction.

* If phone signal is lost → **revoke immediately**.
* Mac runs full cleanup (kill tracked processes, unmount secrets volume, clear temp artifacts).
* UI: switches to Locked.

### Mode B — Background TTL

**Intent:** Practical "coffee shop" mode. If phone goes away briefly, allow a timed window.

* While phone signal is present → Trusted.
* On signal loss → start **countdown TTL** (user picks: 2/5/10 minutes or custom).
* Mac immediately notifies user:

  * Menubar state: "Signal lost — revoking in **MM:SS**"
  * Optional system notification: "Phone signal lost — revoking in 05:00"
* If signal returns before TTL expires:

  * Mac attempts **re-grant** (Face ID required on iPhone)
  * **Countdown stays active** as safety net until Rust verifies the new proof
  * On `E_TRUST_GRANTED` → cancel countdown, return to Trusted
  * If re-grant fails → countdown continues, revoke on expiry
* If TTL expires while signal remains lost (or re-grant not completed):

  * Mac revokes and runs full cleanup.

### Mode C — Office Mode (Until Mac Sleep, with Activity Gate)

**Intent:** Office/hotdesk mode. User trusts the environment but wants safety if they walk away.

* Trust persists until **Mac sleeps/lid closes** OR the Mac becomes idle for too long.
* On signal loss:

  * Do **not** revoke immediately.
  * Mac shows: "Signal lost — Office Mode active (locks on idle/sleep)"
* Activity gate:

  * If **no user activity for X minutes** (configurable) → revoke + cleanup.
  * If Mac sleeps/lid closes → revoke + cleanup immediately.
* If signal returns:

  * Mac attempts **re-grant** (Face ID required) → on success, returns to Trusted.

### Re-grant rule (global)

Any time trust is restored after a signal loss, it requires:

1. iPhone app foreground
2. Face ID success
3. challenge–response proof verified by Rust

### Cleanup rule (global)

On revoke (any mode), SymbiAuth must:

* kill all tracked processes launched during trust
* unmount secrets volume (if mounted)
* delete temp secret files (if used)
* clear internal "trusted" state and update UI

**Cleanup timeout:** if cleanup takes longer than `cleanup_timeout_secs` (configurable, default 10s), force-transition to Locked with reason `cleanup_timeout`. Fail closed.

### Mac UX requirement (global)

When signal is lost, Mac must visibly show:

* current trust mode
* whether a countdown is active
* time-to-revoke (if applicable)
* a clear Locked vs Trusted indication

---

# Mac State Machine & Events (v1)

## Core idea

The Mac owns **trust state**. BLE is only used to **(re)grant** trust via a verified proof (Rust verifies HMAC). Trust does **not** flap on raw BLE discovery.

---

## State variables

These are the only pieces of state the Mac trust controller needs:

* `mode: TrustMode`
  `Strict | BackgroundTTL { ttl_secs } | OfficeMode { idle_secs }`

* `trust: TrustState`
  `Locked | Trusted { until: Option<Instant> } | Revoking { started_at: Instant }`

* `signal: SignalState`
  `Present | Lost`

* `deadline: Option<Instant>`
  only used when `mode=BackgroundTTL` and `signal=Lost`

* `last_user_activity: Instant`
  only relevant in `OfficeMode`

* `last_grant_at: Option<Instant>`
  for logging/UI (not policy)

* `revoking_started_at: Option<Instant>`
  tracks cleanup duration; force-transition to Locked if exceeds `cleanup_timeout_secs`

---

## Events (inputs)

All logic is driven by these events:

### A) Proof/crypto events (from Rust verification)

* `E_TRUST_GRANTED(until: Option<Instant>)`
  From Rust: proof verified + policy allowed.
  `until=None` means "no TTL while signal present" (allowed in your model); TTL only applies on loss if mode says so.

* `E_TRUST_DENIED(reason: String)`
  From Rust: proof failed or policy rejected.

### B) Signal events (from BLE transport, reported to Rust via mandatory UDS messages)

* `E_SIGNAL_LOST()`
  Trigger when BLE link is gone / cannot reach phone service *and* we previously had signal present.
  (This is transport-level; it does NOT automatically revoke unless mode requires.)
  **Swift MUST send `trust.signal_lost` to Rust over UDS when this occurs.**

* `E_SIGNAL_PRESENT()`
  Trigger when phone is seen again at transport layer.
  **Important:** this does NOT directly restore trust. It only means "we can attempt re-grant."
  **Important:** this does NOT cancel any running deadline. Only `E_TRUST_GRANTED` cancels deadlines.
  **Swift MUST send `trust.signal_present` to Rust over UDS when this occurs.**

### C) Time events

* `E_TICK(now: Instant)`
  Fired every 1s (or 500ms). Used for countdowns/idle checks/cleanup timeout.

* `E_DEADLINE_EXPIRED()`
  Derived event when `deadline <= now`.

* `E_CLEANUP_TIMEOUT()`
  Derived event when `revoking_started_at + cleanup_timeout_secs <= now`.

### D) User/system events

* `E_USER_END_SESSION()`
  User clicked "End session" in menubar.

* `E_MAC_SLEEP()`
  Lid close / sleep event.

* `E_USER_ACTIVITY()`
  From activity monitor (keyboard/mouse/etc.). Updates `last_user_activity`.

---

## Outputs (actions)

These are side effects the state machine can trigger:

* `A_NOTIFY_SIGNAL_LOST(remaining_secs, mode)`
  Menubar change + optional system notification.

* `A_NOTIFY_TRUSTED(until/remaining, mode)`
  Menubar update.

* `A_NOTIFY_LOCKED(reason)`
  Menubar update.

* `A_REQUEST_REGRANT()`
  Mac asks iPhone to re-grant trust (iPhone must be foreground + Face ID).
  Practically: attempt BLE connect → send challenge.

* `A_REVOKE_AND_CLEANUP(reason)`
  Calls Rust agent to revoke + cleanup (kill tracked procs, unmount, etc.)

* `A_PUSH_EVENT(event_type, payload)`
  Rust pushes a `trust.event` to Swift over UDS for UI updates (see UDS protocol section).

---

## State transitions (contract)

### 1) Startup

* Initial:

  * `trust = Locked`
  * `signal = Lost`
  * `deadline = None`

Action:

* Start BLE scanning (transport layer).
* UI: Locked.

---

### 2) Grant path

**Trigger:** Mac successfully completes challenge/proof and Rust replies granted.

Event: `E_TRUST_GRANTED(until)`

* Set:

  * `trust = Trusted { until }`
  * `signal = Present`
  * `deadline = None` ← **this is the only place deadline is cancelled**
  * `last_grant_at = now`
* Output:

  * `A_NOTIFY_TRUSTED(...)`
  * `A_PUSH_EVENT("granted", { trust_until_ms, mode, trust_id })`

Notes:

* `until` may be `None` if you're in "no TTL while signal present" mode.
* If `until` is set (max session duration), it is the "hard expiry regardless of phone state" variant.

---

### 3) Signal loss behavior (per trust mode)

Event: `E_SIGNAL_LOST()`

* Set:

  * `signal = Lost`

Then branch by `mode`:

#### Mode A: Strict

* If `trust == Trusted`:

  * `trust = Revoking { started_at: now }`
  * Output: `A_REVOKE_AND_CLEANUP(reason="signal_lost")`
  * On cleanup complete: `trust = Locked`, `A_NOTIFY_LOCKED("signal_lost")`
  * Output: `A_PUSH_EVENT("revoked", { reason: "signal_lost" })`

#### Mode B: BackgroundTTL { ttl_secs }

* If `trust == Trusted`:

  * Set `deadline = now + ttl_secs`
  * Output: `A_NOTIFY_SIGNAL_LOST(remaining=ttl_secs, mode)`
  * Output: `A_PUSH_EVENT("deadline_started", { deadline_ms, ttl_secs })`
  * Trust stays `Trusted` during countdown (resources remain available until expiry)
* If already `deadline != None`, refresh notification only (don't spam).

#### Mode C: OfficeMode { idle_secs }

* If `trust == Trusted`:

  * No countdown by default.
  * Output: `A_NOTIFY_SIGNAL_LOST(remaining_secs=nil, mode="office")`
  * Output: `A_PUSH_EVENT("signal_lost", { mode: "office" })`
  * Trust remains `Trusted` until `E_MAC_SLEEP` or idle timeout triggers.

---

### 4) Signal returns (important — FIXED)

Event: `E_SIGNAL_PRESENT()`

* Set:

  * `signal = Present`
* Output: `A_PUSH_EVENT("signal_present", {})`
* **DO NOT modify `deadline`** — deadline stays active as safety net until re-grant succeeds.
* Re-grant behavior depends on mode:

  * **Mode B (BackgroundTTL):** `A_REQUEST_REGRANT()` — attempt re-grant because countdown is running and we want to cancel it if proof succeeds.
  * **Mode C (OfficeMode):** re-grant is **optional** (for UI health/status), not mandatory to keep trust alive. Trust is already held by the office mode contract.
  * **Mode A (Strict):** N/A — trust was already revoked on signal loss.
* If `trust == Locked`:

  * v1: don't auto-regrant; require user to start session from iPhone or explicit action.

**Rule:** `E_SIGNAL_PRESENT` never directly grants trust and never cancels deadlines. Only `E_TRUST_GRANTED` does both.

---

### 5) Countdown expiry (Background TTL)

Event: `E_TICK(now)`

* If `mode = BackgroundTTL` and `deadline != None` and `now >= deadline`:

  * Emit `E_DEADLINE_EXPIRED()`

Event: `E_DEADLINE_EXPIRED()`

* If `trust == Trusted`:

  * `trust = Revoking { started_at: now }`
  * Output: `A_REVOKE_AND_CLEANUP(reason="ttl_expired_after_signal_loss")`
  * On cleanup complete: `trust = Locked`, `deadline=None`, `A_NOTIFY_LOCKED("ttl_expired")`
  * Output: `A_PUSH_EVENT("revoked", { reason: "ttl_expired" })`

---

### 6) Office idle gate

Event: `E_USER_ACTIVITY()`

* Set `last_user_activity = now`

Event: `E_TICK(now)`

* If `mode=OfficeMode` and `trust==Trusted` and `signal==Lost`:

  * If `now - last_user_activity >= idle_secs`:

    * `trust = Revoking { started_at: now }`
    * Output: `A_REVOKE_AND_CLEANUP(reason="office_idle_timeout")`
    * On cleanup complete: `trust=Locked`, `A_NOTIFY_LOCKED("idle_timeout")`
    * Output: `A_PUSH_EVENT("revoked", { reason: "idle_timeout" })`

**Note:** only apply idle timeout when `signal==Lost`, exactly as your "phone gone but office mode" risk control.

---

### 7) Max session duration (optional v1.1)

If you support a hard max session duration regardless of phone:

* Set `trust.until = now + max_session_secs` at grant
* On `E_TICK`, if `now >= until` → revoke regardless of signal state

This is **separate** from Background TTL (which starts on signal loss). To avoid user confusion, name this "Max session duration" in the UI, not "TTL."

---

### 8) Manual end + Mac sleep

Event: `E_USER_END_SESSION()`

* If `trust==Trusted`:

  * revoke immediately → Revoking → Locked
  * Output: `A_PUSH_EVENT("revoked", { reason: "manual_end" })`

Event: `E_MAC_SLEEP()`

* If `trust==Trusted`:

  * revoke immediately → Revoking → Locked
  * Output: `A_PUSH_EVENT("revoked", { reason: "mac_sleep" })`

---

### 9) Cleanup timeout (NEW)

Event: `E_TICK(now)`

* If `trust == Revoking { started_at }` and `now - started_at >= cleanup_timeout_secs`:

  * Emit `E_CLEANUP_TIMEOUT()`

Event: `E_CLEANUP_TIMEOUT()`

* Force: `trust = Locked`
* Output: `A_NOTIFY_LOCKED("cleanup_timeout")`
* Output: `A_PUSH_EVENT("revoked", { reason: "cleanup_timeout" })`
* Log warning: `mac.trust.cleanup_timeout elapsed_ms=<...>`

---

## Logging requirements (must-have)

Each transition should log one stable event:

* `mac.trust.granted mode=<...> until=<...>`
* `mac.signal.lost mode=<...> deadline=<...>`
* `mac.signal.present mode=<...>`
* `mac.trust.deadline_started secs=<...>`
* `mac.trust.deadline_cancelled reason=regrant_ok`
* `mac.trust.revoking reason=<...>`
* `mac.trust.revoked`
* `mac.trust.cleanup_timeout elapsed_ms=<...>`
* `mac.office.idle_timeout idle_secs=<...>`

---

## UX requirements tied to state

* If `signal==Lost` and `deadline!=None`: show countdown prominently.
* If `signal==Lost` and office mode: show "Office mode active (locks on idle/sleep)."
* If locked: show why ("expired", "signal lost", "manual end", "sleep", "cleanup_timeout").

---

# V1 UDS Trust Protocol (Swift macOS ↔ Rust agent)

## Overview

Swift macOS BLE Central receives a `proof` from iPhone over GATT. Swift does **no crypto verification**. It forwards verification to Rust over UDS.

Rust replies with `trust.granted` or `trust.denied`, and **pushes state change events** to Swift for UI updates. Swift updates menubar and renders countdowns locally from timestamps.

All messages are **framed JSON** (your existing length-prefix framing).

## Common fields (all messages)

```json
{
  "type": "string",
  "v": 1,
  "corr_id": "string",
  "ts_ms": 1772227983000,
  "origin": "macos"
}
```

* `v`: protocol version (start with `1`)
* `corr_id`: required, generated by sender per request
* `ts_ms`: unix epoch milliseconds (sender clock)
* `origin`: `"macos"` or `"agent"` (optional but useful)

---

## Message: trust.verify_request (Swift → Rust)

Swift sends this after it has:

* connected to iPhone via BLE
* obtained `challenge` and `proof` payloads
* measured RSSI (optional but recommended)

```json
{
  "type": "trust.verify_request",
  "v": 1,
  "corr_id": "abc123",
  "ts_ms": 1772227983000,

  "mac_id": "sha256:b11660d2...6b3b",
  "phone_fp": "sha256:5084370890...59d9",

  "mode": "strict | background_ttl | office",
  "ttl_secs": 300,

  "rssi_dbm": -46,

  "challenge": {
    "nonce_b64": "base64(16 bytes)",
    "challenge_ts_ms": 1772227982500
  },

  "proof": {
    "proof_b64": "base64(32 bytes)",
    "proof_ts_ms": 1772227982700
  },

  "transport": {
    "ble_id": "uuid-or-identifier",
    "device_name": "Chiricescu's iPhone",
    "service_uuid": "C7F3A8B0-...-CDEF"
  }
}
```

### Notes

* `mac_id` is the stable Mac identifier used in pairing (your agent TLS fingerprint works fine).
* `phone_fp` is the iPhone identity fingerprint already used in pairing.
* `mode`/`ttl_secs` are a **request** from Swift based on user selection. Rust treats them as input but may **clamp** to policy. Rust returns effective values in `trust.verify_response`.
* Rust is the source of truth for policy; Swift does not enforce limits.

---

## Message: trust.verify_response (Rust → Swift)

Rust answers a verify request with a single response.

### Success

```json
{
  "type": "trust.verify_response",
  "v": 1,
  "corr_id": "abc123",
  "ts_ms": 1772227983050,

  "ok": true,
  "grant": {
    "trust_id": "t_7s9d2k",
    "mode": "background_ttl",
    "trust_until_ms": 1772228283000,
    "ttl_secs_effective": 300,
    "policy": {
      "ttl_cap_secs": 1800,
      "rssi_min_dbm": -75
    }
  }
}
```

### Deny

```json
{
  "type": "trust.verify_response",
  "v": 1,
  "corr_id": "abc123",
  "ts_ms": 1772227983050,

  "ok": false,
  "deny": {
    "reason": "hmac_invalid | stale | unknown_device | policy_reject | rate_limited",
    "detail": "optional human string"
  }
}
```

---

## Message: trust.signal_lost (Swift → Rust) — MANDATORY

Swift sends this when the BLE link to the paired phone is lost.

```json
{
  "type": "trust.signal_lost",
  "v": 1,
  "corr_id": "sl_123",
  "ts_ms": 1772227990000,
  "mac_id": "sha256:....",
  "phone_fp": "sha256:....",
  "trust_id": "t_7s9d2k | null"
}
```

Rust uses this to:

* Start Background TTL deadline (Mode B)
* Track signal state for Office Mode idle gate (Mode C)
* Immediately revoke in Strict mode (Mode A)
* Push `trust.event` back to Swift with updated state

> **Note:** `trust_id` is optional (nullable). Signal can be lost when Locked, on restart, or before any grant.

---

## Message: trust.signal_present (Swift → Rust) — MANDATORY

Swift sends this when the paired phone's BLE service is discovered again.

```json
{
  "type": "trust.signal_present",
  "v": 1,
  "corr_id": "sp_123",
  "ts_ms": 1772227995000,
  "mac_id": "sha256:....",
  "phone_fp": "sha256:....",
  "trust_id": "t_7s9d2k | null"
}
```

Rust uses this to:

* Update internal `signal = Present`
* Push `trust.event` back to Swift
* **Does NOT cancel deadline** — deadline continues until `trust.verify_request` succeeds

> **Note:** `trust_id` is optional (nullable). Signal can appear when Locked or before any grant.

---

## Message: trust.revoke (Swift → Rust)

Triggered by:

* user clicked End Session
* mac sleep/lid close

```json
{
  "type": "trust.revoke",
  "v": 1,
  "corr_id": "rvk_91k2",
  "ts_ms": 1772229000000,

  "reason": "manual_end | mac_sleep",
  "trust_id": "t_7s9d2k"
}
```

### Response

```json
{
  "type": "trust.revoke_ack",
  "v": 1,
  "corr_id": "rvk_91k2",
  "ts_ms": 1772229000050,
  "ok": true
}
```

> **Note:** TTL expiry, idle timeout, and signal_lost_strict revocations are now determined by Rust internally (since Rust owns the deadlines). Swift only sends `trust.revoke` for explicit user/system triggers.

---

## Message: trust.event (Rust → Swift) — PUSH

Rust pushes state change events to Swift. Swift **does not poll** for these.

```json
{
  "type": "trust.event",
  "v": 1,
  "ts_ms": 1772228000000,
  "event": "granted | denied | revoked | signal_lost | signal_present | deadline_started | deadline_cancelled | cleanup_timeout",
  "trust_id": "t_7s9d2k",
  "mode": "strict | background_ttl | office",
  "trust_until_ms": 1772228300000,
  "deadline_ms": 1772228300000,
  "reason": "optional"
}
```

Swift behavior on receiving `trust.event`:

* Stores latest `trust_until_ms` / `deadline_ms`
* Runs a **local 1s UI timer** to display `remaining = deadline_ms - now`
* No 1s UDS polling needed — Swift has the timestamps and ticks its own display

---

## Message: trust.status (Swift → Rust) — ON-DEMAND ONLY

Used only for:

* App launch / window appears
* Reconnect after UDS failure
* Debug inspection

**Not used for countdown display** (that's now driven by `trust.event` pushes).

```json
{
  "type": "trust.status",
  "v": 1,
  "corr_id": "st_1",
  "ts_ms": 1772227984000
}
```

### Response

```json
{
  "type": "trust.status_response",
  "v": 1,
  "corr_id": "st_1",
  "ts_ms": 1772227984050,

  "state": "locked | trusted | revoking",
  "mode": "strict | background_ttl | office",
  "trust_id": "t_7s9d2k",
  "trust_until_ms": 1772228283000,
  "signal": "present | lost",
  "deadline_ms": 1772228283000,

  "active": {
    "mounted": true,
    "running_pids": [1234, 5678]
  }
}
```

---

# Where logic lives (source of truth)

## Rust agent owns:

* trust lease times (`trust_until_ms`)
* deadline management (start/cancel based on signal events + mode)
* mode enforcement + policy clamping
* HMAC verification
* cleanup execution + timeout
* idle gate (Office Mode)
* revoke triggering (TTL expiry, idle timeout, strict signal loss)
* pushing `trust.event` to Swift

## Swift macOS owns:

* BLE transport (scan, connect, GATT challenge/proof exchange)
* Forwarding proof to Rust via `trust.verify_request`
* Reporting signal state via `trust.signal_lost` / `trust.signal_present` (mandatory)
* Sending `trust.revoke` on explicit user/system triggers (manual end, mac sleep)
* Rendering UI from `trust.event` push data
* Local 1s countdown display timer (no UDS traffic)
* `trust.status` for on-demand sync only

---

# Minimal set to implement first (vertical slice)

1. `trust.verify_request` → `trust.verify_response`
2. `trust.signal_lost` (Swift → Rust)
3. `trust.signal_present` (Swift → Rust)
4. `trust.event` (Rust → Swift, push)
5. `trust.revoke` → `trust.revoke_ack`
6. `trust.status` → `trust.status_response` (on-demand only)
