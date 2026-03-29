# Commercial Production Roadmap

**Updated:** February 2, 2026  
**Current Status:** BLE proximity core complete, production hardening needed

---

## Critical Question: Is Vault Gating Driven by ProxState?

**Answer from code inspection (bridge.rs:689):**

```rust
if matches!(p.state(), ProxState::Far) {
    // Reject vault operations when Far
}
```

**Status:** ✅ **YES** - Vault gating checks `ProxState`  
**But:** Need to verify it's **strictly** proximity-driven (not mixed with TLS heartbeats)

**Next code task:** Ensure proximity is **authoritative** and TLS is secondary/diagnostic only

---

## Phase 1: Make Proximity Authoritative (NEXT)

### 1.1 - Remove TLS from Proximity Decision
- [ ] **Audit all proximity state changes** - grep for `note_tls_seen`, `on_tls_up`
- [ ] **Make BLE primary signal** - Only BLE updates Near/Far (✅ Done in tick())
- [ ] **TLS becomes diagnostic only** - Keep for pairing + Face ID approvals
- [ ] **Verify vault gating** - Check bridge.rs vault operations only use ProxState

**Files to check:**
- `bridge.rs` lines 772-774 (TLS heartbeat handlers)
- `bridge.rs` line 689 (vault gating)
- `proximity.rs` (ensure TLS doesn't drive state)

---

### 1.2 - Add Backpressure Monitoring
**Problem:** `try_send()` silently drops events if channel full

**Solution:**
```rust
// In ble_scanner.rs
match self.prox_tx.try_send(...) {
    Ok(_) => {},
    Err(mpsc::error::TrySendError::Full(_)) => {
        warn!(event = "ble.prox_event.drop", reason = "channel_full");
        // Inc counter for metrics
    }
    Err(mpsc::error::TrySendError::Closed(_)) => {
        error!(event = "ble.prox_event.drop", reason = "channel_closed");
    }
}
```

**Also:**
- [ ] Monitor drop rate in logs
- [ ] Increase channel size if needed (currently 256)

---

### 1.3 - Per-Device Tracking (Future)
**Current:** Single global `last_ble_seen`  
**Future Multi-Device:**
```rust
// In Proximity struct
last_ble_seen: HashMap<String, Instant>, // fp -> timestamp
```

**Logic:** Near if **any** approved device is near  
**Priority:** Low (single device works for v1)

---

## Phase 2: iOS Background Reliability (CRITICAL)

### 2.1 - Real Device Testing

**Must-Run Tests:**
- [ ] **Overnight soak** (8-12 hours, phone locked)
- [ ] **Low Power Mode** enabled
- [ ] **Phone in pocket** (RSSI attenuation test)
- [ ] **Mac sleep/wake cycles**
- [ ] **iPhone locked 30+ minutes**
- [ ] **App killed from switcher** (harshest test)

**Metrics to Record:**
- Avg beacons/minute
- Max gap between `ble.token.valid`
- RSSI distribution
- Battery drain %/hour

---

### 2.2 - Threshold Tuning

**Current (may be too aggressive):**
- Near: 8s
- Far: 15s
- Hysteresis: 7s

**Production Recommendation:**
- Near: **10s**
- Far: **45-90s** (based on real scan data)
- Consecutive misses: **3 failed scan windows** before Far
- Immediate lock: User can force lock anytime

**Why longer Far timeout?**
- iOS may throttle advertising on thermal/battery
- Low Power Mode changes behavior
- Prevents "walked 2 meters, vault locked" bad UX
- Want "really walked away", not "brief wobble"

**Config-driven (recommended):**
```rust
// In config or env
ARM_BLE_NEAR_THRESHOLD_S=10
ARM_BLE_FAR_TIMEOUT_S=60
ARM_BLE_MISS_COUNT=3
```

---

### 2.3 - Battery Profiling

**Tool:** Xcode Instruments → Energy Log

**Test:**
1. Run 8-hour overnight test
2. Record battery % before/after
3. Goal: **<5% drain per day** from BLE proximity alone

**If excessive:**
- Reduce advertising frequency
- Implement conditional advertising (only when vault operations likely)
- Add "pause proximity" mode for user override

---

## Phase 3: Crypto Test Vectors (MUST)

### 3.1 - Rust Test

```rust
#[cfg(test)]
mod tests {
    #[test]
    fn test_k_ble_derivation_deterministic() {
        // Fixed inputs
        let device_fp = "sha256:5084...";
        let sk = /* fixed wrap secret */;
        let ios_pub = /* fixed SEC1 point */;
        
        // Derive salt
        let salt = derive_salt_from_fp(device_fp);
        assert_eq!(hex::encode(salt), "expected_hex");
        
        // Derive k_ble
        let k_ble = derive_ble_key(&sk, &ios_pub, &salt).unwrap();
        assert_eq!(hex::encode(k_ble), "expected_k_ble_hex");
    }
    
    #[test]
    fn test_hmac_token_matches_ios() {
        let k_ble = hex::decode("...").unwrap();
        let bucket: u64 = 12345;
        
        let token = compute_bucket_token(&k_ble, bucket);
        assert_eq!(hex::encode(token), "expected_token_hex");
    }
}
```

---

### 3.2 - Swift Test

```swift
func testKBLEDerivationMatchesRust() {
    // Same fixed inputs as Rust test
    let deviceFp = "sha256:5084..."
    let ecdh = /* fixed shared secret */
    
    let kBLE = SessionKeyDerivation.deriveK_BLE(
        ecdh: ecdh,
        deviceFingerprint: deviceFp
    )
    
    XCTAssertEqual(kBLE.hexString, "expected_k_ble_hex")
}

func testHMACTokenMatchesRust() {
    let kBLE = Data(hexString: "...")
    let bucket: UInt64 = 12345
    
    let token = BLEAdvertiser.computeToken(kBLE: kBLE, bucket: bucket)
    XCTAssertEqual(token, 0x12345678) // Expected 4-byte token
}
```

**Critical:** Same test vectors on both platforms = never drift again

---

## Phase 4: State Machine Tests

```rust
#[test]
fn test_far_to_near_on_ble() {
    let mut prox = Proximity::new(...);
    assert_eq!(prox.state(), ProxState::Far);
    
    prox.note_ble_seen(Instant::now(), Some(-45));
    assert!(matches!(prox.state(), ProxState::NearLocked | ProxState::NearUnlocked));
}

#[test]
fn test_near_to_far_on_timeout() {
    let mut prox = Proximity::new(...);
    prox.note_ble_seen(Instant::now(), Some(-45));
    
    // Wait 15+ seconds
    let future = Instant::now() + Duration::from_secs(16);
    prox.tick(future);
    
    assert_eq!(prox.state(), ProxState::Far);
}
```

---

## Phase 5: Repository Hygiene

### 5.1 - Secret Scanning

```bash
# Install tools
brew install gitleaks trufflehog

# Scan repo history
gitleaks detect --source /Users/cmbosys/Work/Armadilo --verbose

# Or
trufflehog git file:///Users/cmbosys/Work/Armadilo
```

**What to look for:**
- Private keys (`.pem`, `.key`, `.p12`, `.der`)
- API tokens
- `server_identity` files
- Hardcoded secrets in code
- Logs with fingerprints

**If found:**
1. **Rotate immediately** (assume compromised)
2. Remove from history with `git filter-repo`
3. Update `.gitignore`

---

### 5.2 - .gitignore Audit

**Must ignore:**
```gitignore
# Rust
target/

# Xcode
DerivedData/
build/
*.xcresult
*.xcuserstate
*.xcuserdata/

# Secrets
*.pem
*.key
*.p12
*.der
*.mobileprovision
server_identity*
.env

# Logs
*.log
*.ndjson

# macOS
.DS_Store
```

---

### 5.3 - Warning Cleanup Sprint

**Goal:** 97 Rust + 35 iOS warnings → **~10 total**

**Strategy:**
1. Remove dead files (unknown purpose ones)
2. Fix unused imports/variables
3. Run `cargo clippy --fix`
4. Run Xcode "Fix All Issues"
5. Enable `-D warnings` in CI later (not now)

---

## Phase 6: Production Distribution

### 6.1 - macOS Agent

**Development:**
```bash
cargo build --release --bin agent-macos
# Binary at: target/release/agent-macos
```

**Production:**
1. Sign with Apple Developer ID
2. Notarize with `notarytool`
3. Distribute as:
   - Standalone binary + installer
   - Or bundled in macOS TLS terminator app

---

### 6.2 - iOS App

**TestFlight (Recommended First):**
1. Archive in Xcode
2. Upload to TestFlight
3. Invite internal testers
4. Iterate based on feedback

**App Store (Later):**
1. Privacy policy required
2. App Review guidelines compliance
3. Metadata + screenshots
4. Submit for review

---

### 6.3 - macOS TLS Terminator

**Development:**
- Run from Xcode

**Production:**
- Archive → Export → Sign + Notarize
- Distribute as `.app` or `.pkg`

---

## Phase 7: Operational Readiness

### 7.1 - Diagnostic UI (Must Have)

**iOS:**
- Connection status
- Last BLE seen timestamp
- RSSI value
- "Export logs" button
- Pairing status

**macOS:**
- Menu bar: Near/Far/Locked icon
- Panel: Last seen, RSSI, state
- "Open logs folder"
- "Reset pairing"

**Why critical:** Without diagnostics, you die in support

---

### 7.2 - Logging Strategy

**Production logs should:**
- Be structured (JSON or NDJSON)
- Include timestamps + correlation IDs
- Omit sensitive data (no full fingerprints in prod)
- Be exportable by user

**Levels:**
- ERROR: vault gating failures, crypto errors
- WARN: channel drops, timeout transitions
- INFO: state changes, BLE validation
- DEBUG: raw tokens, RSSI (dev only)

---

## Timeline Estimate

| Phase | Duration | Priority |
|-------|----------|----------|
| **Phase 1** - Proximity authoritative | 2-4 hours | HIGH |
| **Phase 2** - iOS testing + tuning | 3-5 days | CRITICAL |
| **Phase 3** - Crypto tests | 4-6 hours | HIGH |
| **Phase 4** - State machine tests | 2-3 hours | MEDIUM |
| **Phase 5** - Repo hygiene | 1-2 days | HIGH |
| **Phase 6** - Distribution setup | 2-3 days | MEDIUM |
| **Phase 7** - Operational polish | 3-5 days | HIGH |

**Total to "shippable beta":** 2-3 weeks

---

## Success Criteria (Definition of "Production Ready")

- [ ] **Vault gating strictly driven by ProxState**
- [ ] **TLS not used for proximity** (pairing + Face ID only)
- [ ] **8-hour soak test passes** (phone locked, backgrounded)
- [ ] **Battery < 5%/day** from BLE proximity
- [ ] **Crypto test vectors pass** on both platforms
- [ ] **Zero critical warnings**
- [ ] **No secrets in repo** (verified by scanning)
- [ ] **TestFlight beta deployed**
- [ ] **Diagnostic UI functional** on both platforms
- [ ] **User can export logs** for troubleshooting

---

## Current Status Summary

✅ **Complete:**
- BLE proximity protocol (ARM/BLE/v1)
- Channel-based integration
- 15-second timeout (needs tuning)
- Production-grade architecture

⏳ **In Progress:**
- Vault gating verification
- TLS→proximity separation

❌ **Not Started:**
- Real device testing
- Crypto test vectors
- Repository hygiene
- Distribution setup

**Next Immediate Step:** Verify and enforce ProxState as sole vault authority
