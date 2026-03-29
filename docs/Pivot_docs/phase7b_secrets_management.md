# Phase 7b: Secrets Management Layer

> **Scope:** Make secrets manageable without a terminal. No custom secret store, no full app window.
> **Depends on:** Phase 7a (launcher.rs, bridge.rs, AppDelegate.swift all in place).
> **Status:** Locked after engineer review. Ready for implementation.

---

## Product Context

Today, adding a secret requires running:
```bash
security add-generic-password -s "com.symbiauth.secrets" -a "BINANCE_API_KEY" -w "actual_key_value"
```

After 7b, the user can manage secrets from the menubar with zero terminal usage. The engineering effort is small because 7a already built the Keychain backend and the UDS/bridge/menubar pipeline.

---

## Key Architecture Decisions

### 1. Launcher-derived secret list (no separate registry)

**Problem:** macOS Keychain has no "list all accounts for service X" in the high-level `security-framework` API. Options were:

| Option | Pro | Con |
|--------|-----|-----|
| A. Use low-level `SecItemCopyMatching` | Lists everything in Keychain | Complex, may include stale entries |
| B. Maintain separate `secrets.yaml` index | Independent of launchers | Sync issues, extra config file |
| **C. Derive from launcher `secret_refs`** | **Always in sync, zero config** | **Can't browse orphaned secrets** |

**Decision: Option C.** `secret.list` collects all unique `secret_refs` across all launchers, then checks each one against Keychain. This answers the only question users care about: *"Which secrets do my launchers need, and are they available?"*

Orphaned secrets (in Keychain but not referenced) are harmless and can be managed via Keychain Access.app if needed.

### 2. Trust gate on writes, not reads

| Operation | Trust required? | Reason |
|-----------|----------------|--------|
| `secret.list` | No | Read-only, returns names + status only, never values |
| `secret.test` | No | Same as list, but for a single secret |
| `secret.set` | **Yes** | Writes to Keychain — dangerous if UDS is compromised |
| `secret.delete` | **Yes** | Removes secrets — dangerous, could break launchers |

Rationale: the product thesis is "dangerous actions require trust." Adding/removing secrets that control launcher behavior is dangerous.

### 3. Single resolver boundary (no forked logic)

`secrets.rs` owns all Keychain primitives (`KEYCHAIN_SERVICE` constant, `test_secret`, `set_secret`, `delete_secret`). `launcher.rs` delegates through `SecretResolver` trait → `KeychainSecretResolver` → `secrets.rs`. **One read path, not two.**

```rust
// secrets.rs — owns the constant and all Keychain primitives
pub const KEYCHAIN_SERVICE: &str = "com.symbiauth.secrets";

// launcher.rs — delegates, does not import security_framework directly
impl SecretResolver for KeychainSecretResolver {
    fn resolve_secrets(&self, secret_refs: &[String]) -> Result<HashMap<String, String>, String> {
        crate::secrets::resolve_secrets(secret_refs)  // single path
    }
}
```

### 4. Error taxonomy

All secret operations return structured, distinguishable errors:

| Error | When |
|-------|------|
| `trust_not_active` | Write/delete attempted without active trust |
| `secret_not_found` | Delete/test for a secret that doesn't exist in Keychain |
| `keychain_write_failed` | Keychain rejected the write (permissions, locked, etc.) |
| `keychain_access_denied` | Keychain access denied by user or entitlement |
| `keychain_backend_disabled` | `mac-keychain` feature not enabled |
| `invalid_secret_name` | Name fails validation (see §5) |
| `value_too_large` | Value exceeds max length (see §5) |

### 5. Input validation for `secret.set`

Validate before touching Keychain:

```rust
fn validate_secret_name(name: &str) -> Result<(), String> {
    if name.is_empty() || name.len() > 128 {
        return Err("invalid_secret_name".to_string());
    }
    // Allow: A-Z, a-z, 0-9, underscore, dash, dot
    if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.') {
        return Err("invalid_secret_name".to_string());
    }
    Ok(())
}

fn validate_secret_value(value: &str) -> Result<(), String> {
    if value.is_empty() || value.len() > 8192 {
        return Err("value_too_large".to_string());
    }
    Ok(())
}
```

Limits: name ≤128 chars (alphanumeric + `_-.`), value ≤8KB.

### 6. Menubar UX (not full window)

