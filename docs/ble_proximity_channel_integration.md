# Production-Grade BLE → Proximity Integration

**Architecture:** Channel-based event system (no mutexes)  
**Recommendation:** A (Production) - Robust, deadlock-free, commercial-ready

---

## Current Code Structure (Ground Truth)

### 1. Proximity Creation (main.rs:180-186)
```rust
let prox = proximity::Proximity::new(
    cfg.prox_mode,
    Duration::from_millis(cfg.prox_grace_ms),
    Duration::from_secs(cfg.prox_pause_default_s),
    None, // event callback
);
let proximity = Arc::new(Mutex::new(prox));  // ← Currently using Mutex
```

### 2. Proximity Tick Loop (main.rs:191-198)
```rust
let prox_clone = proximity.clone();
tokio::spawn(async move {
    loop {
        tokio::time::sleep(Duration::from_millis(500)).await;  // ← 500ms tick
        let now = Instant::now();
        let mut p = prox_clone.lock().await;  // ← tokio::sync::Mutex
        p.tick(now);
    }
});
```

### 3. BLE Scanner Creation (main.rs:210)
```rust
let scanner_result = match ble_scanner::BleScanner::new().await {
    Ok(s) => Ok(s),
    Err(e) => Err(format!("...")),
};
// ← No proximity parameter currently
```

---

## Production Architecture: Channel-Based Events

### Why This is Superior

✅ **No deadlocks** - Single owner, no lock contention  
✅ **Clear data flow** - BLE → Event → Proximity (unidirectional)  
✅ **Testable** - Can send test events, mock proximity responses  
✅ **Auditable** - All proximity changes go through event log  
✅ **Scalable** - Add more event sources without touching proximity code

---

## Implementation Steps

### Step 1: Define Proximity Event Types

**File:** `apps/agent-macos/src/proximity.rs` (add at top after imports)

```rust
use tokio::sync::mpsc;

/// Events that affect proximity state
#[derive(Debug, Clone)]
pub enum ProxEvent {
    /// BLE beacon validated - device is near
    BleSeen {
        fp: String,
        rssi: Option<i16>,
        timestamp: std::time::Instant,
    },
    
    /// TLS heartbeat (secondary/diagnostic only)
    TlsHeartbeat {
        timestamp: std::time::Instant,
    },
    
    /// Manual state override (for testing/debugging)
    #[allow(dead_code)]
    ForceState {
        state: ProxState,
    },
}

/// Channel sender type for convenience
pub type ProxEventSender = mpsc::Sender<ProxEvent>;
```

---

### Step 2: Refactor Proximity to Event-Driven Owner

**File:** `apps/agent-macos/src/main.rs` (replace lines 180-199)

```rust
// Create proximity instance (still owned, but no Arc<Mutex>)
let prox = proximity::Proximity::new(
    cfg.prox_mode,
    Duration::from_millis(cfg.prox_grace_ms),
    Duration::from_secs(cfg.prox_pause_default_s),
    None, // event callback
);

// Create event channel
let (prox_tx, mut prox_rx) = tokio::sync::mpsc::channel::<proximity::ProxEvent>(256);

// Spawn single-owner proximity task
tokio::spawn(async move {
    let mut prox_state = prox;  // Move ownership into this task
    let mut tick_interval = tokio::time::interval(Duration::from_millis(500));
    
    loop {
        tokio::select! {
            // Regular tick for timeouts/grace periods
            _ = tick_interval.tick() => {
                let now = Instant::now();
                if let Some(new_state) = prox_state.tick(now) {
                    info!(event = "prox.state_change", state = ?new_state);
                    // TODO: Emit state changes to vault gating
                }
            }
            
            // Handle incoming proximity events
            Some(event) = prox_rx.recv() => {
                match event {
                    proximity::ProxEvent::BleSeen { fp, rssi, timestamp } => {
                        prox_state.note_ble_seen(timestamp, rssi);
                        info!(
                            event = "prox.ble_update",
                            fp = %fp,
                            rssi = ?rssi
                        );
                    }
                    proximity::ProxEvent::TlsHeartbeat { timestamp } => {
                        // Optional: keep TLS as secondary signal
                        // prox_state.note_tls_seen(timestamp);
                    }
                    proximity::ProxEvent::ForceState { state } => {
                        info!(event = "prox.forced", state = ?state);
                        // For testing/debug only
                    }
                }
            }
        }
    }
});

// Store sender for other components to use
let prox_event_tx = prox_tx.clone();
```

