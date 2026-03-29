# GitHub Issues for Armadillo Roadmap

Copy/paste these into GitHub Issues to track work.

---

## M1: Agent Polish

### Issue 1: Finalize Proximity Modes

**Title:** Implement Production Proximity Modes (auto_unlock, prox_first_use, prox_intent)

**Labels:** `enhancement`, `security`, `M1`

**Description:**

Finalize the proximity state machine with three production modes:

**Modes:**
- `auto_unlock`: Unlock automatically when in proximity (default dev)
- `prox_first_use`: Require Face ID on first use per session, then proximity
- `prox_intent`: Require explicit intent + "Still around?" timer (production default)

**Requirements:**
- [x] Basic proximity detection (implemented)
- [ ] Mode selection via policy
- [ ] `prox_intent`: pause timer + "Still around?" prompt
- [ ] `prox_first_use`: session tracking + Face ID gate
- [ ] Mode configuration in `policy.yaml`
- [ ] Default to `prox_intent` for production

**Acceptance Criteria:**
- [ ] Unit tests for state machine transitions
- [ ] Each mode behavior validated
- [ ] "Still around?" timeout configurable (default: 5min)
- [ ] Mode persists across agent restarts

**Files:**
- `apps/agent-macos/src/proximity.rs`
- `apps/agent-macos/src/policy.rs`
- Policy schema update

---

### Issue 2: Audit Log with Hash Chain

**Title:** Implement Hash-Chained Audit Log (NDJSON)

**Labels:** `security`, `audit`, `M1`

**Description:**

Create tamper-evident audit log using hash chaining:

**Format:** NDJSON at `~/.armadillo/audit.ndjson`

**Each event:**
```json
{
  "ts": "2025-12-15T12:00:00Z",
  "seq": 123,
  "prev_hash": "sha256:abc...",
  "event": "auth.granted",
  "corr_id": "req-uuid",
  "origin": "https://github.com",
  "decision": "allow",
  "via": "proximity",
  "latency_ms": 45,
  "hash": "sha256:def..."
}
```

**Hash Chain:**
```
hash = SHA256(ts || seq || prev_hash || event_data)
```

**Requirements:**
- [ ] NDJSON append-only writer
- [ ] Hash chain computation
- [ ] Integrity verification tool
- [ ] Events: `auth.granted`, `auth.denied`, `policy.changed`, `cert.rotated`
- [ ] Include `corr_id`, `origin`, `decision`, `via`, `latency_ms`

**Acceptance Criteria:**
- [ ] Hash chain validates from genesis
- [ ] Tamper detection (modified event breaks chain)
- [ ] CLI: `agent-cli audit verify`
- [ ] Log rotation with boundary hash
- [ ] Unit test: continuity property

**Files:**
- `apps/agent-macos/src/audit.rs` (expand existing)
- `apps/agent-macos/src/bin/agent-cli.rs` (`audit` subcommand)

---

### Issue 3: Origin Canonicalization

**Title:** Strict Origin Canonicalization for Credential Scopes

**Labels:** `security`, `bug`, `M1`

**Description:**

Prevent origin bypass via scheme/host/port variations.

**Problem:**
```
https://GitHub.com:443/login
https://github.com/login
http://github.com:80/login
```
Should these be same origin? Need strict rules.

**Requirements:**
- [ ] Normalize scheme to lowercase
- [ ] Normalize host to lowercase (IDNA for internationalized domains)
- [ ] Strip default ports (`:443` for https, `:80` for http)
- [ ] Reject invalid/suspicious origins
- [ ] Apply during credential scope matching

**Canonicalization Rules:**
```rust
https://GitHub.COM:443/path → https://github.com/path
http://Example.org:80/       → http://example.org/
HTTPS://foo.com              → https://foo.com/
```

**Acceptance Criteria:**
- [ ] Table-driven tests with 20+ cases
- [ ] IDNA normalization for internationalized domains
- [ ] Reject malformed URLs (missing scheme, invalid port)
- [ ] Applied in `cred.get`, `cred.write`, rate limiting

**Files:**
- `apps/agent-macos/src/origin.rs` (new)
- `apps/agent-macos/src/credentials.rs` (use canonicalization)
- `apps/agent-macos/src/ratelimit.rs` (use canonicalization)