Full secret editor is 7d scope. For 7b:
- **Secrets submenu** under Settings showing name + status (✅/❌)
- **"Add Secret..."** action → `NSAlert` with name field + `NSSecureTextField` for value
- Each secret has a **submenu with "Delete..."** action (not right-click — fragile on menubar)
- Secret values are **never displayed** in any UI surface

### 7. Non-Keychain behavior

With `mac-keychain` feature disabled:
- `secret.list` returns all secrets with `"available": false` and `"status": "backend_disabled"` — **not** silently missing
- `secret.test` returns `"available": false, "status": "backend_disabled"`
- `secret.set` / `secret.delete` return `"error": "keychain_backend_disabled"`

### 8. Audit events

Since 7a already has `log_launcher_event` plumbing, 7b logs secret operations (never values):

| Event | Fields |
|-------|--------|
| `secret.set` | `name`, `created` (bool), `result` (ok/err) |
| `secret.delete` | `name`, `affected_launchers`, `result` (ok/err) |

---

## UDS Message Contracts

### `secret.list` — Request

```json
{
  "type": "secret.list",
  "corr_id": "abc123"
}
```

### `secret.list` — Response

```json
{
  "type": "secret.list",
  "corr_id": "abc123",
  "ok": true,
  "secrets": [
    { "name": "BINANCE_API_KEY", "available": true, "used_by": ["bot-freqtrade"] },
    { "name": "BINANCE_API_SECRET", "available": true, "used_by": ["bot-freqtrade"] },
    { "name": "SSH_PASSPHRASE", "available": false, "used_by": ["ssh-prod"] }
  ]
}
```

Fields:
- `name` — the secret ref name (from launcher YAML)
- `available` — `true` if Keychain has this entry, `false` if missing
- `used_by` — list of launcher IDs that reference this secret

With `mac-keychain` disabled, each secret includes `"status": "backend_disabled"` and `"available": false`.

### `secret.set` — Request (trust required)

```json
{
  "type": "secret.set",
  "corr_id": "abc123",
  "name": "BINANCE_API_KEY",
  "value": "actual_key_value"
}
```

### `secret.set` — Response

```json
{
  "type": "secret.set",
  "corr_id": "abc123",
  "ok": true,
  "name": "BINANCE_API_KEY",
  "created": false
}
```

Fields:
- `created` — `true` if new entry, `false` if updated existing. Uses `set_generic_password` which upserts.

Error response (trust not active):
```json
{
  "type": "secret.set",
  "corr_id": "abc123",
  "ok": false,
  "name": "BINANCE_API_KEY",
  "error": "trust_not_active"
}
```

### `secret.delete` — Request (trust required)

```json
{
  "type": "secret.delete",
  "corr_id": "abc123",
  "name": "BINANCE_API_KEY"
}
```

### `secret.delete` — Response

```json
{
  "type": "secret.delete",
  "corr_id": "abc123",
  "ok": true,
  "name": "BINANCE_API_KEY",
  "affected_launchers": ["bot-freqtrade"]
}
```

`affected_launchers` tells the user which launchers will break. The deletion still proceeds — it's the user's explicit action. The menubar shows a confirmation dialog before sending this.

Possible errors:

| `error` value | When |
|---------------|------|
| `trust_not_active` | Trust session not active |
| `secret_not_found` | Secret doesn't exist in Keychain |
| `keychain_access_denied` | Keychain rejected the deletion |
| `keychain_backend_disabled` | Feature not enabled |

### `secret.test` — Request

```json
{
  "type": "secret.test",
  "corr_id": "abc123",
  "name": "BINANCE_API_KEY"
}
```

### `secret.test` — Response

```json
{
  "type": "secret.test",
  "corr_id": "abc123",
  "ok": true,
  "name": "BINANCE_API_KEY",
  "available": true
}
```

Note: `secret.test` returns `ok: true` even if the secret doesn't exist — `ok` means the request succeeded, `available` tells you if the secret is there. Error `ok: false` is reserved for system failures (e.g., Keychain unavailable).

---

## Rust Implementation

### New module: `secrets.rs`