---

### Step 3: Update BLE Scanner to Use Channel

**File:** `apps/agent-macos/src/ble_scanner.rs`

**Modify struct (around line 25):**
```rust
pub struct BleScanner {
    adapter: Adapter,
    paired_devices: Arc<RwLock<HashMap<String, Vec<u8>>>>,
    prox_tx: mpsc::Sender<crate::proximity::ProxEvent>,  // ADD THIS
}
```

**Update constructor (around line 35):**
```rust
pub async fn new(
    prox_tx: mpsc::Sender<crate::proximity::ProxEvent>  // ADD PARAMETER
) -> Result<Self, Box<dyn std::error::Error>> {
    let manager = Manager::new().await?;
    let adapters = manager.adapters().await?;
    
    let adapter = adapters
        .into_iter()
        .next()
        .ok_or("No Bluetooth adapters found")?;
    
    Ok(Self {
        adapter,
        paired_devices: Arc::new(RwLock::new(HashMap::new())),
        prox_tx,  // STORE IT
    })
}
```

**Update token validation (around line 200):**
```rust
if self.validate_token_for_device(token_bytes, k_ble, fp_suffix, bucket) {
    info!(
        event = "ble.token.valid",
        fp_suffix = %fp_suffix,
        rssi = ?rssi,
        bucket_delta = bucket_delta,
        bucket = bucket
    );
    
    // Send event to proximity (non-blocking)
    let _ = self.prox_tx.try_send(crate::proximity::ProxEvent::BleSeen {
        fp: fp_suffix.to_string(),
        rssi,
        timestamp: std::time::Instant::now(),
    });
    
    return;
}
```

**Note:** Using `try_send` instead of `await send` keeps the scanner loop non-blocking. If the channel is full (unlikely with 256 capacity), we just drop the event rather than blocking BLE scanning.

---

### Step 4: Pass Channel to BLE Scanner on Creation

**File:** `apps/agent-macos/src/main.rs` (update line 210)

```rust
// OLD
let scanner_result = match ble_scanner::BleScanner::new().await {

// NEW  
let scanner_result = match ble_scanner::BleScanner::new(prox_event_tx.clone()).await {
```

**Make sure `prox_event_tx` is accessible** in the BLE spawn block. You may need to clone it before the spawn:

```rust
// Before line 208 spawn
let prox_tx_for_ble = prox_event_tx.clone();

tokio::spawn(async move {
    let scanner_result = match ble_scanner::BleScanner::new(prox_tx_for_ble).await {
        // ... rest of code
    };
    // ...
});
```

---

### Step 5: Make Proximity Use BLE as Primary Signal

**File:** `apps/agent-macos/src/proximity.rs`

**In the `tick()` method**, ensure BLE timestamp is checked first:

```rust
pub fn tick(&mut self, now: Instant) -> Option<ProxState> {
    // 1. Check BLE signal FIRST (most reliable)
    if let Some(last_ble) = self.last_ble_seen {
        let ble_age = now.duration_since(last_ble);
        
        // Near threshold: 6 seconds  
        if ble_age < Duration::from_secs(6) {
            if self.state != ProxState::Near {
                info!(event = "prox.ble_near", ble_age_ms = ble_age.as_millis());
                return self.transition_to_near(now);
            }
            return None;  // Already near, no change
        }
        
        // Far threshold: 15 seconds (with hysteresis)
        if ble_age > Duration::from_secs(15) {
            if self.state == ProxState::Near {
                info!(event = "prox.ble_far", ble_age_ms = ble_age.as_millis());
                return self.transition_to_far(now);
            }
        }
    }
    
    // 2. Check grace/pause timers
    // ... existing grace logic ...
    
    // 3. TLS heartbeat as fallback/diagnostic only
    // (optional, or remove entirely)
    
    None
}
```

