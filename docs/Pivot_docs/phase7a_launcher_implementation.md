# Phase 7a: Minimal Trusted Launcher System — Implementation Spec

> **Status:** Approved, ready for implementation (final revision — engineer-reviewed)
> **Scope:** Rust agent + macOS menubar only. No iOS changes.
> **Depends on:** Phase 1–6 (trust state machine, BLE challenge-response, menubar trust display — all complete)
> **Primary demo narrative:** Prod SSH + signer security-first story (code is generic, but demo/docs optimize for this vertical)

---

## Why you're reading this

Right now, after Phase 6, the Mac knows when trust is active — but **nothing happens**. The menubar shows a green icon. That's it.

Launchers are what make trust **mean something**. A launcher is a **saved shortcut to a sensitive command** — a bot, an SSH session, a deploy script — that the Mac will only run when trust is active, with secrets injected from macOS Keychain, and automatic cleanup when trust ends.

### The user story

**Without SymbiAuth:**
1. User opens terminal, pastes `BINANCE_API_KEY=abc123 ./run_bot.sh`
2. Keys are now in shell history, clipboard, `.env` files
3. Bot keeps running when user walks away. No cleanup.

**With SymbiAuth + Launchers:**
1. User approves trust from iPhone (Face ID)
2. Clicks "Run Freqtrade" in Mac menubar
3. Bot starts with Keychain secrets injected as env vars — never on disk, never in history
4. Trust ends → bot is killed, secrets gone

**That's the product.** The launcher bridges "trust is active" and "something useful happens on the Mac."

---

## Phase 7 full roadmap (what comes after 7a)

> **Read this first.** You're building 7a, but your code must not block 7b–7d. Design with these in mind.

| Phase | What it adds | Impact on 7a code |
|-------|-------------|-------------------|
| **7a (this)** | Launcher config + Keychain secrets + env injection + process group tracking + menubar display + audit logging | — |
| **7b** | Secrets management — possibly a helper UI or Keychain wrapper, potentially a custom encrypted store later | `secret_refs` resolution should be behind a trait/abstraction so the backend can change from Keychain to custom store without touching launcher logic |
| **7c** | Mounted encrypted volumes + temp file injection | Launcher struct will gain `mount_volume: bool` and `temp_files: Vec<TempFileSpec>` fields. Use `#[serde(default)]` on all optional fields now so new fields don't break existing configs |
| **7d** | Full Mac app window with tabs: Overview, Launchers, Secrets, Settings | Menubar stays as the quick-action surface. Full app becomes the configuration surface. `launcher.list` and `launcher.run` UDS messages will be reused by the full app UI — design them to be complete enough for a GUI, not just a menubar |

### What this means for your code

1. **Launcher struct:** Use `#[serde(default)]` on every optional field. New fields will be added in 7c/7d without breaking existing YAML configs.
2. **Secret resolution:** Put it behind a function/trait boundary. Don't scatter Keychain calls through launcher code. One `resolve_secrets(refs) -> Result<HashMap<String, String>>` function that can be swapped later.
3. **UDS payloads:** Make `launcher.list` response rich enough for a GUI, not just a menubar. Include all metadata.
4. **Menubar items:** The menubar UI in 7a will eventually coexist with a full app window in 7d. Don't put launcher management in the menubar — it's just for running.

---

## Architecture context

```
┌──────────────┐     BLE      ┌────────────────┐
│  iPhone app  │◄────────────►│  macOS agent    │
│  (Face ID +  │   trust      │  (Rust binary)  │
│   BLE proof) │   grant      │                 │
└──────────────┘              │  trust.rs       │  ← existing, gates launcher.run
                              │  launcher.rs    │  ← NEW: this phase
                              │  bridge.rs      │  ← existing, add UDS handlers
                              └───────┬─────────┘
                                      │ UDS (Unix socket ~/.armadillo/a.sock)
                              ┌───────┴─────────┐
                              │  TLS terminator  │
                              │  (Swift app)     │
                              │  AppDelegate.swift│ ← menubar renders launchers
                              │  UnixSocketBridge │ ← existing UDS client
                              └──────────────────┘
```

