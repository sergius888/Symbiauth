# SymbiAuth v1 Pivot — Master Execution Plan

> **This is the single guide.** Each step links to the detailed doc that governs it.
> Check off steps as you go. Do NOT skip ahead — later steps depend on earlier ones.

---

## Document Index

| Doc | What it's for |
|-----|---------------|
| [v1_product_spec_states.md](docs/Pivot_docs/v1_product_spec_states.md) | **Source of truth** — trust modes, state machine, UDS protocol |
| [PIVOT_IMPLEMENTATION_PLAN.md](docs/Pivot_docs/PIVOT_IMPLEMENTATION_PLAN.md) | What to delete/create, architecture, phases |
| [pre_coding_readiness.md](docs/Pivot_docs/pre_coding_readiness.md) | Gotchas, socket paths, permissions, dev workflow |
| [ios_ui_architecture.md](docs/Pivot_docs/ios_ui_architecture.md) | iOS screen map, navigation, file structure |
| [V1_direction.md](docs/Pivot_docs/V1_direction.md) | iPhone state machine + logs (partially superseded) |
| [V1_Product_spec.md](docs/Pivot_docs/V1_Product_spec.md) | Features: launchers, vault, cleanup, use cases (partially superseded) |
| [after_pivot_stable_next.md](docs/Pivot_docs/after_pivot_stable_next.md) | Post-pivot sequencing: cleanup → rename → repo → UI |

---

## Phase 0: Pre-Flight (do once, before any code)

- [ ] **0.1** Verify UDS socket path matches — **confirmed: both use `~/.armadillo/a.sock` ✅**
  - Rust already prints: `[agent] using socket path=<...>` on startup
  - **Add** a matching log in Swift at connect time: `[mac] uds.connect path=<...>` — you WILL forget later and waste 2 hours when something reconnects to an old path
- [ ] **0.2** Create `run-agent.sh` and `run-tls.sh` dev scripts — see [pre_coding_readiness.md §3](docs/Pivot_docs/pre_coding_readiness.md)
- [ ] **0.3** Add `NSBluetoothAlwaysUsageDescription` to macOS `ArmadilloTLS` Info.plist
- [ ] **0.4** Add `NSBluetoothAlwaysUsageDescription` to iOS Info.plist (if missing)
- [ ] **0.5** Verify `k_ble` derivation produces same key on both sides (run existing test or write one)

---

## Phase 1: Rust Trust State Machine + UDS Messages

**Ref:** [PIVOT_IMPLEMENTATION_PLAN.md §2D + §3 Phase 1](docs/Pivot_docs/PIVOT_IMPLEMENTATION_PLAN.md) · [v1_product_spec_states.md §State Machine](docs/Pivot_docs/v1_product_spec_states.md)

- [ ] **1.1** Create `apps/agent-macos/src/trust.rs` with:
  - State variables: `mode`, `trust`, `signal`, `deadline`, `last_user_activity`, `revoking_started_at`
  - Events: `E_TRUST_GRANTED`, `E_SIGNAL_LOST`, `E_SIGNAL_PRESENT`, `E_TICK`, `E_USER_END_SESSION`, `E_MAC_SLEEP`
  - Outputs: `A_REVOKE_AND_CLEANUP`, `A_PUSH_EVENT`, `A_NOTIFY_*`
  - All 3 modes: Strict, BackgroundTTL, OfficeMode
- [ ] **1.2** Define UDS message structs in Rust (serde):
  - `trust.verify_request` / `trust.verify_response`
  - `trust.signal_lost` / `trust.signal_present`
  - `trust.revoke` / `trust.revoke_ack`
  - `trust.event` (push)
  - `trust.status` / `trust.status_response`
- [ ] **1.3** Add `ARM_TRUST_V1=1` feature flag. In `bridge.rs`:
  - If set → route trust messages to `trust.rs`, gate with `trust.is_trusted()`
  - If unset → old proximity behavior (nothing breaks)
- [ ] **1.3b** Create **one single gate function** `is_sensitive_allowed()` in `bridge.rs` that switches source based on feature flag. **Replace ALL existing gating calls** (`prox.is_unlocked()`, TLS presence checks) to go through this one function. This prevents the "half-migrated" state where some endpoints are gated by trust and others by proximity.
- [ ] **1.4** Implement 1s tick loop for deadline/idle/cleanup checks
- [ ] **1.5** Implement `trust.event` push over UDS
- [ ] **1.6** Test with manual JSON over UDS (pipe a `trust.verify_request` in, expect `trust.verify_response` back)

