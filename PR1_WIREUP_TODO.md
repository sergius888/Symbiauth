# PR1 Wire-Up Remaining Tasks

## ✅ What's Complete

1. **Core Modules** (committed: `5922ead`)
   - `error.rs` - ApiError with HTTP codes + err_reason
   - `ratelimit.rs` - TokenBucket + auth concurrency (5/min, 3 global, 1 per origin)
   - `idempotency.rs` - SQLite persistence with TTL GC
   - `config.rs` - Env var loading with safe defaults
   - All modules exported from `lib.rs`

2. **Tests** (all 23 passing)
   - 15 unit tests in modules
   - 8 integration tests in `gating_tests.rs`
   - Coverage: 401/403, rate limiting, concurrency, idempotency

3. **Struct Modification**
   - Added `rate_limiter` and `idempotency` fields to `UnixBridge`

## 🔧 Remaining Wire-Up Work

### 1. Constructor Update (`UnixBridge::new`)
**File:** `apps/agent-macos/src/bridge.rs` line ~219

```rust
pub async fn new(
    socket_path: &str,
    rate_limiter: Arc<Mutex<RateLimiter>>,
    idempotency: Arc<Idempotency>,
) -> Result<Self, BridgeError> {
    // ... existing setup ...
    
    Ok(UnixBridge {
        listener,
        socket_path: socket_path.to_string(),
        rate_limiter,
        idempotency,
    })
}
```

### 2. Main.rs Initialization
**File:** `apps/agent-macos/src/main.rs` after line ~80

```rust
// Load config
let cfg = config::AgentConfig::from_env();

// Initialize rate limiter
let rate_limiter = Arc::new(Mutex::new(RateLimiter::new(
    cfg.rate_per_origin_per_min,
    cfg.rate_per_origin_per_min, // capacity = per_min for burst
    cfg.auth_max_global,
    cfg.auth_max_per_origin,
)));

// Initialize idempotency store
let idem_path = arm_dir.join("idempotency.db");
let idem_conn = rusqlite::Connection::open(&idem_path)?;
let idempotency = Arc::new(Idempotency::new(idem_conn)?);

// Spawn GC loop
let idem_clone = idempotency.clone();
let ttl = cfg.idempotency_ttl_s;
tokio::spawn(async move {
    loop {
        tokio::time::sleep(Duration::from_secs(300)).await;
        let _ = idem_clone.gc(ttl);
    }
});

// Update UnixBridge::new call
let unix_bridge = UnixBridge::new(
    &socket_path,
    rate_limiter.clone(),
    idempotency.clone(),
).await?;
```

### 3. Ingress Rate Limiting
**File:** `apps/agent-macos/src/bridge.rs` line ~380 (in message loop)

After parsing JSON, before routing:

```rust
// Extract metadata
let msg_type = json_msg.get("type").and_then(|v| v.as_str()).unwrap_or("<no_type>");
let start = Instant::now();

// Rate limit check (skip for internal messages)
if should_rate_limit(msg_type) {
    if let Some(origin) = extract_origin(&json_msg) {
        let mut rl = self.rate_limiter.lock().await;
        if !rl.allow_origin(&origin) {
            let err = json!({
                "type": "error",
                "err_code": 429,
                "err_reason": "too_many_requests",
                "message": "Rate limit exceeded",
                "corr_id": corr_id_opt.as_ref().unwrap_or(&"".to_string()),
                "latency_ms": start.elapsed().as_millis(),
            });
            Self::send_message(&w_arc, &err).await?;
            continue;
        }
    }
}

fn should_rate_limit(msg_type: &str) -> bool {
    matches!(msg_type, "cred.get" | "cred.list" | "vault.read" | "vault.write" | "auth.proof")
}

fn extract_origin(msg: &Value) -> Option<String> {
    msg.get("origin").and_then(|v| v.as_str()).map(|s| s.to_string())
}
```

### 4. Idempotent Writes
**File:** `apps/agent-macos/src/bridge.rs` in `vault.write` handler (line ~680)

Before existing write logic:

```rust
"vault.write" => {
    // Check idempotency key
    if let Some(idem_key) = json_msg.get("idempotency_key").and_then(|v| v.as_str()) {
        if self.idempotency.was_applied(idem_key).unwrap_or(false) {
            // Already applied, return success without re-writing
            let response = json!({
                "type": "vault.ack",
                "op": "write",
                "ok": true,
                "replayed": true,
                "corr_id": corr_id_opt.as_ref().unwrap_or(&"".to_string()),
            });
            Self::send_message(&w_arc, &response).await?;
            continue;
        }
    } else {
        // Missing idempotency key for write
        let err = json!({
            "type": "error",
            "err_code": 400,
            "err_reason": "bad_request",
            "message": "idempotency_key required for writes",
            "corr_id": corr_id_opt.as_ref().unwrap_or(&"".to_string()),
        });
        Self::send_message(&w_arc, &err).await?;
        continue;
    }
    
    // ... existing write logic ...
    
    // After successful write, mark idempotency key
    if let Some(idem_key) = json_msg.get("idempotency_key").and_then(|v| v.as_str()) {
        let _ = self.idempotency.mark_applied(idem_key);
    }
}
```

### 5. Auth Prompt Guard (RAII)
**File:** `apps/agent-macos/src/bridge.rs` 

Add helper struct at top of file:

```rust
struct AuthPromptGuard<'a> {
    rate_limiter: &'a Arc<Mutex<RateLimiter>>,
    origin: String,
}

impl<'a> AuthPromptGuard<'a> {
    fn new(rate_limiter: &'a Arc<Mutex<RateLimiter>>, origin: String) -> Option<Self> {
        let mut rl = rate_limiter.blocking_lock();
        if rl.try_enter_auth(&origin) {
            Some(Self { rate_limiter, origin })
        } else {
            None
        }
    }
}

impl Drop for AuthPromptGuard<'_> {
    fn drop(&mut self) {
        let mut rl = self.rate_limiter.blocking_lock();
        rl.leave_auth(&self.origin);
    }
}
```

When creating auth.request (look for `"type": "auth.request"`):

```rust
let guard = AuthPromptGuard::new(&self.rate_limiter, origin.clone())
    .ok_or_else(|| /* return 429 error */)?;
    
// Send auth.request...
// Guard automatically releases on drop
```

### 6. Module Imports
**File:** `apps/agent-macos/src/bridge.rs` top of file

Add:
```rust
use crate::config;
use crate::error::ApiError;
use crate::idempotency::Idempotency;
use crate::ratelimit::RateLimiter;
use std::time::Instant;
```

### 7. Main.rs Module Imports
**File:** `apps/agent-macos/src/main.rs` top of file

Add:
```rust
mod config;
mod error;
mod idempotency;
mod ratelimit;
```

## 🧪 Testing After Wire-Up

Run:
```bash
cargo test -p agent-macos
cargo build -p agent-macos
```

Manual validation:
1. Start agent
2. Fire 6 requests for same origin in 60s → 6th gets 429
3. Write with idempotency key, restart, retry → gets replayed response
4. Trigger step-up → first request creates prompt (check logs)

## 📝 Next Steps

1. Apply changes 1-7 above
2. Fix any compilation errors
3. Run tests
4. Manual validation
5. Commit: "feat(pr1): wire gating into bridge"
6. Push for CI
7. Merge to main

## ⚠️ Notes

- Keep existing error handlers intact for now (don't refactor)
- Map to ApiError only at boundary
- Auth prompt guard location: search for `json!({"type":"auth.request"` to find exact spot
- If `handle_connection` is async, use `.lock().await` instead of `.blocking_lock()`
