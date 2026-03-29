# Phase 7d UI/UX Execution Plan (Locked)

Status: Draft for implementation
Owner: Codex
Date: 2026-03-12
Depends on: Phase 7a, 7b, 8a, 8b-slice1/2

---

## 1) Goal

Make SymbiAuth feel operator-grade and self-explanatory while preserving trust safety.

Success means:
- A first-time user can pair, start session, run a launcher, and understand trust state without docs.
- Menubar is fast runtime control.
- Preferences is complete configuration control.
- iOS is a clear trust/session companion.

---

## 2) Product IA (Locked)

### macOS Menubar (runtime surface)
Use for immediate operational actions only:
- Trust status + mode + connection hint
- Trusted Actions (run launchers)
- End Session
- Show Pairing QR
- Settings > Open Preferences

Do not place complex forms or multi-step config flows in menubar.

### macOS Preferences (configuration surface)
Single window, single instance, tabs:
- Diagnostics
- Launchers
- Secrets
- Settings

### iOS App (companion surface)
- Hub: connection/trust snapshot + action entry
- Session: active session state + end action
- Settings: advanced toggles and maintenance

---

## 3) UX Principles (Locked)

1. Explain the system in the UI, not in logs.
2. Every field must have a visible label and helper text.
3. Errors must be actionable and local to the failed control.
4. Dangerous actions require explicit confirmation.
5. Status language must be stable across macOS and iOS.
6. Minimize mode confusion (strict/background_ttl/office must be obvious).

---

## 4) Canonical Terminology + Copy Contract

Use exactly these labels everywhere:

Trust states:
- Trusted
- Locked
- Grace Period
- Reconnecting

Connection states:
- Connected
- Reconnecting
- Offline

Mode labels:
- Strict
- Background TTL
- Office

Launcher field labels:
- Launcher ID
- Display Name
- Description
- Command
- Arguments
- Working Directory
- Required Secrets
- Trust Policy
- Single Instance
- Enabled

Secret labels:
- Secret Name
- Secret Value
- Availability
- Used By

Prohibited copy:
- raw internal error keys as primary user-facing message (`keychain_write_failed` can appear only in details)
- ambiguous labels like `id`, `cwd`, `args` without plain-language context

---

## 5) macOS UX Changes

### 5.1 Menubar refinements

Keep concise and readable:
- Header row: app name + trust badge icon
- State row: `Trusted • Phone connected • Office mode`
- Divider
- Trusted Actions section
- Divider
- End Session (visible only when trusted)
- Show Pairing QR
- Settings submenu (Open Preferences first)
- Quit

Rules:
- If locked, trusted actions still listed but disabled with reason in tooltip/status line.
- Do not spam status text with diagnostics details.

### 5.2 Preferences: Diagnostics tab

Current strengths preserved, add:
- Last proof age (humanized)
- Presence timeout value (for offline expectations)
- Simple explanation string: `Offline revoke may take up to ~12s` (from watchdog)

### 5.3 Preferences: Launchers tab

Fix current ambiguity from screenshots:
- Convert raw stacked inputs into labeled form rows.
- Each field gets one-line helper text.
- Trust policy control uses segmented buttons with definitions:
  - Continuous: stops on revoke
  - Start only: keeps running after revoke

Validation:
- `Launcher ID`: lowercase kebab-case suggested, uniqueness checked
- `Command`: required absolute path or shell path
- `Arguments`: parse preview + syntax hint
- `Working Directory`: must exist or show warning before save

Action row:
- New
- Save
- Run Now
- Delete

Feedback:
- success inline text near action row
- errors inline under specific field + top summary banner

### 5.4 Preferences: Secrets tab

Fix status clarity:
- Show per-secret badge: `Available` / `Missing` / `Access denied` / `Backend disabled`
- Replace raw backend error text in list row with plain message + optional `Details` disclosure.

Behavior:
- Save/Add/Delete/Test trust-gated with explicit reason when blocked.
- If delete impacts launchers, confirmation modal lists impacted launcher IDs.

### 5.5 Preferences: Settings tab

Implement now (replace placeholder):
- Trust Mode selector
- Background TTL seconds
- Office idle seconds
- Presence timeout seconds (watchdog)

Rules:
- Numeric fields clamp to accepted ranges and show range next to input.
- Saving trust config applies immediately and updates UI state strip.
- If active session mode changes, show info callout:
  - `New mode applies immediately to current trust controller.`

---

## 6) iOS UX Changes

### 6.1 Hub

Primary purpose:
- active Mac
- data connection state
- trust session entry