### Key existing code you'll touch

| File | What it does | Lines |
|------|-------------|-------|
| `apps/agent-macos/src/trust.rs` | `TrustController` with `is_trusted()`, `grant()`, `revoke()`, `tick()` | 310 |
| `apps/agent-macos/src/bridge.rs` | UDS message router. Trust messages at ~line 1532. Match block for all message types. | 2475 |
| `apps/agent-macos/src/main.rs` | Agent entrypoint. Wires bridge, trust, vault, proximity. | 443 |
| `apps/agent-macos/Cargo.toml` | Dependencies. Already has `serde`, `serde_yaml`, `uuid`, `tokio`. | — |
| `apps/tls-terminator-macos/ArmadilloTLS/AppDelegate.swift` | Menubar. `buildStatusMenu()` at line 154. `onTrustStateChanged()` refreshes menu. | 579 |
| `apps/tls-terminator-macos/ArmadilloTLS/UnixSocketBridge.swift` | UDS client. `send(json:completion:)` for request-response. | 554 |
| `apps/tls-terminator-macos/ArmadilloTLS/TLSServer.swift` | Owns the `socketBridge`. **Do NOT put launcher logic here** — TLS is becoming pairing-only. | — |

### Critical architectural rule

> **No launcher logic in `TLSServer.swift`.** All launcher UDS calls go through `AppDelegate` → `UnixSocketBridge`. If `AppDelegate` needs bridge access, expose a generic `sendToAgent(json:completion:)` passthrough on `TLSServer` that delegates to its `socketBridge`. No launcher-specific methods in TLSServer.

---

## UI/UX Specification — Mac Menubar

The menubar is the **only UI surface for Phase 7a**. No full app window yet.

### Current menubar structure (what exists today)

```
┌─────────────────────────────────────┐
│ Armadillo TLS                       │  ← status header
│ ─────────────────────────────────── │
│ Fingerprint: a1b2c3d4e5f6g7h8      │  ← debug info
│ Port: 8443                          │
│ State: Trusted                      │  ← trust state
│ Mode: Office                        │
│ iPhone: ...3A7B                     │
│ ─────────────────────────────────── │
│ Show Pairing QR Code                │
│ ─────────────────────────────────── │
│ Install/Repair Browser Bridge       │  ← legacy utilities
│ Remove Browser Bridge Manifest      │
│ ─────────────────────────────────── │
│ Quit                                │
└─────────────────────────────────────┘
```

### Target menubar structure (after Phase 7a)

```
LOCKED STATE:
┌─────────────────────────────────────┐
│ SymbiAuth                           │
│ 🔒 Locked                          │
│ Start a session from your iPhone    │
│ ─────────────────────────────────── │
│ Trusted Actions                     │  ← section header
│   Run Freqtrade              (dim)  │  ← greyed out, not clickable
│   SSH Production             (dim)  │
│   Start Signer               (dim)  │
│ ─────────────────────────────────── │
│ Show Pairing QR Code                │
│ Settings ▸                          │  ← submenu with debug/dev stuff
│ Quit                                │
└─────────────────────────────────────┘

TRUSTED STATE:
┌─────────────────────────────────────┐
│ SymbiAuth                           │
│ ✅ Trusted                          │
│ Phone connected · Office mode       │
│ ─────────────────────────────────── │
│ Trusted Actions                     │
│   Run Freqtrade              ▶      │  ← clickable, runs launcher
│   ● SSH Production           ▶      │  ← ● = currently running
│   Start Signer               ▶      │
│ ─────────────────────────────────── │
│ End Session                         │
│ Settings ▸                          │
│ Quit                                │
└─────────────────────────────────────┘

SIGNAL LOST / COUNTDOWN STATE:
┌─────────────────────────────────────┐
│ SymbiAuth                           │
│ ⏱️ Signal lost                      │
│ Revoking in 4:32                    │
│ ─────────────────────────────────── │
│ Trusted Actions                     │
│   Run Freqtrade              ▶      │  ← still enabled (trust active)
│   ● SSH Production           ▶      │
│ ─────────────────────────────────── │
│ End Session                         │
│ Settings ▸                          │
│ Quit                                │
└─────────────────────────────────────┘
```

