## BLE Presence — Phase 2 (Anti‑Relay, Signed Epoch Payload)

Status: Draft plan (not yet implemented). Linked from `docs/north-star.md`.

### Goal
Increase assurance that a nearby beacon truly originates from the paired iPhone by adding a signed, foreground GATT payload per epoch that the macOS scanner can verify.

### Threat model
- Relay attacks rebroadcasting Phase‑1 rotating service UUIDs from afar.
- Software-only beacons attempting to spoof presence without possession of `K_ble`.

### Design sketch
- Key material: reuse `K_ble` (pairing‑derived via ECDH + HKDF).
- Epoching: fixed window (e.g., 8s) aligned between devices (t0 = floor(now/epoch)).
- Payload: iOS, when foreground and advertising, exposes a small GATT characteristic:
  - `epoch`: uint64 (or truncated)
  - `nonce`: 8–12 bytes
  - `sig`: HMAC(K_ble, “ble:p2:signed|epoch|nonce|mac_fp_suffix”)[0..16]
- Scanner verifies:
  - epoch is in {t−1, t, t+1}
  - HMAC matches for the allowed device(s)
  - RSSI threshold and freshness windows still apply
- Privacy: payload contains no PII; `mac_fp_suffix` is a short suffix already shown in UI.

### iOS changes
- Foreground mode: expose a lightweight GATT service/characteristic when app is active.
- Rate limit reads (once per epoch) and avoid keeping radio awake unnecessarily.
- If background constraints block GATT, fall back to Phase‑1 only.

### macOS changes
- When Phase‑2 is available, prefer signed verification; otherwise fall back to Phase‑1.
- Emit NDJSON:
  - `ble.p2.ok` (epoch, rssi)
  - `ble.p2.fail` (reason: bad_sig|stale|rate_limit)

### Acceptance
- With the phone foregrounded, scanner verifies signed payload reliably (≥99% within 1 epoch).
- Relay attempts without `K_ble` fail signature check.
- Phase‑1 remains functional when Phase‑2 is unavailable (background, OS limits).

### Open items
- Exact epoch length and jitter budget.
- Background feasibility across iOS versions.
- Battery impact; disable toggles and thresholds.