> **Milestone:** Rust trust state machine works in isolation. Can be tested without BLE or Swift.

---

## Phase 2: iOS GATT Peripheral

**Ref:** [PIVOT_IMPLEMENTATION_PLAN.md §2A + §3 Phase 2](docs/Pivot_docs/PIVOT_IMPLEMENTATION_PLAN.md) · [V1_direction.md §iPhone State Machine](docs/Pivot_docs/V1_direction.md)

- [ ] **2.1** Delete `Features/BLE/BLEAdvertiser.swift` (old iBeacon)
- [ ] **2.2** Create `Features/BLE/BLETrustServer.swift`:
  - `CBPeripheralManager` with `SYMBIAUTH_V1_SERVICE_UUID`
  - Challenge characteristic (Write, without response)
  - Proof characteristic (**Notify + Read**) — Notify is the main path, Read is the recovery path when notify subscription timing is flaky (and it *will* be flaky during early testing)
  - HMAC computation using `k_ble`
- [ ] **2.3** Wire Face ID: "Start Session" button → Face ID → start advertising
- [ ] **2.4** Stop advertising on: app background, app inactive, user taps "End Session"
- [ ] **2.5** Implement iPhone state machine: `IOS_IDLE` → `IOS_AUTHED_FOREGROUND` → `IOS_REVOKED`
- [ ] **2.6** Add structured logs per [V1_direction.md §iPhone Logs](docs/Pivot_docs/V1_direction.md)
- [ ] **2.7** Test: verify iOS advertises service, characteristics are discoverable (use nRF Connect or LightBlue)

> **Milestone:** iPhone GATT server works. Challenge/Proof characteristics discoverable + responsive.

---

## Phase 3: macOS Swift BLE Central

**Ref:** [PIVOT_IMPLEMENTATION_PLAN.md §2B + §3 Phase 3](docs/Pivot_docs/PIVOT_IMPLEMENTATION_PLAN.md)

- [ ] **3.1** Create `ArmadilloTLS/BLE/BLETrustCentral.swift`:
  - `CBCentralManager` scanning for `SYMBIAUTH_V1_SERVICE_UUID`
  - Subscribe to Proof (Notify) **before** writing Challenge
  - Generate nonce, write to Challenge, receive proof via notification
  - **Add `connectInFlight` + `challengeInFlight` bools** — ignore new discoveries while connected/handshaking. This prevents double-connect / double-challenge storms (same bug class as Bonjour had)
  - **Generate and log a `ble_session_corr_id`** at each step for tracing
- [ ] **3.2** Forward proof to Rust via `trust.verify_request` over existing `UnixSocketBridge`
- [ ] **3.3** Implement mandatory `trust.signal_lost` / `trust.signal_present` on BLE link state changes
- [ ] **3.4** Listen for `trust.event` pushes from Rust
- [ ] **3.5** Add BLE state logging (bluetooth state transitions, scan start, didDiscover, connect attempts) — **explicit logs at every CB callback**, not just errors
- [ ] **3.6** Test end-to-end: iPhone ↔ BLE ↔ Mac Swift ↔ UDS ↔ Rust → `trust.verify_response`

> **Milestone:** Full pipeline works. iPhone proof reaches Rust, Rust replies with grant/deny.

---

## Phase 4: Integration + Vertical Slice

**Goal:** Prove the entire flow works reliably before adding UI polish.

- [ ] **4.1** Real `k_ble` derivation on both sides (remove any hardcoded test keys)
- [ ] **4.2** Real HMAC verification in Rust verifier (replace stubbed `ok:true`)
- [ ] **4.3** Test Strict mode: disconnect iPhone → trust revoked immediately
- [ ] **4.4** Test Background TTL: disconnect → countdown → revoke on expiry
  - **Semantic decision (locked in):** during countdown, session **remains trusted** — no friction. Blocking new secret actions while signal-lost is an optional policy flag for later, not v1.
- [ ] **4.5** Test Office mode: disconnect → trust holds → revoke on idle/sleep
- [ ] **4.6** Test re-grant: signal returns → Face ID → new proof → deadline cancelled
- [ ] **4.7** Test cleanup timeout: simulate slow cleanup → force to Locked
- [ ] **4.8** Delete `ble_scanner.rs` + `ble_global.rs` (old btleplug scanner) — do this **only after** Modes A/B/C pass end-to-end at least once

