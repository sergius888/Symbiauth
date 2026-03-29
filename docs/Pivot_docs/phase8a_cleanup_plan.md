# Phase 8a: Targeted Hygiene Plan

> **Scope:** Light cleanup only. Remove safely deletable dead code, stabilize build artifacts.
> **Rule:** No broad refactoring, no renames, no global warning crusade. If it requires touching `bridge.rs` business logic, it's 8b.

---

## Dependency Audit (verified)

Before writing this plan, we audited actual references to each "dead code" candidate:

| File | `mod` declared | Actually used by | Verdict |
|------|---------------|-----------------|---------|
| `bridge_prox_gate.rs` | **Not declared anywhere** | Nothing | ✅ **Safe to delete** |
| `ble_scanner.rs` | `main.rs:12`, `lib.rs:6` | `main.rs:245` (BleScanner::new), `ble_global.rs:3` | 🔴 **Active runtime path — 8b work** |
| `ble_global.rs` | `main.rs:11`, `lib.rs:5` | `pairing.rs:548` (get_ble_scanner) | 🔴 **Active runtime path — 8b work** |
| `proximity.rs` | `main.rs:23`, `lib.rs:15` | `bridge.rs` (25+ refs), `config.rs` (5 refs), `main.rs` (5 refs), `lib.rs:40` | 🔴 **Deeply wired — 8b work** |

> [!CAUTION]
> `proximity.rs` cannot be deleted in 8a. It's referenced by `bridge.rs` in 25+ places including the core message loop, state management, and auth gating. Removing it requires refactoring bridge.rs internals, which is 8b scope.
>
> `ble_scanner.rs` and `ble_global.rs` are also not safe to delete in 8a. They are currently initialized in `main.rs` and used by pairing hot-reload paths. This is active code, not dead fallback.

---

## 8a Scope: What TO Do

### Step 1: Delete truly dead files

- **Delete** `bridge_prox_gate.rs` — zero references anywhere
- **Verify** build still passes

### Step 2: Keep btleplug + scanner stack in 8a (explicit defer)

- `btleplug`, `ble_scanner.rs`, and `ble_global.rs` are explicitly deferred to 8b.
- Even though trust-v1 BLE moved to Swift (`BLETrustCentral`), the Rust scanner stack still participates in proximity/pairing paths.
- Removing them in 8a would require behavior refactor in `main.rs`, `pairing.rs`, and proximity flows.

### Step 4: Stabilize `.gitignore`

Current `.gitignore` (root level):
```
.DS_Store
xcuserdata/
DerivedData/
target/
node_modules/
dist/
build/
*.xcactivitylog
*.xcuserstate
*.xccheckout
*.xcscmblueprint
*.swiftdeps
*.swiftsourceinfo
*.swiftmodule
*.dSYM/
/tmp/*.log
*.ndjson
```

Add if missing:
- `*.ndjson` is already present (audit logs) ✅
- Verify `Cargo.lock` is tracked (should be, it's a binary project)
- Add `*.bak` or `*.bak_*` if launcher config backups shouldn't be tracked
- Add `.armadillo/` if local runtime data shouldn't be tracked
 - Add tool/build output ignores that are currently polluting status (without destructive untracking in 8a)

### Step 5: Fix high-signal warnings (touched files only)

- Run `cargo build --bin agent-macos 2>&1 | grep warning` to see current warnings
- Fix only warnings in files touched during Phase 7a/7b: `launcher.rs`, `secrets.rs`, `bridge.rs`, `audit/record.rs`, `audit/writer.rs`, `AppDelegate.swift`
- Do NOT fix warnings in `proximity.rs`, `ble_scanner.rs`, or other files scheduled for 8b removal

### Step 6: Quick secrets scan

- `rg -n -i "password|api[_-]?key|secret[_-]?key|token|BEGIN (RSA|OPENSSH|PRIVATE) KEY" apps docs` for hardcoded secrets
- Verify no real credentials committed anywhere
- Check for leftover test secrets in config files

---

## 8a Scope: What NOT To Do (8b work)

| Item | Why it's 8b |
|------|------------|
| Delete `proximity.rs` | 25+ references in bridge.rs business logic |
| Delete `ble_scanner.rs` / `ble_global.rs` | Active runtime/pairing path; not dead yet |
| Remove `btleplug` dep | Blocked by active scanner path |
| Rename armadillo → symbiauth | Bundle IDs, keychain groups, entitlements — broad impact |
| Refactor bridge.rs proximity gating | Core message loop, needs careful untangling |
| Deep warning pass across all files | Not our code, not our problem until 8b |
| Switch TLS to on-demand | Architectural change |
| Delete `config.rs` ProxMode references | Tied to proximity.rs removal |

---

## Verification

```bash
# After all steps:
cargo build --bin agent-macos
cargo test --bin agent-macos -- --nocapture
xcodebuild -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj -scheme ArmadilloTLS -configuration Debug build
```

All three must pass. No new warnings should be introduced. Existing test count should remain ≥ current (secrets + launcher tests all pass).

---

## Acceptance Checklist

- [ ] `bridge_prox_gate.rs` deleted
- [ ] `ble_scanner.rs` + `ble_global.rs` explicitly deferred to 8b (documented)
- [ ] `btleplug` removal explicitly deferred to 8b (documented)
- [ ] `.gitignore` reviewed and updated
- [ ] Warnings in 7a/7b touched files fixed
- [ ] No hardcoded secrets found
- [ ] `cargo build` passes
- [ ] `cargo test` passes (no regressions)
- [ ] `xcodebuild` passes
- [ ] Progress logged in `Logs.md` + `lessons.md`