```rust
use std::collections::{HashMap, HashSet};

pub const KEYCHAIN_SERVICE: &str = "com.symbiauth.secrets";

// --- Validation ---

pub fn validate_secret_name(name: &str) -> Result<(), String> {
    if name.is_empty() || name.len() > 128 {
        return Err("invalid_secret_name".to_string());
    }
    if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.') {
        return Err("invalid_secret_name".to_string());
    }
    Ok(())
}

pub fn validate_secret_value(value: &str) -> Result<(), String> {
    if value.is_empty() || value.len() > 8192 {
        return Err("value_too_large".to_string());
    }
    Ok(())
}

// --- Launcher-derived helpers ---

pub fn collect_secret_refs(launchers: &[crate::launcher::Launcher]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut refs = Vec::new();
    for launcher in launchers {
        for sr in &launcher.secret_refs {
            if seen.insert(sr.clone()) {
                refs.push(sr.clone());
            }
        }
    }
    refs
}

pub fn secret_usage_map(launchers: &[crate::launcher::Launcher]) -> HashMap<String, Vec<String>> {
    let mut map: HashMap<String, Vec<String>> = HashMap::new();
    for launcher in launchers {
        for sr in &launcher.secret_refs {
            map.entry(sr.clone())
                .or_default()
                .push(launcher.id.clone());
        }
    }
    map
}

// --- Keychain operations ---

pub fn test_secret(name: &str) -> Result<bool, String> {
    #[cfg(feature = "mac-keychain")]
    {
        use security_framework::passwords::get_generic_password;
        Ok(get_generic_password(KEYCHAIN_SERVICE, name).is_ok())
    }
    #[cfg(not(feature = "mac-keychain"))]
    {
        let _ = name;
        Err("keychain_backend_disabled".to_string())
    }
}

pub fn set_secret(name: &str, value: &str) -> Result<bool, String> {
    validate_secret_name(name)?;
    validate_secret_value(value)?;

    #[cfg(feature = "mac-keychain")]
    {
        use security_framework::passwords::{get_generic_password, set_generic_password};
        let existed = get_generic_password(KEYCHAIN_SERVICE, name).is_ok();
        set_generic_password(KEYCHAIN_SERVICE, name, value.as_bytes())
            .map_err(|e| {
                let msg = e.to_string();
                if msg.contains("denied") || msg.contains("authorization") {
                    "keychain_access_denied".to_string()
                } else {
                    format!("keychain_write_failed:{}", msg)
                }
            })?;
        Ok(!existed)
    }
    #[cfg(not(feature = "mac-keychain"))]
    {
        let _ = (name, value);
        Err("keychain_backend_disabled".to_string())
    }
}

pub fn delete_secret(name: &str) -> Result<(), String> {
    validate_secret_name(name)?;

    #[cfg(feature = "mac-keychain")]
    {
        use security_framework::passwords::delete_generic_password;
        delete_generic_password(KEYCHAIN_SERVICE, name)
            .map_err(|e| {
                let msg = e.to_string();
                if msg.contains("not found") || msg.contains("-25300") {
                    "secret_not_found".to_string()
                } else if msg.contains("denied") || msg.contains("authorization") {
                    "keychain_access_denied".to_string()
                } else {
                    format!("keychain_write_failed:{}", msg)
                }
            })
    }
    #[cfg(not(feature = "mac-keychain"))]
    {
        let _ = name;
        Err("keychain_backend_disabled".to_string())
    }
}

/// Resolve secrets for launcher use — single read path.
/// launcher.rs delegates here via SecretResolver trait.
pub fn resolve_secrets(secret_refs: &[String]) -> Result<HashMap<String, String>, String> {
    if secret_refs.is_empty() {
        return Ok(HashMap::new());
    }

    #[cfg(feature = "mac-keychain")]
    {
        use security_framework::passwords::get_generic_password;
        let mut resolved = HashMap::new();
        for name in secret_refs {
            let bytes = get_generic_password(KEYCHAIN_SERVICE, name)
                .map_err(|e| format!("secret_not_found:{}:{}", name, e))?;
            let value = String::from_utf8(bytes)
                .map_err(|e| format!("secret_not_found:{}:invalid_utf8:{}", name, e))?;
            resolved.insert(name.clone(), value);
        }
        Ok(resolved)
    }

    #[cfg(not(feature = "mac-keychain"))]
    {
        Err("keychain_backend_disabled".to_string())
    }
}
```

### Update `launcher.rs`

- Delete the `resolve_secrets()` function (move to `secrets.rs`)
- `KeychainSecretResolver` delegates to `crate::secrets::resolve_secrets()`
- Remove `use security_framework::passwords::get_generic_password` import

---

## Swift Menubar (AppDelegate.swift)

### Secrets submenu under Settings

```
Settings ▸
  Secrets ▸
    ✅ BINANCE_API_KEY ▸
       Delete...
    ✅ BINANCE_API_SECRET ▸
       Delete...
    ❌ SSH_PASSPHRASE         (used by: SSH Production)
    ────────────────
    Add Secret...
```