---

### Issue 4: Monotonic TTL & Skew Guard

**Title:** Use Monotonic Clock for TTL and Add Clock Skew Protection

**Labels:** `security`, `bug`, `M1`

**Description:**

Prevent credential reuse bypass via clock manipulation.

**Problem:**
- User sets system clock back → stale credentials reused
- Clock skew between systems → TTL bypass

**Requirements:**
- [ ] Use **monotonic clock** for TTL enforcement
- [ ] Store `created_at_monotonic` + `created_at_wall_clock`
- [ ] Detect forward clock skew > 5 minutes → force re-auth
- [ ] Detect backward clock skew → log warning, continue with monotonic
- [ ] Apply to credential re-use, session lifetimes

**Implementation:**
```rust
use std::time::Instant; // Monotonic

struct Credential {
    created_at: Instant,        // Monotonic (for TTL)
    created_at_wall: SystemTime, // Wall clock (for audit)
    ttl_s: u64,
}

fn is_expired(&self) -> bool {
    self.created_at.elapsed().as_secs() > self.ttl_s
}
```

**Acceptance Criteria:**
- [ ] TTL based on monotonic time
- [ ] Clock skew detection (forward > 5min = re-auth)
- [ ] Unit tests: clock goes backward
- [ ] Audit events use wall clock timestamps

**Files:**
- `apps/agent-macos/src/credentials.rs`
- `apps/agent-macos/src/session.rs`

---

### Issue 5: UDS Permission Checks at Startup

**Title:** Enforce File Permissions on Socket and Config Directory

**Labels:** `security`, `hardening`, `M1`

**Description:**

Deny startup if socket/config has weak permissions.

**Requirements:**
- [ ] Check `~/.armadillo/` directory: must be `0700`
- [ ] Check UDS socket: must be `0600`
- [ ] Check `tls_config.json`: must be `0600`
- [ ] **Refuse to start** if permissions are weak
- [ ] Log clear error message with chmod command

**Error Example:**
```
ERROR: Insecure permissions on ~/.armadillo/
  Current: 0755
  Required: 0700
  Fix: chmod 700 ~/.armadillo
```

**Acceptance Criteria:**
- [ ] Agent refuses to start with weak perms
- [ ] Clear actionable error messages
- [ ] macOS + Linux permission checks
- [ ] Unit tests (mock filesystem)

**Files:**
- `apps/agent-macos/src/main.rs` (startup checks)
- `apps/agent-macos/src/bridge.rs` (socket permissions)

---

## M2: Remote Approvals + Step-Up Rules

### Issue 6: Remote Approvals with Scoped Tokens

**Title:** Implement Remote Approval Flow (TOTP/Push)

**Labels:** `feature`, `security`, `M2`

**Description:**

Allow approvals when device is not in proximity.

**Flow:**
1. Agent detects no proximity
2. Sends push notification OR displays TOTP code
3. User approves on iOS
4. iOS sends signed approval token to agent
5. Agent validates and grants access (time-limited)

**Requirements:**
- [ ] `remote.grant` path in agent
- [ ] Scoped token: `{origin, action, ttl, sig}`
- [ ] iOS: push notification + approval UI
- [ ] Token validation (signature, expiry, scope)
- [ ] Rate limits apply (3 global auth, 1 per origin)
- [ ] Audit: `auth.granted via=remote`

**Token Format:**
```json
{
  "origin": "https://github.com",
  "action": "login",
  "granted_at": 1734268800,
  "ttl_s": 300,
  "signature": "..."
}
```

**Acceptance Criteria:**
- [ ] E2E: iOS approval → agent grants access
- [ ] Invalid signature rejected
- [ ] Expired token rejected
- [ ] Wrong origin/action rejected
- [ ] Rate limits enforced

**Files:**
- `apps/agent-macos/src/remote.rs` (new)
- `apps/app-macos-tls/` (push notification)
- `apps/app-ios/` (approval UI)

---

### Issue 7: Per-Site Step-Up Rules

**Title:** Policy Rules for Per-Site TTL and Step-Up

**Labels:** `feature`, `policy`, `M2`

**Description:**

Allow fine-grained control over authentication requirements.

