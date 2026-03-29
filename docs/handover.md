# Armadillo Handover (Current State, Behavior, TODOs)

## Components
- **agent-macos (Rust)**: UDS server (`~/.armadillo/a.sock`), vault, proximity logic, gating, policy.
- **TLS terminator (Swift)**: mTLS to iOS, UDS to agent.
- **nmhost (Rust)**: Chrome native messaging host (`armadillo-nmhost`).
- **Web extension**: MV3 service worker + content script; popup for TOTP.
- **iOS app**: Pairing, Face ID approval, BLE presence (heartbeats to be sent via TLS).

## Proximity & Session (agreed rules)
- Heartbeats: TLS/iOS must send `prox.heartbeat` every few seconds while the phone link is healthy; stop when away/offline.
- Grace: target 60s (currently ~15s in code; to be bumped). No heartbeat for grace ⇒ proximity = `Far` and vault locks.
- Auto-recover: any heartbeat instantly sets `Near` (no manual step), even after grace expired.
- No self-heartbeat in agent.
- Vault unlock: `Near` + valid session ⇒ unlocked. `Far` ⇒ lock and block gated ops. When `Near` resumes:
  - Session TTL valid ⇒ unlock resumes silently.
  - Session TTL expired ⇒ Face ID required once to start a new session.
- Session TTL: user-configurable (example 1h). Starts after Face ID. Within TTL, returns to `Near` resume without Face ID; after TTL, next gated op triggers Face ID.
- UX flow: enter room (heartbeat) ⇒ prompt Face ID if no/expired session else silent resume; leave ⇒ after grace goes Far/locked; return within TTL ⇒ resume; return after TTL ⇒ Face ID again.
- iOS UI (planned): list of Macs with presence bar (green/yellow/red by heartbeat age); buttons per device: Unlock (Face ID), Manage (lock/unlock, TTL slider within policy, proximity settings view/edit per policy, live status with heartbeat age and expiry, rename/forget).

## Key Code Changes (recent)
- **Proximity watchdog** in agent: ticks every 500ms to enforce grace; flips to Far after grace with no heartbeat; back to Near on heartbeat.
- **Heartbeat handler**: `prox.heartbeat` accepted in agent; sets Near if Far, otherwise refreshes heartbeat.
- **nmhost** updated to forward `prox.heartbeat` to agent.
- **Session reuse**: auth sid check defaults to true when sid missing (extension reuse of Face ID).
- **TTL defaults**: `auth_ttl_s` and `prox_session_ttl_s` bumped to 3600s in `config.rs`.
- **Idempotency**: `vault.write` requires `idempotency_key` (UUID) or returns error.
- **Error logging**: send_error logs err_code/err_reason.
- **Extension**: public `background.js`/`content.js` simplified; background auto-send `prox.heartbeat` (when host accepts); cred.list → cred.get (first account) → fill.form to content script.
- **Native host path**: actual binary is `target/release/armadillo-nmhost` (workspace root).

## Current Behavior / Known Issues
- If heartbeats stop (TLS/iOS not sending), agent flips to Far after grace ⇒ `proximity_far` on cred.get; needs steady heartbeats from TLS/iOS.
- Face ID prompt only appears on auth.request; current extension flow just returns errors when locked; plan: push auth.request to phone on `session_unlock_required`/`proximity_far`.
- iOS “Vault Test” button fails unless it sends `idempotency_key`; extension writes not needed (reads only).
- nmhost manifest must point to `~/WORK/ArmadilloProject/target/release/armadillo-nmhost`; if wrong, errors: “host not found” or “Unknown message type: prox.heartbeat.”
- Grace still small (~15s); should be bumped to 60s as per rules.
- Session unlock expires after TTL/idle; without heartbeat/near, fills will fail.

## How to Run (current)
- Agent: `ARM_AUTH_POLICY=per_op` (if you want Face ID on first op) or leave default; start with `cargo run --bin agent-macos`.
- TLS: launch ArmadilloTLS.app (ensure it connects to agent UDS).
- nmhost: build `cargo build -p armadillo-nmhost --release`; set manifest path to the release binary (see below); restart browser.
- Web extension: reload after nmhost update; service worker logs `[armadillo]`.
- Pairing: scan QR on iOS; Face ID should appear on first auth.request if locked.

## Native Messaging Manifest (Chrome path)
File: `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.armadillo.nmhost.json` (repeat for Beta/Canary/Chromium/Brave/Edge if used).
```json
{
  "name": "com.armadillo.nmhost",
  "description": "Armadillo Native Messaging host",
  "path": "/Users/zenmonkey/WORK/ArmadilloProject/target/release/armadillo-nmhost",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://opojlcnklbhebgdnafldoinkmedgpokk/"]
}
```
After editing: `pkill -f armadillo-nmhost` and restart browser.

## Quick Debug Commands
- Proximity status:
```bash
python3 - <<'PY'
import socket,json,struct,os
msg={"type":"prox.status","corr_id":"p"};d=json.dumps(msg).encode();f=struct.pack(">I",len(d))+d
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.connect(os.path.expanduser("~/.armadillo/a.sock"))
s.sendall(f);n=struct.unpack(">I",s.recv(4))[0];print(s.recv(n).decode());s.close()
PY
```
- Vault status: same with `"type":"vault.status"`.
- Heartbeat manual:
```bash
python3 - <<'PY'
import socket,json,struct,os
msg={"type":"prox.heartbeat","corr_id":"hb"};d=json.dumps(msg).encode();f=struct.pack(">I",len(d))+d
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.connect(os.path.expanduser("~/.armadillo/a.sock"))
s.sendall(f);n=struct.unpack(">I",s.recv(4))[0];print(s.recv(n).decode());s.close()
PY
```
- Write with idempotency:
```bash
python3 - <<'PY'
import socket,json,struct,os,uuid,base64
msg={"type":"vault.write","key":"sample_test","value_b64":base64.b64encode(b"hello").decode(),"idempotency_key":str(uuid.uuid4()),"corr_id":"seed1"}
d=json.dumps(msg).encode();f=struct.pack(">I",len(d))+d
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.connect(os.path.expanduser("~/.armadillo/a.sock"))
s.sendall(f);n=struct.unpack(">I",s.recv(4))[0];print(s.recv(n).decode());s.close()
PY
```

## What’s Next / TODO
- TLS/iOS: emit `prox.heartbeat` every few seconds while connected; stop when truly away. Add last_heartbeat_age_ms to prox.status.
- Increase grace to 60s in config; ensure instant Near on heartbeat.
- Push auth.request to phone when `session_unlock_required`/`proximity_far` so Face ID appears without restart.
- iOS Vault Test: add `idempotency_key` to writes.
- UI: implement presence bar + per-device Unlock/Manage screens as described.
- Stabilize default session TTL policy (user-configurable) consistent with proximity resume rules.
