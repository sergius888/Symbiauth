# Phase 7d: Preferences Window (Menubar App, Option A) — Implementation Spec

> **Status:** Drafted for review (implementation not started)
> **Scope:** macOS menubar app + Rust agent UDS extensions. No iOS code changes.
> **Depends on:** Phase 7a + 7b complete, 8a complete.

---

## Why 7d now

7a/7b proved trust-gated execution and secrets management, but configuration is still fragmented:
- launchers require YAML editing
- secrets are manageable but minimal (menubar dialogs)
- trust diagnostics/settings are not centralized

7d introduces a Preferences window as the configuration surface while preserving menubar as the execution surface.

---

## Product model (locked)

- **Menubar remains primary for runtime actions**:
  - trust status
  - run launcher
  - end session
- **Preferences window is configuration-only**:
  - launchers
  - secrets
  - trust/settings
  - diagnostics
- **App remains menubar-only** (`NSApp.setActivationPolicy(.accessory)` stays).
- No Dock-first app conversion in 7d.

---

## UX principles (locked)

1. No hidden critical controls.
2. No redundant screens for the same object.
3. No destructive actions without explicit confirmation.
4. Validation errors must be inline and actionable (not only logs).
5. Keep user-facing language operational, not dev-jargon.

---

## Window architecture

### Surface model

- New menu action: `Settings ▸ Open Preferences…`
- Single reusable window instance (no duplicates).
- On reopen: focus existing window instead of creating a new one.

### Implementation choice

- Keep AppKit menubar shell (`AppDelegate`) and embed a SwiftUI Preferences root via `NSHostingController`.
- Reason: fastest path to a rich tabbed UI while preserving existing AppKit status item and UDS plumbing.

### New macOS files (target)

- `apps/tls-terminator-macos/ArmadilloTLS/Preferences/PreferencesWindowController.swift`
- `apps/tls-terminator-macos/ArmadilloTLS/Preferences/PreferencesRootView.swift`
- `apps/tls-terminator-macos/ArmadilloTLS/Preferences/LaunchersTabView.swift`
- `apps/tls-terminator-macos/ArmadilloTLS/Preferences/SecretsTabView.swift`
- `apps/tls-terminator-macos/ArmadilloTLS/Preferences/SettingsTabView.swift`
- `apps/tls-terminator-macos/ArmadilloTLS/Preferences/DiagnosticsTabView.swift`
- `apps/tls-terminator-macos/ArmadilloTLS/Preferences/PreferencesViewModel.swift`

> `TLSServer.swift` remains transport-generic. Preferences talks through `AppDelegate` -> `sendToAgent(json:...)`.

---

## Information architecture (tabs)

## 1) Launchers tab

Purpose: fully replace YAML editing for normal users.

Sections:
- launcher table: name, id, enabled, trust policy, single instance, status/running
- details form: editable fields
- actions: `Add`, `Save`, `Duplicate`, `Delete`, `Run now` (only when trusted)
- templates quick-start: `SSH`, `Trading Bot`, `Signer`

Validation behavior:
- inline validation before save
- server-side validation on save with concrete error mapping
- `Run now` uses existing `launcher.run` UDS contract.
- After `Run now`, refresh `launcher.list` so both Preferences and menubar running indicators remain consistent.

## 2) Secrets tab

Purpose: richer replacement for menubar secret dialogs.

Sections:
- list: name, availability, usage count, status
- detail pane: `used_by` launchers
- actions: `Add`, `Update`, `Delete`, `Test`

Constraints:
- never display secret values
- write/delete operations remain trust-gated

## 3) Settings tab

Purpose: trust behavior + app-level operational controls.

Sections:
- trust mode: `strict | background_ttl | office`
- timers:
  - `background_ttl_secs`
  - `office_idle_secs`
- startup behavior toggles (if already supported)
- safety toggle group (future-compatible placeholders allowed but disabled with tooltip)

## 4) Diagnostics tab

Purpose: human-readable state and fast triage.

Sections:
- current trust snapshot
- signal state + countdown remaining
- active trusted action runs
- last launcher/secret errors
- export/copy diagnostics summary