**Policy Schema:**
```yaml
sites:
  - origin: "https://github.com"
    actions:
      - push: { ttl_s: 0, require: face_id }  # Every time
      - read: { ttl_s: 7200 }                 # 2 hours
  
  - origin: "https://vpn.corp.com"
    actions:
      - connect: { ttl_s: 0, require: face_id }
  
  - origin: "https://facebook.com"
    actions:
      - "*": { deny: true }  # Block all
```

**Requirements:**
- [ ] Parse site-specific rules from policy
- [ ] `ttl_s=0` forces every-time authentication
- [ ] `require: face_id` bypasses proximity
- [ ] `deny: true` blocks all actions
- [ ] Fallback to global defaults

**Acceptance Criteria:**
- [ ] E2E: `github.push` requires Face ID every time
- [ ] E2E: `vpn.connect` requires Face ID
- [ ] E2E: `facebook.*` blocked (403)
- [ ] Site rules override global defaults
- [ ] YAML syntax validated on load

**Files:**
- `apps/agent-macos/src/policy.rs`
- `apps/agent-macos/src/auth.rs`
- Example policy files

---

## M3: iOS MVP UI

### Issue 8: iOS Devices Tab

**Title:** iOS Devices Tab - Status, Proximity Mode, Controls

**Labels:** `ios`, `ui`, `M3`

**Description:**

UI to manage paired Mac devices.

**Features:**
- [ ] List all paired Macs (name, last seen, proximity status)
- [ ] Per-device proximity mode selector (auto/first_use/intent)
- [ ] **Pause** button (disable for 24h)
- [ ] **Resume** button
- [ ] **Unlock for 5min** button (temporary bypass)
- [ ] **Remove Device** (unpair)

**UI Mockup:**
```
┌─────────────────────────┐
│ Devices                  │
├─────────────────────────┤
│ 🖥️  MacBook Pro         │
│    In proximity          │
│    Mode: Intent          │
│    [Pause] [Unlock 5m]  │
├─────────────────────────┤
│ 🖥️  iMac                │
│    Not in proximity      │
│    Mode: First Use       │
│    [Paused until 3:00PM]│
│    [Resume]              │
└─────────────────────────┘
```

**Acceptance Criteria:**
- [ ] UITests for mode toggle
- [ ] Pause persists across app restarts
- [ ] Unlock 5m countdown timer
- [ ] Proximity status updates in real-time

**Files:**
- `apps/app-ios/ArmadilloMobile/Features/Devices/`

---

### Issue 9: iOS Sites & Actions Tab

**Title:** iOS Sites & Actions - Search and Face ID Toggles

**Labels:** `ios`, `ui`, `M3`

**Description:**

Manage per-site authentication requirements.

**Features:**
- [ ] Search bar (filter by origin)
- [ ] List of sites/actions with last used timestamp
- [ ] **Require Face ID** toggle (global → per-Mac override)
- [ ] Clear site data button
- [ ] Export site list

**UI Mockup:**
```
┌─────────────────────────┐
│ Sites & Actions          │
│ 🔍 Search...             │
├─────────────────────────┤
│ github.com               │
│   push (Face ID) ✓      │
│   read                   │
│                          │
│ vpn.corp.com             │
│   connect (Face ID) ✓   │
│                          │
│ slack.com                │
│   login                  │
│   [Require Face ID]      │
└─────────────────────────┘
```

**Acceptance Criteria:**
- [ ] Search filters by origin
- [ ] Face ID toggle applies immediately
- [ ] Changes sync to agent via policy update
- [ ] UITests for toggle + search

**Files:**
- `apps/app-ios/ArmadilloMobile/Features/Sites/`

---

### Issue 10: iOS Activity Feed

**Title:** iOS Activity Feed - Audit Event Summary

**Labels:** `ios`, `ui`, `M3`

**Description:**

Display recent authentication activity from agent audit log.

**Features:**
- [ ] Fetch last 100 audit events from agent
- [ ] Group by date
- [ ] Show: timestamp, origin, action, decision, method
- [ ] Filter: allowed/denied/all
- [ ] Pull-to-refresh