- Status prefix: ✅ (available) / ❌ (missing)
- Tooltip: `used_by` launcher names
- Available secrets have a **submenu with "Delete..."** action (not right-click — fragile on menubar)
- Missing secrets are not clickable — they show the problem
- "Add Secret..." opens an `NSAlert` dialog

### Add Secret dialog

```swift
let alert = NSAlert()
alert.messageText = "Add Secret"
alert.informativeText = "Enter the secret name and value. The value will be stored in macOS Keychain."
alert.addButton(withTitle: "Save")
alert.addButton(withTitle: "Cancel")

let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
stack.orientation = .vertical
stack.spacing = 8

let nameField = NSTextField(frame: .zero)
nameField.placeholderString = "Secret name (e.g. BINANCE_API_KEY)"

let valueField = NSSecureTextField(frame: .zero)
valueField.placeholderString = "Secret value"

stack.addArrangedSubview(nameField)
stack.addArrangedSubview(valueField)
alert.accessoryView = stack

if alert.runModal() == .alertFirstButtonReturn {
    let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
    let value = valueField.stringValue
    guard !name.isEmpty, !value.isEmpty else { return }
    // Send secret.set via UDS
}
```

### Delete Secret

Per-secret submenu → "Delete..." → confirmation `NSAlert`:

```
"Delete secret BINANCE_API_KEY?"
"This will affect launchers: Run Freqtrade"
[Delete] [Cancel]
```

`affected_launchers` is precomputed from `used_by` in the cached `secret.list` response.

---

## Implementation Order

| Step | What | Files |
|------|------|-------|
| 1 | `secrets.rs` module (constant, collect, test, set, delete) | `secrets.rs`, `lib.rs`, `main.rs` |
| 2 | Update `launcher.rs` to use `KEYCHAIN_SERVICE` constant | `launcher.rs` |
| 3 | UDS handlers in `bridge.rs` (list, test, set, delete + trust gate) | `bridge.rs` |
| 4 | Swift: `secret.list` request + Secrets submenu rendering | `AppDelegate.swift` |
| 5 | Swift: "Add Secret..." dialog + `secret.set` call | `AppDelegate.swift` |
| 6 | Swift: "Delete" action + confirmation + `secret.delete` call | `AppDelegate.swift` |
| 7 | Tests + verification | `secrets.rs` tests, build, device pass |

---

## Verification Plan

### Automated tests (Rust)
1. `test_collect_secret_refs` — deduplicates across launchers
2. `test_secret_usage_map` — maps secret → launcher IDs
3. `test_validate_secret_name` — valid/invalid name patterns
4. `test_validate_secret_value` — empty/oversized rejection
5. `test_set_and_test_secret` — set → test returns true (requires Keychain, may need `#[ignore]` in CI)
6. `test_delete_secret` — delete → test returns false
7. `test_delete_nonexistent` — returns `secret_not_found`
8. `test_non_keychain_returns_backend_disabled` — cfg(not(mac-keychain)) behavior

### Build verification
```bash
cargo test --bin agent-macos secrets::tests -- --nocapture
cargo build --bin agent-macos
xcodebuild -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj -scheme ArmadilloTLS -configuration Debug build
```

### Manual device pass
1. Start agent + menubar app + iPhone
2. Settings ▸ Secrets — see ❌ for missing secrets
3. Start trust session from iPhone
4. "Add Secret..." → enter name + value → Save
5. Secrets submenu updates to ✅
6. Click launcher that uses the secret → verify it runs
7. Delete the secret → confirmation shows affected launchers
8. Secrets submenu shows ❌ again → launcher fails with `secret_not_found`

---

## What is NOT in scope

- Custom encrypted store (Keychain is the backend)
- Secret rotation / expiry
- Import / export
- Sharing secrets across Macs
- Displaying secret values anywhere
- Full app window for secret management (7d)

---

## Blockers

| # | Risk | Mitigation |
|---|------|------------|
| 1 | Keychain prompts on unsigned dev builds | Expected. "Always Allow" is permanent per service+account. Same as 7a. |
| 2 | `set_generic_password` upsert semantics unclear | Docs confirm it creates or updates. `created` field in response derived from pre-check with `get_generic_password`. |
| 3 | Large number of secret_refs causes slow `secret.list` | Each `get_generic_password` is ~1ms. 20 secrets = 20ms. Not a concern for v1. |
