# BLE → Proximity Integration Plan

**Goal:** Wire BLE token validation to proximity state machine  
**Status:** BLE working, proximity ready, connection missing  
**Estimated Time:** 30-60 minutes

---

## Current State

### ✅ What Works
- iOS advertises iBeacon with HMAC tokens
- macOS scanner detects and validates tokens
- Log shows: `event="ble.token.valid"` every 1-2 seconds
- Proximity module has `note_ble_seen(now, rssi)` ready

### ❌ The Gap
BLE validation happens but **doesn't update proximity state**:

```rust
// apps/agent-macos/src/ble_scanner.rs:200
if self.validate_token_for_device(...) {
    info!(event = "ble.token.valid", ...);
    
    // TODO: Update proximity module  ← THIS IS THE GAP
    // proximity.note_ble_seen(Instant::now(), rssi)
    
    return;
}
```

---

## Implementation Plan

### Step 1: Pass Proximity to BLE Scanner

**File:** `apps/agent-macos/src/ble_scanner.rs`

**Change struct definition:**
```rust
pub struct BleScanner {
    adapter: Adapter,
    paired_devices: Arc<RwLock<HashMap<String, Vec<u8>>>>,
    proximity: Arc<Mutex<Proximity>>,  // ADD THIS
}
```

**Update constructor:**
```rust
impl BleScanner {
    pub async fn new(
        proximity: Arc<Mutex<Proximity>>  // ADD PARAMETER
    ) -> Result<Self, Box<dyn std::error::Error>> {
        // ... existing code ...
        
        Ok(Self {
            adapter,
            paired_devices: Arc::new(RwLock::new(HashMap::new())),
            proximity,  // STORE IT
        })
    }
}
```

---

### Step 2: Call Proximity on Valid Token

**File:** `apps/agent-macos/src/ble_scanner.rs` (around line 200)

**Replace TODO with actual call:**
```rust
if self.validate_token_for_device(token_bytes, k_ble, fp_suffix, bucket) {
    info!(
        event = "ble.token.valid",
        fp_suffix = %fp_suffix,
        rssi = ?rssi,
        bucket_delta = bucket_delta,
        bucket = bucket
    );
    
    // UPDATE PROXIMITY STATE
    if let Ok(mut prox) = self.proximity.lock() {
        prox.note_ble_seen(Instant::now(), rssi);
        info!(
            event = "prox.ble_seen",
            fp = %fp_suffix,
            rssi = ?rssi
        );
    } else {
        warn!(event = "prox.lock_failed", reason = "mutex poisoned");
    }
    
    return;
}
```

---

### Step 3: Update BLE Scanner Creation Sites

**File:** `apps/agent-macos/src/main.rs` (around line 200-250)

**Find where BLE scanner is created**, add proximity parameter:

```rust
// OLD
let ble_scanner = BleScanner::new().await?;

// NEW
let ble_scanner = BleScanner::new(
    Arc::clone(&proximity)  // Pass proximity reference
).await?;
```

**Note:** You'll need to ensure `proximity` is created BEFORE the BLE scanner.

---

### Step 4: Verify Proximity Module Integration

**File:** `apps/agent-macos/src/proximity.rs`

**The method already exists** (line 314):
```rust
pub fn note_ble_seen(&mut self, now: Instant, rssi: Option<i16>) {
    self.last_ble_seen = Some(now);
    self.last_rssi = rssi;
    
    // BLE beacon clears grace deadline - we're near!
    if self.grace_deadline.is_some() {
        self.grace_deadline = None;
        // ... state transition logic ...
    }
}
```

**No changes needed here** - it's ready to use!

---

### Step 5: Make Proximity Use BLE as Primary Signal

**File:** `apps/agent-macos/src/proximity.rs` (check `tick()` or state evaluation)

**Ensure proximity logic checks BLE first:**

```rust
pub fn tick(&mut self, now: Instant) -> Option<ProxState> {
    // Check BLE signal first
    if let Some(last_ble) = self.last_ble_seen {
        let age = now.duration_since(last_ble);
        
        if age < NEAR_THRESHOLD {  // e.g., 10 seconds
            // BLE says NEAR → trust it
            return self.transition_to(ProxState::Near, now);
        } else if age < FAR_THRESHOLD {  // e.g., 30 seconds
            // Grace period - don't change state yet
            return None;
        } else {
            // BLE timeout → FAR
            return self.transition_to(ProxState::Far, now);
        }
    }
    
    // Fallback to TLS heartbeat (secondary)
    // ... existing TLS logic ...
}
```

**Note:** Exact thresholds and hysteresis logic may already exist - verify current implementation.

---

## Testing Plan

### Phase 1: Verify Wiring (5 minutes)