**UI Mockup:**
```
┌─────────────────────────┐
│ Activity                 │
│ [All] [Allowed] [Denied] │
├─────────────────────────┤
│ Today                    │
│ ✅ github.com/push       │
│    11:30 AM via Face ID  │
│                          │
│ ❌ facebook.com/login    │
│    10:15 AM blocked      │
│                          │
│ Yesterday                │
│ ✅ vpn.corp.com/connect  │
│    09:00 AM via Face ID  │
└─────────────────────────┘
```

**Acceptance Criteria:**
- [ ] Displays agent audit events
- [ ] Grouped by date
- [ ] Filter toggles work
- [ ] Pull-to-refresh updates

**Files:**
- `apps/app-ios/ArmadilloMobile/Features/Activity/`

---

### Issue 11: iOS Continuation Hygiene

**Title:** Fix Background/Suspend During Auth Prompts

**Labels:** `ios`, `bug`, `M3`

**Description:**

Ensure all auth prompts resolve cleanly (no orphaned continuations).

**Problem:**
- App backgrounded mid-Face ID → prompt hangs
- User cancels → agent left waiting
- Timeout not enforced → zombie requests

**Requirements:**
- [ ] Face ID prompt: 30s timeout
- [ ] Background/suspend: auto-cancel with `auth.canceled via=background`
- [ ] User cancel: send cancel message to agent
- [ ] Agent enforces 60s max wait on all auth requests
- [ ] Cleanup orphaned requests on reconnect

**Acceptance Criteria:**
- [ ] UITest: background during Face ID → cancels + logs event
- [ ] UITest: user cancel → agent receives cancel
- [ ] UITest: timeout after 30s → auto-cancel
- [ ] No zombie requests after suspend cycle

**Files:**
- `apps/app-ios/ArmadilloMobile/Features/Auth/`
- `apps/agent-macos/src/auth.rs` (timeout enforcement)

---

## M4: Web Extension MVP

### Issue 12: Native Messaging Integration

**Title:** Chrome Extension - Native Messaging for cred.get/list

**Labels:** `extension`, `feature`, `M4`

**Description:**

Connect extension to agent via Native Messaging.

**Requirements:**
- [ ] Manifest V3 native messaging host config
- [ ] `cred.get(origin)` → agent → credential
- [ ] `cred.list()` → agent → all credentials
- [ ] Strict origin binding (validate origin matches)
- [ ] Error handling (agent offline, permission denied)

**Message Format:**
```json
// Request
{"type": "cred.get", "origin": "https://github.com", "corr_id": "uuid"}

// Response
{"type": "cred.response", "username": "user", "password": "***", "corr_id": "uuid"}
```

**Acceptance Criteria:**
- [ ] Autofill happy path works
- [ ] Wrong origin → denied
- [ ] Agent offline → user-friendly error
- [ ] Exponential backoff on failures

**Files:**
- `packages/webext/src/native-messaging.js`
- `apps/agent-macos/native-messaging-host.json`

---

### Issue 13: Blur Overlay for Per-Site Proximity

**Title:** CSS Blur Overlay When Away from Device

**Labels:** `extension`, `feature`, `M4`

**Description:**

Blur page content when user leaves proximity.