---

## UDS contracts

### Existing contracts reused unchanged

- `launcher.list`
- `launcher.run`
- `secret.list`
- `secret.set`
- `secret.delete`
- `secret.test`
- `trust.status`
- `trust.revoke`

### New contracts required for 7d

## Launcher CRUD

Trust gating decision (locked):
- `launcher.upsert` and `launcher.delete` are **not trust-gated**.
- Rationale: users must be able to configure while locked; only execution remains trust-gated.

### `launcher.upsert`

Request:
```json
{
  "type": "launcher.upsert",
  "corr_id": "abc123",
  "launcher": {
    "id": "ssh-prod",
    "name": "SSH Production",
    "description": "Open prod SSH",
    "exec_path": "/bin/zsh",
    "args": ["-lc", "ssh trader@prod"],
    "cwd": "/Users/cmbosys",
    "secret_refs": ["SSH_PASSPHRASE"],
    "trust_policy": "continuous",
    "single_instance": true,
    "enabled": true
  }
}
```

Response:
```json
{
  "type": "launcher.upsert",
  "corr_id": "abc123",
  "ok": true,
  "id": "ssh-prod",
  "created": false
}
```

Errors: `invalid_launcher`, `id_duplicate`, `config_write_failed`, `config_reload_failed`.

### `launcher.delete`

Request:
```json
{
  "type": "launcher.delete",
  "corr_id": "abc123",
  "launcher_id": "ssh-prod"
}
```

Response:
```json
{
  "type": "launcher.delete",
  "corr_id": "abc123",
  "ok": true,
  "launcher_id": "ssh-prod"
}
```

Errors: `launcher_not_found`, `config_write_failed`.

### `launcher.template.list`

Locked behavior:
- Source: hardcoded built-in templates in Rust for 7d (no template YAML file yet).
- Shape: each template returns launcher-like defaults with placeholders.
- UI flow: selecting template pre-fills form locally; persistence only happens on `Save` via `launcher.upsert`.

Response example:
```json
{
  "type": "launcher.template.list",
  "corr_id": "abc123",
  "ok": true,
  "templates": [
    {
      "template_id": "ssh-prod",
      "name": "SSH Production",
      "launcher": {
        "id": "ssh-prod",
        "name": "SSH Production",
        "description": "Open production SSH session",
        "exec_path": "/bin/zsh",
        "args": ["-lc", "ssh user@host"],
        "cwd": "/Users/you",
        "secret_refs": ["SSH_PASSPHRASE"],
        "trust_policy": "continuous",
        "single_instance": true,
        "enabled": true
      }
    }
  ]
}
```

## Trust/settings persistence

### `trust.config.get`

Response:
```json
{
  "type": "trust.config.get",
  "corr_id": "abc123",
  "ok": true,
  "mode": "background_ttl",
  "background_ttl_secs": 300,
  "office_idle_secs": 60
}
```

### `trust.config.set`

Request:
```json
{
  "type": "trust.config.set",
  "corr_id": "abc123",
  "mode": "office",
  "background_ttl_secs": 300,
  "office_idle_secs": 120
}
```

Response: `ok` + normalized values.

Errors: `invalid_mode`, `invalid_ttl`, `config_write_failed`.

Semantics (locked):
- Apply immediately to in-memory trust config.
- Reevaluate active session on next tick/event under new policy.
- If stricter policy invalidates current state, immediate revoke is allowed.

---

## Rust scope (7d)

Files:
- `apps/agent-macos/src/bridge.rs`
- `apps/agent-macos/src/launcher.rs`
- `apps/agent-macos/src/config.rs` (or new trust config module)
- `apps/agent-macos/src/audit/*` (audit additions only)

Required additions:
1. launcher YAML read/write helpers with atomic write (`write tmp + fsync + rename`).
2. `launcher.upsert` + `launcher.delete` handlers.
3. built-in template provider.
4. trust config get/set persistence at `~/.armadillo/trust.yaml`.
5. audit events:
   - `launcher.upsert`
   - `launcher.delete`
   - `trust.config.set`

---

## macOS scope (7d)