1. **Rebuild macOS agent**
   ```bash
   cd /Users/cmbosys/Work/Armadilo
   cargo build --bin agent-macos
   ```

2. **Run agent with logs**
   ```bash
   RUST_LOG=info cargo run --bin agent-macos
   ```

3. **Expected logs:**
   ```
   ble.token.valid fp_suffix=sha256:5084... rssi=Some(-45)
   prox.ble_seen fp=sha256:5084... rssi=Some(-45)
   ```

4. **Check proximity state:**
   - Should show `near` or similar
   - `last_ble_seen` should update continuously

### Phase 2: State Transitions (10 minutes)

1. **Test NEAR → FAR:** 
   - With phone nearby, verify `prox=near`
   - Turn off iPhone Bluetooth
   - Wait 10-30 seconds
   - **Expected:** `prox=far` + vault locks

2. **Test FAR → NEAR:**
   - Turn iPhone Bluetooth back on
   - **Expected:** `prox=near` within 1-3 seconds
   - Vault can be unlocked again

3. **Test Background:**
   - Lock iPhone screen
   - **Expected:** BLE continues, proximity stays `near`

### Phase 3: Vault Gating (5 minutes)

1. **Near + unlocked:**
   - Browser extension fill should work

2. **Far (phone away):**
   - Browser extension should show "locked" or "far"
   - Credential requests should fail

---

## Success Criteria

- ✅ `prox.ble_seen` logs appear alongside `ble.token.valid`
- ✅ Proximity state changes to `near` when phone nearby
- ✅ Proximity state changes to `far` when phone removed/BT off
- ✅ Vault locks when proximity goes `far`
- ✅ Vault can unlock when proximity returns to `near`
- ✅ Works with iPhone screen locked (background BLE)

---

## Potential Issues & Solutions

### Issue 1: Proximity Mutex Already Held
**Symptom:** `prox.lock_failed` logs  
**Solution:** Ensure you're not calling from inside another proximity lock

### Issue 2: State Doesn't Change
**Symptom:** `prox.ble_seen` logs but state stays `far`  
**Solution:** Check proximity `tick()` logic - may need to explicitly check BLE timestamp

### Issue 3: Too Sensitive (Flapping)
**Symptom:** Rapid near/far transitions  
**Solution:** Add hysteresis:
- Require X consecutive failures before going `far`
- Require X consecutive successes before going `near`

### Issue 4: Compilation Errors
**Symptom:** "proximity not found" or type mismatches  
**Solution:** Check:
- `proximity` module is imported correctly
- `Arc<Mutex<Proximity>>` type matches
- `Instant` is from `std::time::Instant`

---

## Code Locations Reference

| File | Line | What |
|------|------|------|
| [ble_scanner.rs](file:///Users/cmbosys/Work/Armadilo/apps/agent-macos/src/ble_scanner.rs#L25-L29) | 25-29 | BleScanner struct definition |
| [ble_scanner.rs](file:///Users/cmbosys/Work/Armadilo/apps/agent-macos/src/ble_scanner.rs#L192-L203) | 192-203 | Token validation (TODO location) |
| [proximity.rs](file:///Users/cmbosys/Work/Armadilo/apps/agent-macos/src/proximity.rs#L314-L320) | 314-320 | `note_ble_seen()` method |
| [main.rs](file:///Users/cmbosys/Work/Armadilo/apps/agent-macos/src/main.rs) | ~200-250 | BLE scanner initialization |

---

## Next Steps After This Works

1. **Tune parameters:**
   - NEAR_THRESHOLD (how quickly to declare "near")
   - FAR_THRESHOLD (how long to wait before "far")
   - Grace periods

2. **Remove TLS heartbeat dependency:**
   - Keep TLS for pairing + Face ID only
   - Proximity entirely driven by BLE

3. **Add crypto test vectors:**
   - Ensure k_ble derivation never drifts
   - Same tests on iOS and macOS

4. **Soak test:**
   - 8-hour overnight test
   - Phone locked, backgrounded
   - Verify stability

---

## Estimated Timeline

- **Step 1-3 (Code changes):** 20 minutes
- **Step 4-5 (Verification):** 10 minutes  
- **Testing Phase 1-2:** 15 minutes
- **Testing Phase 3:** 5 minutes
- **Debugging buffer:** 15 minutes

**Total:** ~60 minutes to fully working proximity

---

## Questions to Answer

Before starting implementation:

1. **Where is proximity currently created in main.rs?**
   - Need to confirm it exists before BLE scanner creation
   
2. **How is proximity currently accessed?**
   - Is it already an `Arc<Mutex<...>>`?
   - Or do we need to wrap it?

3. **What's the current proximity tick frequency?**
   - Does it run every second? Every 5 seconds?
   - This affects how quickly state changes

Would you like me to examine these files to answer these questions first, or do you want to implement based on this plan?