**Requirements:**
- [ ] CSS overlay: `backdrop-filter: blur(10px)`
- [ ] Swallow keyboard/mouse events while blurred
- [ ] Per-site whitelist (don't blur YouTube, etc.)
- [ ] Toggle in extension popup
- [ ] Persist whitelist

**UI:**
```
┌─────────────────────┐
│ 🌫️  Away from Mac    │
│                     │
│ (Content blurred)   │
│                     │
│ Return to unlock    │
└─────────────────────┘
```

**Acceptance Criteria:**
- [ ] Blur activates when proximity lost
- [ ] Keyboard/mouse blocked while blurred
- [ ] Whitelist sites don't blur
- [ ] Toggle per site works
- [ ] Re-proximity removes blur

**Files:**
- `packages/webext/src/content/blur.js`
- `packages/webext/src/popup/whitelist.js`

---

### Issue 14: MV3 Worker Lifecycle Management

**Title:** Service Worker Lifecycle - Reconnect on Wake

**Labels:** `extension`, `bug`, `M4`

**Description:**

Handle Chrome extension service worker wake/sleep cycles.

**Problem:**
- Worker sleeps after 30s inactivity
- Native messaging disconnected on sleep
- Must reconnect per request

**Requirements:**
- [ ] Reconnect NM on each request (don't keep alive)
- [ ] Exponential backoff on connection failures
- [ ] Cache last-known state for 60s
- [ ] Handle wake-from-suspend cleanly

**Acceptance Criteria:**
- [ ] Works after worker sleep
- [ ] Works after system suspend
- [ ] Connection failures don't crash worker
- [ ] Exponential backoff (1s, 2s, 4s, 8s, max 30s)

**Files:**
- `packages/webext/src/background/worker.js`
- `packages/webext/src/background/nm-client.js`

---

## M5: Integration & Hardening

### Issue 15: End-to-End Integration Tests

**Title:** E2E Test Suite - iOS ↔ TLS ↔ Agent ↔ Extension

**Labels:** `testing`, `M5`

**Description:**

Full-stack integration tests.

**Test Scenarios:**
1. **Pairing:** iOS scans QR → TLS accepts → agent paired
2. **Auth Flow:** Extension requests cred → agent → iOS Face ID → credential returned
3. **Rotation:** Stage cert → QR shows dual-pin → iOS connects with either → promote
4. **Rate Limit:** 6 rapid requests → 6th blocked (429)
5. **Idempotency:** Duplicate write → replayed (not duplicated)

**Requirements:**
- [ ] Test harness spawns all components
- [ ] Simulated user interactions (Face ID, proximity)
- [ ] Assert audit events emitted
- [ ] Cleanup between tests

**Files:**
- `tests/integration/` (new directory)
- `tests/integration/test_pairing.rs`
- `tests/integration/test_auth_flow.rs`
- `tests/integration/test_rotation.rs`

---

### Issue 16: Fuzzing in CI

**Title:** Add Fuzzers for UDS Parser and JSON Deserializer

**Labels:** `security`, `testing`, `M5`

**Description:**

Continuous fuzzing to find crashes/panics.

**Targets:**
1. **UDS Frame Parser:** Random bytes → should not panic
2. **JSON Deserializer:** Malformed JSON → graceful errors
3. **Policy YAML:** Invalid policy → clear error message

**Requirements:**
- [ ] cargo-fuzz targets for each parser
- [ ] CI runs fuzzers nightly (5min each)
- [ ] Crashes/panics fail CI
- [ ] Corpus in git (small, curated)

**Acceptance Criteria:**
- [ ] 0 panics in 1M iterations
- [ ] Graceful error messages for all malformed inputs
- [ ] CI integration (GitHub Actions nightly)

**Files:**
- `fuzz/fuzz_targets/uds_parser.rs`
- `fuzz/fuzz_targets/json_deserializer.rs`
- `.github/workflows/fuzz.yml`

---

### Issue 17: Load & Chaos Testing

**Title:** Load Testing - 100 req/s Burst + Component Failures

**Labels:** `testing`, `reliability`, `M5`

**Description:**

Validate system under load and failure conditions.

**Scenarios:**
1. **Burst:** 100 req/s for 10s → no crashes, all requests handled
2. **Kill Agent:** Kill agent mid-request → extension shows error, recovers on restart
3. **Kill TLS:** Kill TLS mid-pairing → iOS shows error, retries
4. **Network Loss:** Disconnect network → queue requests, replay on reconnect

**Requirements:**
- [ ] Load generator (100 concurrent requests)
- [ ] Chaos monkey (randomly kill components)
- [ ] Health checks (service recovers within 5s)
- [ ] Queue/replay on network loss

**Acceptance Criteria:**
- [ ] 100 req/s sustained for 10s (no crashes)
- [ ] Component kill → recovery within 5s
- [ ] No orphaned requests
- [ ] Audit log remains consistent

**Files:**
- `tests/load/` (new directory)
- `tests/load/burst_test.go` or `.rs`
- `tests/load/chaos.sh`

---

## Tracking Milestones

**M1 (Agent Polish):** Issues #1-5  
**M2 (Remote Approvals):** Issues #6-7  
**M3 (iOS MVP UI):** Issues #8-11  
**M4 (Web Extension MVP):** Issues #12-14  
**M5 (Integration & Hardening):** Issues #15-17

**Total:** 17 issues across 5 milestones
