# System Overview — Updated 2025-12-30

This is the current ground truth of architecture, flows, and behaviors.

## Purpose (Goal)
Secure password/credential retrieval with proximity + user approval:
- Primary: when phone is near (BLE/mTLS), fills are allowed per policy and session TTL.
- Secondary: when phone is away, block or require explicit step-up (e.g., TOTP/Face ID).

## Architecture (Current)
- **Agent (Rust, macOS)**: core policy/gating, vault, proximity/session enforcement. Communicates via UDS.
- **TLS Terminator (Swift, macOS)**: mTLS bridge to iOS; forwards messages to agent over UDS; emits prox.heartbeat only when iOS traffic is live; sends `tls.down` when iOS is silent.
- **iOS App**: mTLS client, Face ID approvals, pairing; BLE proximity source (future background robustness needed).
- **nmhost (Rust)**: Native Messaging host for the browser extension; forwards extension messages over UDS to agent; now forwards status to popup.
- **Browser Extension (MV3)**: UI for fill, TOTP, status; talks to nmhost; blocks fill when far/offline/locked; shows proximity/vault status.

Data paths (today):
- Extension → nmhost → UDS → Agent.
- iOS ↔ TLS terminator ↔ UDS ↔ Agent.

## Key Behaviors (As Implemented)
- **Proximity**
  - Heartbeats: TLS sends `prox.heartbeat` every 3s **only when iOS traffic is fresh**; if no iOS traffic for >10s, TLS sends `tls.down` and stops heartbeats.
  - Agent accepts heartbeats only from TLS role; computes near/far/offline using `last_heartbeat_age_ms` and grace. Missing/aged heartbeats → far/offline → vault locks.
  - `tls.down` immediately sets proximity Far and locks vault.
- **Vault/Session**
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

## Recent Key Files
- `apps/tls-terminator-macos/ArmadilloTLS/TLSServer.swift` — heartbeat gating, `tls.down`.
- `apps/agent-macos/src/proximity.rs`, `bridge.rs` — heartbeat age, far/offline lock, gating.
- `packages/webext/public/background.js`, `popup.html/js` — status UI, block fills when far/offline/locked.
- `docs/proximity_rules.md` — rules (dated 2025-12-25).
- `docs/progress_2025-12-30.md` — checkpoint log.

