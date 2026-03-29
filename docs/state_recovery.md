# Symbiauth State Recovery & Crash Safety

## Overview

Symbiauth is designed to **recover gracefully** from crashes, preserving data integrity and resuming normal operation without user intervention.

---

## Vault (SQLite)

### **WAL Mode**

The vault uses **SQLite in WAL (Write-Ahead Logging) mode** for crash safety:

```rust
conn.pragma_update(None, "journal_mode", "WAL")?;
conn.pragma_update(None, "synchronous", "NORMAL")?;
```

**Properties**:
- Writes go to `-wal` file first, then checkpointed to main DB
- **Atomic commits**: Either all changes or none
- **Read-while-write**: Readers see consistent snapshot
- **Crash recovery**: On restart, SQLite replays WAL to restore consistent state

### **Recovery on Boot**

When agent starts:

```rust
async fn open_vault() -> Result<Vault> {
    let path = dirs::home_dir()
        .ok_or(Error::NoHomeDir)?
        .join(".armadillo/vault.db");
    
    // SQLite automatically replays WAL if present
    let conn = Connection::open(path)?;
    
    // Verify schema version
   let version: u32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version != CURRENT_VERSION {
        return Err(Error::VaultVersionMismatch);
    }
    
    Ok(Vault { conn })
}
```

**On corruption** (rare, requires filesystem failure):
- Agent logs error, refuses to start
- User must restore from backup or re-initialize vault
- **No silent data loss**

### **Master Key Survival**

Vault master key is stored in **macOS Keychain**, separate from vault file:

```rust
// On first run, generate and wrap key
let mk = generate_random_256bit();
let wrapped = SecureEnclave::wrap(mk)?;
keychain.set("armadillo.vault.mk", wrapped)?;

// On restart, unwrap from Keychain
let wrapped = keychain.get("armadillo.vault.mk")?;
let mk = SecureEnclave::unwrap(wrapped)?;
```

**Properties**:
- MK survives agent crash/restart
- Even if `vault.db` deleted, MK remains (user can re-init)
- SE wrapping ensures MK never stored in plaintext

---

## Pending Auth Requests

### **Ephemeral State**

Pending `auth.request` entries are **not persisted**:

```rust
struct AuthGate {
    pending: HashMap<String, PendingAuth>, // In-memory only
}
```

**On agent restart**:
1. `pending` map is empty
2. iOS receives no response (connection closed)
3. iOS times out after 30s, shows "Connection lost" to user
4. User can retry manually

**Rationale**:
- Persisting pending auths adds complexity
- 30s timeout is short enough that user can retry
- Avoids stale auth requests after days/weeks

---

## Proximity State

### **Default to Locked**

On agent restart, proximity **defaults to locked**:

```rust
impl Proximity {
    fn new() -> Self {
        Proximity {
            mode: ProxMode::Intent,
            state: ProxState::Locked, // ✅ Start locked
            tls_up: false,
            ble_signal: None,
        }
    }
}
```

**Behavior**:
- User must bring phone close + tap intent (or auto-unlock if configured)
- Prevents accidental unlock if phone was nearby during crash

### **Fresh Presence Required**

After restart, agent requires **fresh proximity signal**:

- BLE signal older than 5s → Ignored
- TLS heartbeat required → Fresh connection

**Rationale**: Don't trust stale BLE advertisements

---

## Cert Rotation

### **Pin Current + Next**

mTLS cert fingerprints stored in **two slots**:

```rust
struct TlsConfig {
    fp_current: Fingerprint, // Currently active cert
    fp_next: Option<Fingerprint>, // Pre-pinned next cert (optional)
}
```

**On rotation**:
1. Generate new cert, compute `fp_new`
2. Update QR to include `fp_current` and `fp_next = fp_new`
3. iOS pins both fingerprints
4. After overlap window (e.g., 7 days), `fp_current` → `fp_next`, `fp_next` → None