### UI Rules

1. **Launcher items show the `name` as title and `description` as tooltip.** Keep the menu clean — don't show descriptions inline unless Apple's NSMenuItem supports subtitles natively (it does via `subtitle` property on macOS 14+; use it if deployment target allows, otherwise tooltip).

2. **Enabled/disabled follows trust state, not cached data.** The `onTrustStateChanged()` callback already rebuilds the menu. Use the current trust visual state to determine enabled/disabled. Never cache trust state separately.

3. **Running launchers get a `●` prefix** on their name. This tells the user "this is still alive." Later phases may add a submenu with "Stop" action.

4. **Move debug info into a Settings submenu.** Fingerprint, port, phone suffix, browser bridge tools — these are not daily-use items. Move them under `Settings ▸` to make room for launchers. This is a housekeeping change within 7a.

5. **"End Session"** is a direct trust revoke action. It should call the existing trust revoke flow. Note: this should also trigger `cleanup_on_revoke()` through the normal revoke event path.

### What the menubar should NOT do (save for 7d)

- No "Add Launcher" in the menubar — that's for the full app window
- No "Edit Launcher" — configure via YAML for now
- No "Manage Secrets" — Keychain setup is terminal-based for now
- No launcher reordering or categories

---

## 1. Launcher config file

**Path:** `~/.armadillo/launchers.yaml`

```yaml
launchers:
  - id: "bot-freqtrade"
    name: "Run Freqtrade"
    description: "Starts the live trading bot with Binance keys"
    exec_path: "/bin/zsh"
    args: ["-lc", "./run_bot.sh"]
    cwd: "/Users/sergiu/projects/freqtrade"
    secret_refs: ["BINANCE_API_KEY", "BINANCE_API_SECRET"]
    trust_policy: "start_only"    # may continue after trust ends
    single_instance: true          # default: prevent double-launch
    enabled: true

  - id: "ssh-prod"
    name: "SSH Production"
    description: "Opens SSH session to production server"
    exec_path: "/bin/zsh"
    args: ["-lc", "ssh trader@prod-box"]
    cwd: "/Users/sergiu"
    secret_refs: []
    trust_policy: "continuous"    # default: killed when trust ends
    single_instance: true
    enabled: true
```

**Rules:**
- `cwd` must be an absolute path. If `~` is provided, the loader MUST expand to `$HOME` and log the expanded path.
- `secret_refs` are names of macOS Keychain items stored under service `com.symbiauth.secrets`.
- `trust_policy` — either `"continuous"` (default, killed on revoke) or `"start_only"` (trust needed to start, may continue after).
- `single_instance` — default `true`. Prevents launching the same action twice. Returns `already_running` error.
- YAML chosen because `serde_yaml` is already a dependency and matches existing `policy.yaml` pattern.
- Reload config on every `launcher.list` **and** `launcher.run` request — file is <1KB, re-reading is cheap, no file watcher needed.
- Use `#[serde(default)]` on all optional fields for forward compatibility with future phases.

### Config validation (on load)

The loader MUST validate each launcher entry:
1. `exec_path` — must be absolute, must exist, must not be world-writable
2. `cwd` — after `~` expansion, must exist and be a directory
3. `id` — must be non-empty and unique across all launchers
4. `trust_policy` — must be `"continuous"` or `"start_only"` (reject anything else)

Invalid launchers should be logged with a warning and skipped (not crash the agent). The `launcher.list` response only includes valid launchers.

---

## 2. Rust structs

### File: `apps/agent-macos/src/launcher.rs` (NEW)