**Add helper methods if they don't exist:**
```rust
fn transition_to_near(&mut self, now: Instant) -> Option<ProxState> {
    self.state = ProxState::Near;
    self.grace_deadline = None;  // Clear any grace period
    Some(ProxState::Near)
}

fn transition_to_far(&mut self, now: Instant) -> Option<ProxState> {
    self.state = ProxState::Far;
    // Optionally set grace deadline
    Some(ProxState::Far)
}
```

---

## Testing & Validation

### Compile Check
```bash
cd /Users/cmbosys/Work/Armadilo
cargo check --bin agent-macos
```

### Run Agent
```bash
RUST_LOG=info cargo run --bin agent-macos
```

### Expected Log Sequence
```
[INFO] Starting BLE scanner for proximity detection
[INFO] BLE scanner initialized successfully
[INFO] Derived k_ble for device fp_suffix=sha256:5
[INFO] BLE scanner loaded 1 device keys
...
[INFO] ble.token.valid fp_suffix=sha256:5084... rssi=Some(-45)
[INFO] prox.ble_update fp=sha256:5084... rssi=Some(-45)
[INFO] prox.ble_near ble_age_ms=150
[INFO] prox.state_change state=Near
```

### State Transition Tests

**1. Near Detection (phone nearby):**
- BLE tokens validated every 1-2s
- `prox.state_change state=Near` appears
- Vault should unlock (if auth valid)

**2. Far Detection (phone removed):**
- Turn off iPhone Bluetooth
- Wait ~15 seconds
- `prox.ble_far ble_age_ms=15000+`
- `prox.state_change state=Far`
- Vault should lock

**3. Return After Far:**
- Turn Bluetooth back on
- Within 3 seconds: `prox.state_change state=Near`
- Vault can unlock again

---

## Advantages Over Mutex Approach

| Concern | Mutex (Option B) | Channel (Option A) |
|---------|------------------|-------------------|
| Deadlock risk | ⚠️ Multiple lock holders | ✅ Single owner |
| Lock contention | ⚠️ BLE + tick + bridge compete | ✅ No locks |
| Testing | ❌ Hard (need mock mutexes) | ✅ Easy (send test events) |
| Debugging | ❌ Lock state unclear | ✅ Event log shows flow |
| Performance | ⚠️ Lock overhead | ✅ Lock-free |
| Commercial grade | ⚠️ Works but risky | ✅ Production pattern |

---

## Migration Difficulty

**Very Low** - Your current code is already well-structured:
- ✅ Proximity already has clean methods (`note_ble_seen`, `tick`)
- ✅ BLE scanner is already separate spawn
- ✅ No complex mutex patterns to untangle

**Total changes:** ~50 lines across 3 files  
**Estimated time:** 30-45 minutes  
**Risk level:** Low (no breaking changes to core logic)

---

## Alternative: Quick Mutex Fix (Not Recommended)

If you *must* go with mutex wiring:

**Only change:** Pass `Arc<tokio::sync::Mutex<Proximity>>` to BLE scanner  
**Line of code:** 
```rust
// main.rs:210
BleScanner::new(Arc::clone(&proximity)).await  // But don't do this
```

**Why I don't recommend:**
- Adds lock contention 
- Risk of deadlock if bridge also locks proximity
- Makes testing harder
- Not "ship to real users" quality

---

## Next Action

**Choose one:**

1. ✅ **Implement Channel (recommended)** - I'll guide you step-by-step
2. ⚠️ **Quick Mutex** - Works, but tech debt

Let me know which, and I'll provide exact code or walk through the implementation.