> **Milestone:** "GATT challenge-response works + TTL revoke triggers cleanup reliably."
> This is the trigger for post-pivot cleanup per [after_pivot_stable_next.md](docs/Pivot_docs/after_pivot_stable_next.md).

---

## Phase 5: macOS UI (Menubar)

**Ref:** [PIVOT_IMPLEMENTATION_PLAN.md §3 Phase 4](docs/Pivot_docs/PIVOT_IMPLEMENTATION_PLAN.md)

- [ ] **5.1** Update menubar to show: Locked / Trusted / Signal Lost + mode context
- [ ] **5.2** Local countdown timer from `deadline_ms` / `trust_until_ms` push events
- [ ] **5.3** Trust mode selector in menubar (Strict / Background TTL / Office)
- [ ] **5.4** All timings user-configurable
- [ ] **5.5** System notifications on signal loss / revoke

> **Milestone:** Mac menubar reflects trust state accurately. User can control modes.

---

## Phase 6: iOS UI Restructure

**Ref:** [ios_ui_architecture.md](docs/Pivot_docs/ios_ui_architecture.md)

- [ ] **6.1** Split `ContentView.swift` → `HubView.swift` + `SessionView.swift`
- [ ] **6.2** Move all dev buttons to `DeveloperView.swift` (hidden by default)
- [ ] **6.3** Build Session Screen with status badge + mode indicator + animated visual area
- [ ] **6.4** Implement `NavigationStack` + `fullScreenCover` for Session
- [ ] **6.5** Fix naming: "Disconnect" → back nav, "Armadillo Mobile" → "SymbiAuth", remove "MVP Testing App"
- [ ] **6.6** Dedup paired Macs in `PairedMacStore`

> **Milestone:** Clean iOS UI with clear Hub → Session → Settings flow. Dev tools hidden.

---

## Phase 7: Trusted Actions (Launchers, Secrets, Cleanup)

**Refs:** [phase7a_launcher_implementation.md](docs/Pivot_docs/phase7a_launcher_implementation.md) (locked spec) · [V1_Product_spec.md §Features](docs/Pivot_docs/V1_Product_spec.md) (partially superseded)

### Phase 7a: Minimal Trusted Launcher System ✅ COMPLETE

- [x] **7a.1** `launcher.rs` — structs, YAML config loader, config validation (exec_path absolute+exists, cwd valid, id unique)
- [x] **7a.2** `SecretResolver` trait + `KeychainSecretResolver` (macOS Keychain via `security-framework`)
- [x] **7a.3** `spawn_launcher()` — process spawn with `setsid()`, pgid tracking, `single_instance` enforcement
- [x] **7a.4** `cleanup_on_revoke(manual, audit)` — SIGTERM → 500ms grace → SIGKILL (manual) / SIGTERM → 3s → SIGKILL (TTL/idle)
- [x] **7a.5** `trust_policy: continuous | start_only` — continuous killed on revoke, start_only preserved
- [x] **7a.6** `bridge.rs` — `launcher.list` + `launcher.run` UDS handlers, trust gate, config reload on both
- [x] **7a.7** Revoke hooks in 3 places: manual `trust.revoke`, `signal_lost`, tick timer
- [x] **7a.8** Audit wiring — `log_launcher_event()` for run/cleanup events
- [x] **7a.9** Swift menubar — Trusted Actions section, `●` running indicator, End Session, Settings submenu
- [x] **7a.10** Build + test + device pass verified (9/9 tests passing, xcodebuild succeeds)

### Phase 7b: Secrets Management Layer ✅ COMPLETE

- [x] **7b.1** UDS API: `secret.list`, `secret.set`, `secret.delete`, `secret.test` message handlers in `bridge.rs`
- [x] **7b.2** Rust backend: `secrets.rs` with single resolver boundary, validation, Keychain CRUD
- [x] **7b.3** Menubar surface: Secrets submenu under Settings with ✅/❌ status, "Add Secret...", per-secret "Delete..."
- [x] **7b.4** Error UX: granular error taxonomy (7 distinct errors), input validation, trust gate on writes

> **Not in scope:** custom encrypted store, import/export, rotation, sharing across Macs.

### Phase 7c: Mounted Volume + Temp-File Injection — DEFERRED

> **Deferred** until users request file-based secret workflows (SSH private keys, cloud JSON keyfiles).
> Schema hooks exist from 7a/7b direction. If pulled forward, start with 7c-lite (temp_env_file only, no mount system).