```rust
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrustPolicy {
    Continuous,  // killed when trust ends (default)
    StartOnly,   // trust needed to start, may continue after
}

impl Default for TrustPolicy {
    fn default() -> Self { TrustPolicy::Continuous }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Launcher {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub exec_path: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub secret_refs: Vec<String>,
    #[serde(default)]
    pub trust_policy: TrustPolicy,
    #[serde(default = "default_true")]
    pub single_instance: bool,
    #[serde(default = "default_true")]
    pub enabled: bool,
    // Future fields (7c): mount_volume, temp_files — will be added with #[serde(default)]
}

fn default_true() -> bool { true }

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LauncherConfig {
    #[serde(default)]
    pub launchers: Vec<Launcher>,
}

#[derive(Debug, Clone)]
pub struct ActiveRun {
    pub run_id: String,
    pub launcher_id: String,
    pub pid: u32,
    pub pgid: i32,              // process GROUP id — after setsid(), pgid == pid
    pub started_at: u64,         // epoch ms
    pub trust_policy: TrustPolicy,
}

pub struct LauncherManager {
    config_path: String,
    launchers: Vec<Launcher>,
    active_runs: Vec<ActiveRun>,
    last_errors: HashMap<String, String>,  // launcher_id -> last error message
}
```

---

## 3. Secret resolution — macOS Keychain

### Locked decision: `security-framework` crate at runtime only

Do NOT shell out to `security find-generic-password`. Use the native Rust crate.

```rust
use security_framework::passwords::get_generic_password;

/// Resolve all secret_refs for a launcher from macOS Keychain.
/// Put this behind a clear function boundary so the backend can change in 7b.
fn resolve_secrets(secret_refs: &[String]) -> Result<HashMap<String, String>, String> {
    let mut resolved = HashMap::new();
    for name in secret_refs {
        let bytes = get_generic_password("com.symbiauth.secrets", name)
            .map_err(|e| format!("secret_not_found:{}: {}", name, e))?;
        let value = String::from_utf8(bytes)
            .map_err(|e| format!("secret '{}' not valid UTF-8: {}", name, e))?;
        resolved.insert(name.clone(), value);
    }
    Ok(resolved)
}
```

### User setup (CLI — for setup instructions only, not runtime)

```bash
# Store a secret
security add-generic-password -s "com.symbiauth.secrets" -a "BINANCE_API_KEY" -w "actual_key_value"

# Verify it exists
security find-generic-password -s "com.symbiauth.secrets" -a "BINANCE_API_KEY" -w
```

### Keychain access prompt

First time the Rust binary reads a Keychain item → macOS shows "Always Allow / Allow / Deny." After "Always Allow," it's silent forever. One-time per secret. Unsigned dev builds may see repeated prompts — codesign for distribution.

---

## 4. Process spawn + process group tracking

This is **core design**, not optional mitigation.

### Why process groups

When a launcher runs `/bin/zsh -lc ./run_bot.sh`, the actual bot is a child of zsh. Killing only the zsh PID leaves the bot running. That makes the cleanup promise fake.

### Spawn pattern

```rust
use std::os::unix::process::CommandExt;
use std::process::Command;
use nix::unistd::Pid;
use nix::sys::signal::{self, Signal};

fn spawn_launcher(launcher: &Launcher, env_vars: HashMap<String, String>) -> Result<ActiveRun, String> {
    let mut cmd = Command::new(&launcher.exec_path);
    cmd.args(&launcher.args);

    if !launcher.cwd.is_empty() {
        cmd.current_dir(&launcher.cwd);
    }

    // Inject secrets as env vars
    for (k, v) in &env_vars {
        cmd.env(k, v);
    }

    // CRITICAL: spawn in new process group so cleanup catches children
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }

    let child = cmd.spawn().map_err(|e| format!("spawn_failed: {}", e))?;
    let pid = child.id();
    let pgid = pid as i32; // after setsid(), pgid == pid

    Ok(ActiveRun {
        run_id: generate_run_id(), // e.g., "r_" + 10 random alphanumeric
        launcher_id: launcher.id.clone(),
        pid,
        pgid,
        started_at: now_epoch_ms(),
        trust_policy: launcher.trust_policy,
    })
}
```

### Cleanup on revoke

Two modes depending on how revoke was triggered:

| Trigger | Behavior |
|---------|----------|
| **Manual "End Session"** | SIGTERM → **500ms** grace → SIGKILL for `continuous` runs. Fast enough to feel immediate, clean enough to avoid unclean shutdown. |
| **TTL/idle timeout** | SIGTERM → **3s** grace → SIGKILL for `continuous` runs. |
| Both | `start_only` runs are **never killed** — only logged. |

