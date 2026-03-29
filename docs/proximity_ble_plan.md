# BLE Proximity Plan (v1) — Draft

Goal: Move proximity to BLE beacons (iOS advertises, macOS scans) so “Near/Far” works without relying on a long-lived TLS socket. Proximity assertions remain Mac-only; the extension is read-only.

## Roles
- **iOS**: BLE peripheral (advertiser). Broadcasts a rotating, verifiable token.
- **macOS Agent (Rust)**: BLE central (scanner). Validates tokens, updates `last_seen`, derives Near/Far. The agent is the only authority for proximity.
- **TLS**: Pairing + Face ID approvals when available. Not a proximity signal.
- **Extension**: Read status only; cannot assert proximity.

## Beacon design
- Shared secret per device: `K_ble` (32 bytes), established at pairing, stored in iOS Keychain and macOS agent storage.
- Time bucket: `T = floor(now / 15s)`, accept buckets `T-1, T, T+1` (drift tolerance).
- Token: `token = Trunc16(HMAC-SHA256(K_ble, "BLE1" || T))` (16 bytes).
- Advert payload:
  - Service UUID: fixed `_armadillo_ble_v1` (128-bit).
  - Service data or manufacturer data: `version_byte (optional) + token`.
- Privacy: No device IDs or stable fingerprints in the advert. Rotating token prevents tracking.

## macOS scan logic
- Maintain per paired device: `last_seen_at`, optional `rssi_filtered`, `near_state`.
- On advert:
  1) Extract token; validate against expected tokens for `T-1, T, T+1`.
  2) If valid: update `last_seen_at = now`; update RSSI smoothing if desired.
- State machine (with hysteresis):
  - Near enter: require presence within last 10s (configurable).
  - Far enter: absence beyond grace (e.g., 60s) or failure to see token beyond grace.
  - Optional RSSI threshold if needed (not required initially).
- Feed agent proximity: `prox.beacon_seen` → agent updates `prox.status` (near/far/offline) based on `last_seen_at`.

## Integration with existing gates
- Agent proximity source becomes BLE `last_seen` instead of TLS heartbeats.
- `prox.status` continues to expose state; extension remains read-only.
- TLS heartbeats can remain for diagnostics but are not used for Near/Far decisions.
- Separation of concerns:
  - `prox.near` (BLE-based)
  - `approval_channel.up` (TLS/iOS available for Face ID)
  - `session TTL` (Face ID recency)
  - Vault lock state

## Remote (FAR) approvals
- Without cloud/APNs: use TOTP on the Mac (user provides code out-of-band).
- TLS/iOS approvals only when the app is foregrounded/awake.

## Recovery (aligned with no-cloud)
- Physical recovery secret on Mac; loud flow; revokes previous devices; optional delay (vacation/block/wipe).
- Not tied to BLE/TLS.

## Security invariants
- Only macOS agent asserts proximity. Extension cannot assert Near.
- No stable identifiers in BLE adverts.
- Validate token with ±1 bucket to handle drift.
- Rate-limit recovery attempts; fail closed.

## Implementation steps (recommended order)
1) Implement BLE advert on iOS:
   - Peripheral mode; rotating token as above.
   - Enable proper background mode (Bluetooth LE accessories).
2) Implement BLE scan in macOS agent (Rust):
   - Validate tokens; log `last_seen`; expose simple `prox.status` updates.
   - Keep gates unchanged initially; just observe stability.
3) Flip proximity source:
   - Agent derives Near/Far from BLE `last_seen` + hysteresis; drop dependency on TLS heartbeats for proximity.
4) Separate “approvals available”:
   - Track TLS up/down separately from proximity; UI can show “Near but approvals channel down”.
5) Reconnect log summary (optional):
   - On Far→Near, send a brief activity summary to phone when TLS is available.

## Open items
- Choose 15s bucket and 60s grace as defaults; tune after testing.
- Decide whether to use service data vs manufacturer data (keep payload small).
- Long-idle testing on installed iOS build to validate background advertising throttling.