File touch points:
- `AppDelegate.swift`:
  - add `Open Preferences…` menu item
  - own singleton window controller lifecycle
- new Preferences files listed above

Rules:
- no launcher/secrets business logic in `TLSServer.swift`
- all UDS communication through existing passthrough
- Preferences refresh is event-driven only (no timer polling):
  - after successful write operations
  - on trust-state notifications
  - when Preferences window opens/becomes key
- Menubar and Preferences must both refresh from shared UDS sources after writes.

---

## Design direction (locked for 7d)

Theme: dark, minimal, liquid-metal/symbiote-inspired (not fantasy, not neon clutter).

Baseline tokens:
- background: near-black with subtle gradient texture
- cards: matte charcoal with slight depth
- accents:
  - trusted: deep emerald
  - warning/countdown: amber
  - destructive: muted red
- typography: clean geometric sans, stronger hierarchy than current menus

Motion:
- restrained transitions (tab switch, status transitions, subtle pulse in diagnostics)
- avoid noisy micro-animations

---

## Out of scope (still deferred)

- 7c encrypted volume/temp-file system
- full repo rename/hard cleanup (8b)
- TLS on-demand architecture switch (8b)

---

## Implementation sequence

1. Preferences shell + menu entry + singleton window lifecycle
2. Diagnostics tab (read-only, reuse existing contracts)
3. Secrets tab (reuse 7b contracts)
4. Launcher CRUD backend (`launcher.upsert/delete`) + Launchers tab
5. Trust config get/set backend + Settings tab
6. Template system + launcher creation flow
7. Audit additions + error mapping polish
8. Full verification matrix

---

## Verification matrix

Automated:
- `cargo test --bin agent-macos launcher::tests -- --nocapture`
- new tests for `launcher.upsert/delete` and trust config bounds
- `xcodebuild ... ArmadilloTLS ... build`

Manual:
1. Open Preferences from menubar; reopen focuses same window.
2. Add launcher from template, save, run from menubar while trusted.
3. Invalid launcher field shows inline error and no write.
4. Add/update/delete secret from Secrets tab with trust gating.
5. Change trust mode/timers in Settings tab and verify reflected in menubar diagnostics.
6. Diagnostics tab reflects live trust state transitions (`granted`, `signal_lost`, `revoked`).

Acceptance:
- no YAML editing needed for standard workflows
- menubar remains action-oriented and uncluttered
- write/delete dangerous operations remain trust-gated

---

## Risks and mitigations

1. **Config corruption on write**
- Mitigation: atomic writes + backup snapshot (`launchers.yaml.bak`) before commit.

2. **UI/agent state drift**
- Mitigation: always refresh after write ops and on trust-state notifications.

3. **Over-complex first UI iteration**
- Mitigation: ship v1 tab MVP first (functional completeness), then visual polish pass within 7d.

---

## 2026-03-11 Addendum: Offline Revoke Behavior (Watchdog)

Problem:
- When iOS backgrounds with data link unavailable, explicit control-plane messages (`trust.revoke` / `trust.signal_lost`) may not arrive.
- Relying only on BLE disconnect callbacks creates variable lag before mac transitions to lost/revoke paths.

Decision:
- Add a mac-side presence watchdog in `BLETrustCentral`.
- Mechanism: periodic keepalive challenge while signal is present.
- If proof does not arrive within timeout window, synthesize `trust.signal_lost` and reset/rescan BLE central.

Contract:
- `strict`: synthesized `signal_lost` triggers immediate revoke.
- `background_ttl`: synthesized `signal_lost` starts TTL immediately.
- `office`: synthesized `signal_lost` enters lost-signal path; office idle policy governs revoke.

Defaults:
- `ARM_TRUST_PRESENCE_TIMEOUT_SECS` default `12`, clamped to `[5, 60]`.

Notes:
- This is fail-closed behavior for offline/unstable links.
- Product mode updates still remain hot-applied via `trust.config.set` (no restart required).
- User-facing expectation: in offline/data-down cases, trust transition can take about the watchdog interval (default ~12s) before mac marks signal lost and applies mode policy.
