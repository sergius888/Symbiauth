# Proximity & Session Rules (Agreed)
_Updated: 2025-12-25_

## Recent Updates (2025-12-25)
- Face ID push works end-to-end: agent nudges TLS/iOS; TLS forwards to phone; Face ID prompt appears.
- Vault auto-reopens after Face ID: TLS replays the cached `vault.open` to the agent on `auth.ok`, so fills work without re-pairing.
- Extension: auto-retry fill after Face ID; popup shows Proximity/Vault status; badge indicates lock.
- nmhost: now forwards `prox.status` / `vault.status` so popup can display live state.

## Next Steps (short list)
- Silence `prox.ack` route_miss noise and reconnect/resume heartbeat cleanly on iOS reconnect.
- Consider per-site “always step-up” intent (extra Face ID for selected origins even when vault is unlocked) and reflect that in the popup/device UI.
- Add `last_heartbeat_age_ms` to `prox.status` so UIs can render presence bars accurately.
- Polish iOS UI per “Manage”/“Unlock” flows in the UX section below.

## Heartbeats & Proximity
- Source: TLS/iOS emits `prox.heartbeat` every few seconds while the phone link is healthy; stop when the phone is away/offline.
- Grace window: If no heartbeat arrives for the grace interval (target 60s), proximity flips to `Far` and the vault auto-locks.
- Auto-recover: Any heartbeat instantly returns proximity to `Near` (no manual step), even after grace expired.
- No self-heartbeat: The agent never self-refreshes proximity; only real heartbeats count.

## Vault Lock / Unlock
- `Near` + session valid ⇒ vault remains unlocked.
- `Far` ⇒ vault locks and gated ops fail.
- When `Near` resumes:
  - If session TTL still valid ⇒ vault unlock resumes automatically (no Face ID).
  - If session TTL expired ⇒ require Face ID once to start a new session.

## Session TTL
- Session starts after a Face ID unlock.
- Session TTL is user-configurable (e.g., 1 hour, user-chosen).
- While TTL is valid, coming back to `Near` resumes the session without Face ID.
- After TTL expires, the next gated op triggers Face ID; approval starts a new session.

## User Experience Flow
- Enter room (Near via heartbeat):  
  - If no active session or session expired ⇒ prompt on phone to unlock session (Face ID).  
  - If session valid ⇒ silent resume; fills work immediately.
- Leave room: Heartbeats stop; after grace ⇒ `Far`; vault locks; fills blocked.
- Return within TTL: Heartbeat resumes ⇒ `Near` ⇒ vault unlock resumes silently; fills work.
- Return after TTL: Heartbeat resumes ⇒ `Near` ⇒ next gated op triggers Face ID; after approval, new session starts.

## iOS App UX (multi-device)
- Home screen lists all paired Macs. Each row shows: device name/fingerprint, presence bar (green/yellow/red based on heartbeat freshness/age), and actions.
- Buttons per device row:
  - `Unlock`: visible when heartbeats are present (green/yellow). On tap, triggers Face ID for that Mac; if approved, starts/extends that Mac’s session.
  - `Manage`: always available; opens device-specific settings:
    - Lock now / Unlock (Unlock always Face ID-gated)
    - Session TTL slider (per device, within policy limits; e.g., 15m–2h)
    - Proximity settings (mode/grace: read-only or editable if policy allows)
    - Live status: Near/Far, last heartbeat age, session expiry time
    - Device actions: rename, forget/revoke pairing (with confirmation)
  - (Optional) `Lock`: in Manage screen to force-lock that Mac; re-unlock requires Face ID even if signal stays green.
- Multiple Macs in same room: phone emits heartbeats per active link; bars turn green; user taps Unlock on whichever Macs they want. Face ID runs once per Mac when tapping Unlock.
- Leaving the room: bars go red after grace; vaults lock. Returning within TTL: heartbeat resumes, bar turns green; per current rule, next gated op triggers Face ID if TTL expired; if TTL still valid, can auto-resume (policy decision).
- No overlapping popups: keep everything in-app. Presence bar updates live; actions are user taps. No stacked system notifications.

## Implementation Notes (next steps)
- Ensure TLS/iOS sends steady `prox.heartbeat`; stop when away.
- Increase grace to 60s to reduce flakiness during brief drops.
- Keep auto-Far after grace with no heartbeat, and instant Near on the next heartbeat.
- Add `last_heartbeat_age_ms` to `prox.status` so UIs can render bars without guessing.