- [ ] **7c.1** Extend launcher schema with `mount_refs` and `temp_file_refs` fields
- [ ] **7c.2** Encrypted volume mount on trust grant, unmount on revoke
- [ ] **7c.3** Temp file injection (write secrets to temp files, inject path as env var, delete on revoke)
- [ ] **7c.4** Cleanup integration: volumes + temp files cleaned alongside process kills in `cleanup_on_revoke`

### Phase 7d: Preferences Window (Option A — menubar-launched) ✅ COMPLETE

> Delivered: Preferences window with 4 tabs, new UDS contracts, reliability hardening, device-validated across all trust modes.

- [x] **7d.1** Preferences shell + singleton window lifecycle + `Open Preferences…` menu item
- [x] **7d.2** Diagnostics tab — trust state, mode, deadlines, launcher/secret counters (event-driven refresh)
- [x] **7d.3** Secrets tab — list, add, update, delete, test (reuses 7b contracts, trust-gated writes)
- [x] **7d.4** Launchers tab — CRUD editor, run-now, templates (`launcher.upsert/delete/template.list`)
- [x] **7d.5** Settings tab — trust mode picker, TTL/idle timers (`trust.config.get/set`, immediate apply + persist)
- [x] **7d.6** Atomic config writes (`tmp + fsync + rename`) for launcher persistence
- [x] **7d.7** 3 built-in templates (SSH, trading bot, tx-signer)
- [x] **7d.8** Reliability hardening: offline watchdog, BLE central reset on revoke, mode-aware iOS background signaling
- [x] **7d.9** Canonical dev startup script (`scripts/dev/run_phase7_stack.sh`)

> **Milestone reached:** User can configure launchers, secrets, and trust settings from Preferences window. No YAML editing required for standard workflows.

---

## Phase 8a: Targeted Hygiene (before 7d) ✅ COMPLETE

> Scoped conservatively after dependency audit. Only `bridge_prox_gate.rs` was truly dead.

- [x] **8a.1** Deleted dead code: `bridge_prox_gate.rs` (zero references)
- [x] **8a.2** Stabilized `.gitignore` and build artifacts
- [x] **8a.3** Fixed warnings in touched files (`bridge.rs`, `writer.rs`)
- [x] **8a.4** Secrets scan clean
- [x] Explicitly deferred `proximity.rs`, `ble_scanner.rs`, `ble_global.rs`, `btleplug` to 8b

---

## Phase 8b: Full Cleanup (after 7d stabilizes)

> **Scope:** Broader renames, repo hygiene, deep warning pass. Only after 7d UI contracts are locked.

- [ ] **8b.1** Rename: dreiglasser/armadillo → symbiauth (bundle IDs, keychain groups, entitlements, labels)
- [ ] **8b.2** Deep compiler warning cleanup across all files
- [ ] **8b.3** Repo hygiene: clean history consideration, stale branches, README
- [ ] **8b.4** Switch TLS to on-demand only (pairing mode, not always-on)
- [ ] **8b.5** UI/UX polish pass

---

## Phase 9: Future (v1.1+)

Not blocking v1. Tracked in [random-ideas-forfuture.md](docs/Pivot_docs/random-ideas-forfuture.md).

- [ ] Ferrofluid/symbiotic animation (Metal shader / SceneKit)
- [ ] Onboarding flow for first-time users
- [ ] Wi-Fi sharing shortcut for pairing
- [ ] Widget trust status
- [ ] Max session duration (optional hard TTL)
- [ ] Ephemeral file injection (Mode B2)
- [ ] Screen-share safe mode launcher


### important note: You are the owner of the implementation and the UI design, you decide if we should focus on UI quality at this phase or later, but in the end when app is ready we should not have cheap looking UI with cheap emoji style. This is just an FYI and treat it as a suggestion. Also I will mention that in the end the theme of this app should be kind of darker, and its inspired by the black oilish substance like symbiote that we know from the comics, not alien like, but more like a liquid metal, or oil, you know what I mean. And this should be beautifuly blended with the rest of UI. Avoid fantasy looking style, rather slightly cyber-punk like but with the symbiote theme. A simpler representation of this symbiote for you is think about a ferrofluid, but in a liquid metal form, and with the ability to change its shape and form, and to blend with the rest of UI. This is something to remember from now anytime we work on the UI.