**Safe to roll back**:
- If rotation fails mid-process, agent can keep using `fp_current`
- iOS accepts either `fp_current` or `fp_next`

---

## Crash Safety Tests

### **Test Scenarios**

| Test | Setup | Kill Signal | Expected After Restart |
|------|-------|-------------|------------------------|
| **Vault mid-write** | Insert record, kill before commit | SIGKILL | Record not in vault (rolled back) |
| **Vault post-commit** | Insert record, fsync, kill | SIGKILL | Record persists |
| **Auth pending** | Send `auth.request`, kill agent | SIGKILL | iOS times out (30s), can retry |
| **TLS mid-handshake** | Start pairing, kill during SAS | SIGKILL | iOS shows error, can scan QR again |
| **Proximity locked** | Restart agent while phone nearby | N/A | Requires fresh intent/presence |

### **Implementation**

```rust
#[tokio::test]
async fn vault_survives_kill_mid_write() {
    let vault = Vault::open_test_db().await.unwrap();
    
    // Start transaction but don't fsync
    vault.begin_write("key1", b"value1").await.unwrap();
    
    // Simulate crash (drop without commit)
    drop(vault);
    
    // Restart
    let vault2 = Vault::open_test_db().await.unwrap();
    
    // Read should return NotFound (write was rolled back)
    assert!(matches!(vault2.read("key1").await, Err(Error::NotFound)));
}
```

**Run with**:
```bash
cargo test --test crash_safety
```

---

## Backup & Restore (Post-MVP)

> [!NOTE]
> Not implemented in Phase 1-3; designed for Phase 4+.

### **Export Encrypted Backup**

```rust
async fn export_backup(passphrase: &str) -> Result<Vec<u8>> {
    // 1. Read entire vault
    let vault_data = vault.export_all().await?;
    
    // 2. Read policy file
    let policy = fs::read("~/.armadillo/policy.yaml").await?;
    
    // 3. Read pairing DB
    let pairings = pairing_db.export().await?;
    
    // 4. Create archive
    let archive = Archive {
        vault: vault_data,
        policy,
        pairings,
        version: 1,
    };
    
    // 5. Encrypt with passphrase (Argon2id KDF)
    let salt = generate_random_16 bytes();
    let key = argon2id(passphrase, salt, ...);
    let encrypted = aes_gcm_encrypt(key, &archive)?;
    
    Ok(encrypted)
}
```

**Restore**:
- User must enter passphrase
- Agent decrypts, validates version, imports vault + policy + pairings
- Master key remains in Keychain (not exported)

---

## Summary

- **Vault**: SQLite WAL mode ensures atomic commits; auto-recovery on restart
- **Master key**: Stored in Keychain, survives crashes and vault deletion
- **Pending auths**: Ephemeral, cleared on restart; iOS times out and can retry
- **Proximity**: Defaults to locked, requires fresh signal after restart
- **Cert rotation**: Pin current+next; safe to roll back
- **Tests**: Kill agent mid-write → data not lost; kill mid-auth → iOS retries; kill during proximity → requires fresh unlock
- **Backup (future)**: Encrypted export with passphrase, includes vault + policy + pairings

### **SQLite Durability Options**

**Default (MVP)**: `synchronous=NORMAL`

```rust
conn.pragma_update(None, "journal_mode", "WAL")?;
conn.pragma_update(None, "synchronous", "NORMAL")?;
```

**Properties**:
- **Crash-safe**: DB remains consistent (no corruption)
- **May lose last transaction on power loss** (but not application crash)
- **Faster writes** than FULL

**Production (optional)**: `synchronous=FULL`

```rust
conn.pragma_update(None, "synchronous", "FULL")?;
```

**Properties**:
- **Power-loss safe**: Last committed transaction survives even abrupt power off
- **Slower writes** (waiting for fsync)
- **Configurable**: Add flag `--sync-mode=full` for critical deployments