```rust
impl LauncherManager {
    /// manual=true for "End Session" (immediate), false for TTL/idle revoke (grace period)
    pub fn cleanup_on_revoke(&mut self, manual: bool, audit: &Option<Arc<AuditWriter>>) {
        let mut cleaned = Vec::new();
        for run in &self.active_runs {
            if run.trust_policy == TrustPolicy::StartOnly {
                info!(event = "launcher.cleanup.skip",
                      run_id = %run.run_id,
                      launcher_id = %run.launcher_id,
                      pid = run.pid,
                      reason = "trust_policy=start_only");
                // Audit log: launcher allowed to continue
                if let Some(aw) = audit {
                    aw.log_launcher_event("cleanup.skip", &run.run_id, &run.launcher_id, run.pid, "start_only");
                }
                continue;
            }

            // Kill entire process group (negative pgid) — always SIGTERM first
            let pgid = Pid::from_raw(-run.pgid);
            match signal::kill(pgid, Signal::SIGTERM) {
                Ok(_) => {
                    info!(event = "launcher.cleanup.sigterm",
                          run_id = %run.run_id, pid = run.pid, pgid = run.pgid, manual = manual);
                }
                Err(e) => {
                    warn!(event = "launcher.cleanup.sigterm_failed",
                          run_id = %run.run_id, err = %e);
                }
            }

            // Audit log: launcher killed
            if let Some(aw) = audit {
                aw.log_launcher_event("cleanup.kill", &run.run_id, &run.launcher_id, run.pid, 
                    if manual { "manual_end" } else { "revoke" });
            }
            cleaned.push(run.run_id.clone());
        }

        // Schedule SIGKILL after grace period for any survivors
        let grace = if manual { Duration::from_millis(500) } else { Duration::from_secs(3) };
        // (tokio::spawn with sleep(grace), then kill(-pgid, SIGKILL) for each cleaned run)

        self.active_runs.retain(|r| !cleaned.contains(&r.run_id));
    }
}
```

### Trust gate pattern (race condition handling)

```rust
// In launcher.run handler:
// 1. Check trust under lock
let trusted = { trust.lock().await.is_trusted() };
if !trusted {
    return error("trust_not_active");
}
// 2. Check single_instance — if already running, return error
if launcher.single_instance && is_running(&launcher.id) {
    return error("already_running");
}
// 3. Drop lock, spawn, register active run
// Gap is <1ms — cleanup_on_revoke catches stragglers
```

This is acceptable for v1. If revoke happens in the <1ms gap, the next tick's `cleanup_on_revoke()` catches it immediately.

### Per-launcher trust policy guidance

| Launcher type | Recommended `trust_policy` | Rationale |
|---|---|---|
| SSH session | `continuous` (default) | Live privileged session — must die with trust |
| Signer / wallet | `continuous` (default) | High-risk — must die |
| Trading bot | `start_only` | Trust was needed to **start**, not to keep alive |
| Generic script | `continuous` (default) | Secure by default |

---

## 5. UDS message payloads (locked)

These are the exact JSON shapes. Both Rust and Swift must conform to these.

### `launcher.list`

**Request:**
```json
{ "type": "launcher.list", "corr_id": "abc123" }
```

**Response:**
```json
{
  "type": "launcher.list",
  "corr_id": "abc123",
  "ok": true,
  "launchers": [
    {
      "id": "bot-freqtrade",
      "name": "Run Freqtrade",
      "description": "Starts the live trading bot with Binance keys",
      "enabled": true,
      "running": false,
      "trust_policy": "start_only",
      "single_instance": true,
      "last_error": null
    },
    {
      "id": "ssh-prod",
      "name": "SSH Production",
      "description": "Opens SSH session to production server",
      "enabled": true,
      "running": true,
      "trust_policy": "continuous",
      "single_instance": true,
      "last_error": null
    }
  ]
}
```

### `launcher.run`

**Request:**
```json
{ "type": "launcher.run", "corr_id": "def456", "launcher_id": "bot-freqtrade" }
```