Rules:
- Keep Start Session highly visible.
- Keep settings access obvious but secondary.
- Avoid operational duplication from old screens.

### 6.2 Session screen

Must show:
- Trust status (`Active/Locked/Grace Period`)
- Mode (live from mac trust mode)
- Last proof age
- Connection hint (`Data: Connected/Reconnecting/Offline`)

Behavior:
- End Session is primary destructive action with confirm when needed.

### 6.3 iOS settings

Keep advanced ops here:
- Forget paired endpoint
- Dev-only toggles (if enabled)
- Diagnostics/copy logs (optional, non-primary)

---

## 7) Visual Direction (Locked)

Theme: dark, precise, premium, slightly industrial.

Tokens:
- Background: deep graphite + subtle blue gradient texture.
- Surfaces: layered panels with low-contrast borders.
- Positive: emerald/green.
- Warning: amber.
- Critical: red.
- Primary action: electric blue.

Typography:
- macOS: keep SF but enforce hierarchy and spacing rigor.
- iOS: same hierarchy language for parity.

Motion:
- only meaningful transitions (tab switch, status change)
- no decorative micro-animations

---

## 8) State + Error UX Matrix

### Trust/mode behavior copy
- strict + background: `Locked immediately`
- background_ttl + background: `Grace Period started`
- office + signal lost: `Office idle window active`

### Secret errors mapping
- `trust_not_active` -> `Start a trust session to modify secrets.`
- `secret_not_found` -> `Secret not found in Keychain.`
- `keychain_access_denied` -> `Keychain access denied. Check macOS prompt/permissions.`
- `keychain_backend_disabled` -> `Keychain backend disabled in this build.`
- `invalid_secret_name` -> `Secret name must be 1–128 chars: A-Z, a-z, 0-9, _, -, .`
- `value_too_large` -> `Secret value exceeds 8KB limit.`

### Launcher errors mapping
- `trust_not_active` -> `Start a trust session to run this launcher.`
- `already_running` -> `Launcher already running (single instance enabled).`
- `config_write_failed` -> `Could not save launcher config.`
- `invalid_launcher` -> `Some launcher fields are invalid. Review highlighted fields.`

---

## 9) Delivery Slices

### Slice A — IA + Labeling + Copy (no behavior changes)
- Menubar text cleanup
- Launchers/Secrets labeled forms + helper copy
- Remove ambiguous labels/messages

Acceptance:
- zero unlabeled launcher/secret input fields
- no raw backend key as primary message

### Slice B — Settings tab + trust config controls
- Implement trust config UI in Preferences
- Immediate apply + feedback
- Range validation and callouts

Acceptance:
- change mode/timers in Preferences and observe effect without app restart

### Slice C — Error/state polish + empty states
- Consistent banners/toasts/inline messages
- empty states for no launchers/no secrets/no active session
- final visual polish and spacing pass

Acceptance:
- first-time flow understandable with no docs

### Slice D — iOS parity polish
- align trust/status language with mac
- tighten Hub/Session UX states

Acceptance:
- identical trust vocabulary on iOS and mac

---

## 10) Verification Matrix (Device)

1. Untrusted, open menubar: launchers visible but blocked reason clear.
2. Trusted, run launcher from menubar and Preferences, running state syncs.
3. Save launcher with invalid field: field-level error shown.
4. Add secret untrusted: blocked with trust message.
5. Add secret trusted: success + availability badge updates.
6. Delete in-use secret: impact confirmation lists launcher(s).
7. Change mode strict/background_ttl/office in Preferences while app live.
8. Background iOS in each mode; observe expected trust transition copy.
9. Offline revoke path shows expected bounded delay message (~12s).
10. iOS and mac show same mode label and trust state wording.

---

## 11) Non-goals in this plan

- Phase 7c file-backed secret transport
- large repo/module deletions (8b heavy cleanup)
- redesign of deferred modules (vault/widget/nmhost)

---

## 12) Risks + Mitigations

Risk: copy inconsistency across surfaces.
Mitigation: strict terminology contract above + shared constants where practical.

Risk: trust mode confusion if env vars still override runtime config.
Mitigation: define precedence in code and surface active source in diagnostics.

Risk: regressions in launch flow while touching UI.
Mitigation: no transport changes in Slice A; run matrix each slice.

---

## 13) Execution Order (Next)

1. Implement Slice A (mac only) and ship as first reviewable PR.
2. Implement Slice B (mac settings behavior) + live test.
3. Implement Slice C (mac polish).
4. Implement Slice D (iOS parity).
5. Update `docs/Progress/Logs.md` and `docs/Progress/lessons.md` at each slice closure.