**Recommendation**: Start with `NORMAL`; add `FULL` mode if users report data loss.

---

### **Schema Migrations**

Instead of erroring on version mismatch, define **migrate-up path**:

```rust
async fn open_vault() -> Result<Vault> {
    let conn = Connection::open(path)?;
    let current_version: u32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    
    match current_version {
        0 => {
            // Fresh DB, initialize schema
            conn.execute("CREATE TABLE credentials (...)", [])?;
            conn.pragma_update(None, "user_version", CURRENT_VERSION)?;
        }
        1 => {
            // Migrate v1 → v2
            conn.execute("ALTER TABLE credentials ADD COLUMN ...", [])?;
            conn.pragma_update(None, "user_version", 2)?;
        }
        CURRENT_VERSION => {
            // Up to date
        }
        other => {
            return Err(Error::UnsupportedVaultVersion(other));
        }
    }
    
    Ok(Vault { conn })
}
```

**Reversible scripts**: Keep `.sql` migration files for each version (up/down).

---

### **Secure Enclave / Keychain Details**

**macOS Implementation**:

```rust
// Option 1: CryptoKit key wrapping (macOS 10.15+)
use Security::SecKeyCreateRandomKey;

let key_attrs = CFDictionary::from_CFType_pairs(&[
    (kSecAttrKeyType, kSecAttrKeyTypeECSECPrimeRandom),
    (kSecAttrKeySizeInBits, 256),
    (kSecAttrTokenID, kSecAttrTokenIDSecureEnclave),
]);

let se_key = SecKeyCreateRandomKey(key_attrs, &mut error)?;

// Wrap vault MK with SE key
let wrapped_mk = SecKeyCreateEncryptedData(se_key, algorithm, mk_data, &mut error)?;

// Store wrapped MK in Keychain
keychain.set("armadillo.vault.mk", wrapped_mk, kSecAttrAccessibleWhenUnlocked)?;
```

**Key properties**:
- MK never persists in plaintext (not in memory, not on disk)
- `kSecAttrAccessibleWhenUnlocked`: Requires device unlock to access
- SE-backed key cannot be exported (hardware-bound)

---

### **Kill-and-Recover Integration Tests**

**Real process test**:

```rust
#[tokio::test]
async fn kill_agent_mid_write_survives() {
    // 1. Spawn agent process
    let mut child = Command::new("./target/debug/agent-macos")
        .spawn()
        .unwrap();
    
    // 2. Connect and start vault write
    let client = connect_to_agent().await.unwrap();
    client.send_write("key1", b"value1").await.unwrap();
    
    // 3. Kill agent mid-transaction (SIGKILL)
    child.kill().await.unwrap();
    
    // 4. Restart agent
    let mut child2 = Command::new("./target/debug/agent-macos")
        .spawn()
        .unwrap();
    
    tokio::time::sleep(Duration::from_secs(1)).await;
    
    // 5. Verify: write either completed or rolled back (never partial)
    let client2 = connect_to_agent().await.unwrap();
    match client2.send_read("key1").await {
        Ok(v) => assert_eq!(v, b"value1"), // Committed
        Err(Error::NotFound) => {}, // Rolled back (acceptable)
        Err(e) => panic!("Unexpected error: {}", e),
    }
    
    child2.kill().await.unwrap();
}
```

**Run with**: `cargo test --test integration_crash_safety`

---

### **Backup & Pairing DB Restore**

**Backup export** (`backup.enc`):
- Vault data (all credentials)
- Policy file (`policy.yaml`)
- Pairing DB (device fingerprints, session IDs, cert pins)
- Version metadata

**On restore**:
- Pairings are **inert** until re-validated:
  - Agent must verify mTLS cert pins match
  - iOS must re-handshake with current cert
- If cert rotated since backup → pairing fails, user must re-scan QR
- **UX**: Show "Pairings restored; reconnect devices to validate"