**Success response:**
```json
{
  "type": "launcher.run",
  "corr_id": "def456",
  "ok": true,
  "launcher_id": "bot-freqtrade",
  "run_id": "r_abc123",
  "pid": 12345
}
```

**Failure response:**
```json
{
  "type": "launcher.run",
  "corr_id": "def456",
  "ok": false,
  "launcher_id": "bot-freqtrade",
  "error": "trust_not_active"
}
```

**Error values:** `trust_not_active`, `launcher_not_found`, `launcher_disabled`, `already_running`, `secret_not_found:<name>`, `spawn_failed:<detail>`

> **Note:** When `launcher.run` fails, the error is also stored as `last_error` on that launcher. Cleared on next successful run. This lets the menubar show actionable error info.

### Revoke hook wiring

After `push_trust_events()` for any revoke event, add in `bridge.rs`:

```rust
// In trust.revoke handler (manual "End Session"):
if ev.iter().any(|e| e.event == "revoked") {
    let mut lm = launcher_manager.lock().await;
    lm.cleanup_on_revoke(true, &audit);  // manual=true → immediate kill, no grace
}

// In trust.signal_lost and tick handlers (automatic revoke):
if ev.iter().any(|e| e.event == "revoked") {
    let mut lm = launcher_manager.lock().await;
    lm.cleanup_on_revoke(false, &audit);  // manual=false → SIGTERM, 3s grace, SIGKILL
}
```

This goes in **3 places** in bridge.rs where revoke events are emitted:
- `trust.signal_lost` handler (~line 1637) — `manual=false`
- `trust.revoke` handler (~line 1671) — `manual=true` (user clicked "End Session")
- tick timer — `manual=false` (TTL/idle expired)

---

## 6. Main wiring changes

### `main.rs`

```rust
mod launcher; // add module declaration

// In main():
let launcher_config_path = format!("{}/.armadillo/launchers.yaml",
    std::env::var("HOME").unwrap_or_default());
let launcher_manager = launcher::LauncherManager::new(&launcher_config_path);
info!(event = "launcher.loaded", count = launcher_manager.launcher_count());
let launcher_manager = Arc::new(Mutex::new(launcher_manager));

// Pass to bridge.run() — same pattern as trust: Arc<Mutex<TrustController>>
```

### `UnixBridge::run()` signature

Add `launcher_manager: Arc<Mutex<LauncherManager>>` parameter.

---

## 7. Audit logging

Wire launcher events into the existing `audit::AuditWriter`. For every launcher run and cleanup, log:

| Field | Description |
|-------|-------------|
| `event` | `launcher.run`, `launcher.cleanup.kill`, `launcher.cleanup.skip` |
| `launcher_id` | Which launcher |
| `run_id` | Which run instance |
| `trust_id` | Which trust session was active |
| `pid` | Process ID |
| `result` | `ok`, `error:<type>` |
| `reason` | For cleanup: `manual_end`, `revoke`, `start_only` |

**Never log secret values.** Only log secret key names (e.g., `"resolved secrets: [BINANCE_API_KEY, BINANCE_API_SECRET]"`).

Add a `log_launcher_event()` method to `AuditWriter` or use the existing structured logging pattern.

---

## 8. Dependencies

### `Cargo.toml` — add:

```toml
security-framework = "2"
nix = { version = "0.27", features = ["signal", "process"] }
```

---

## Potential blockers

| # | Risk | Mitigation |
|---|------|------------|
| 1 | Keychain access from unsigned binary → repeated prompts | Acceptable for dev. Codesign for distribution. "Always Allow" is permanent. |
| 2 | Child processes survive parent kill | `setsid()` + kill process group. Core design. |
| 3 | Race: trust revoke between check and spawn | <1ms gap. `cleanup_on_revoke()` catches stragglers. |
| 4 | Config changes while agent running | Reload on every `launcher.list` and `launcher.run`. |
| 5 | Stale menubar state | Cache launcher defs only. Trust-enabled state follows live events. |

---

## Implementation order

| Step | File | What to do |
|------|------|------------|
| 1 | `launcher.rs` | `TrustPolicy` enum + `Launcher` / `ActiveRun` / `LauncherManager` structs + YAML loader + config validation + `~` expansion + unit tests |
| 2 | `launcher.rs` | `resolve_secrets()` via `security-framework` + `spawn_launcher()` with `setsid` + pgid tracking + `single_instance` check |
| 3 | `launcher.rs` | `cleanup_on_revoke(manual, audit)` — manual=immediate, TTL=grace period |
| 4 | `bridge.rs` | `launcher.list` (with `last_error`) + `launcher.run` (with `already_running`) UDS handlers |
| 5 | `bridge.rs` | Revoke hook — `cleanup_on_revoke(true)` for manual, `cleanup_on_revoke(false)` for TTL/idle |
| 6 | `main.rs` | `mod launcher`, create manager, wire to bridge |
| 7 | `audit.rs` | Add `log_launcher_event()` method |
| 8 | `AppDelegate.swift` | Menubar: trust status cleanup + "Trusted Actions" section + launcher items + error display + run action (via `UnixSocketBridge`, NOT `TLSServer`) |
| 9 | Build | `cargo build --bin agent-macos` + `xcodebuild` on TLS terminator |
| 10 | Device pass | Manual test (see verification section) |

---

## Verification

### Automated tests

```bash
cargo test --bin agent-macos launcher::tests -- --nocapture
```

1. `test_load_valid_config` — parse valid YAML, verify all fields including `description`, `trust_policy`, `single_instance`
2. `test_load_empty_config` — empty file → no crash, empty list
3. `test_load_invalid_config` — malformed YAML → error handling
4. `test_tilde_expansion` — `cwd: "~"` expands to full home path
5. `test_config_validation` — invalid `exec_path` (relative, missing) → launcher skipped with warning
6. `test_run_requires_trust` — TrustController in Locked state → `trust_not_active` error
7. `test_single_instance_prevents_double_run` — second run of same launcher → `already_running`
8. `test_cleanup_kills_continuous` — `trust_policy: continuous` + cleanup → process dead
9. `test_cleanup_skips_start_only` — `trust_policy: start_only` + cleanup → process survives
10. `test_trust_policy_defaults_to_continuous` — omit field from YAML → defaults to `continuous`

### Build

```bash
cd /Users/cmbosys/Work/Armadilo && cargo build --bin agent-macos
xcodebuild -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj -scheme ArmadilloTLS -configuration Debug build
```

### Manual device pass

1. **Setup:**
   ```yaml
   # ~/.armadillo/launchers.yaml
   launchers:
     - id: "test-echo"
       name: "Echo Secret Test"
       description: "Verifies Keychain secret injection and cleanup"
       exec_path: "/bin/zsh"
       args: ["-lc", "echo $TEST_SECRET && sleep 3600"]
       cwd: "/Users/sergiu"
       secret_refs: ["TEST_SECRET"]
       trust_policy: "continuous"
       single_instance: true
       enabled: true
   ```
   ```bash
   security add-generic-password -s "com.symbiauth.secrets" -a "TEST_SECRET" -w "hello_from_keychain"
   ```

2. **Locked state:** Menubar shows "Echo Secret Test" greyed out. Not clickable.
3. **Trusted state:** iPhone → Face ID → menubar item becomes clickable → click → `ps aux | grep sleep` shows process → agent audit log shows `launcher.run` event.
4. **Single instance:** Click again while running → error toast/log `already_running`.
5. **Revoke cleanup (manual):** Click "End Session" → `sleep 3600` killed immediately → agent logs show `cleanup.kill` with `reason=manual_end`.
6. **Start-only policy:** Change `trust_policy: "start_only"` → restart → trust → run → end trust → process still alive → agent logs show `cleanup.skip` with `reason=start_only`.

---

## Design philosophy notes

- The **menubar is for running actions**, not configuring them (save config UI for 7d full app window).
- **Trust state drives everything.** If trust is active, launchers are available. If not, they're greyed out. Simple.
- The Mac app should feel like a **small control tower for trusted actions**, not a developer debug console.
- User-facing copy: prefer "Trusted Actions" over "Launchers" in the UI. "Launcher" is an internal concept.
