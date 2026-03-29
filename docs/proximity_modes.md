# Proximity Modes

## Overview

The Armadillo agent supports proximity-based authentication using BLE presence detection. When a paired iOS device is near the Mac, the agent can unlock sessions automatically or require explicit user intent.

## Modes

### FirstUse (Default, Recommended)
**Use case:** Balance security with convenience. Initial unlock required, then seamless reuse while device is near.

**Behavior:**
- When iOS device comes NEAR, state is `NearLocked`
- First operation requires Face ID approval (`session_unlock`)
- Once unlocked, reuse credentials while NEAR without re-prompting
- When device goes FAR, session locks immediately

**Configuration:**
```bash
export ARM_PROX_MODE=first_use  # or omit (this is the default)
```

**Flow:**
```
1. cred.get → 401 session_unlock_required
2. User approves on iOS (Face ID)
3. auth.proof → success
4. Subsequent cred.get while NEAR → 200 (no re-prompt)
5. Device goes FAR → state = Far
6. cred.get → 401 proximity_far
```

---

### Intent
**Use case:** High-security environments. Require explicit intent signal before any credential access.

**Behavior:**
- Requires `prox.intent` command from extension/app
- Then requires Face ID unlock
- Reuse while both intent window and NEAR state are active

**Configuration:**
```bash
export ARM_PROX_MODE=intent
```

**Flow:**
```
1. cred.get → 401 prox_intent_required
2. Extension sends prox.intent → ok
3. cred.get → 401 session_unlock_required
4. User approves on iOS (Face ID)
5. auth.proof → success
6. Subsequent cred.get while NEAR + intent window active → 200
```

**Intent Window:**
- Duration: Configurable (default 15 seconds)
- Resets on each new `prox.intent` call
- Independent of session unlock state

---

### AutoUnlock
**Use case:** Trusted environments. Convenience over security.

**Behavior:**
- Automatically unlocks when iOS device is NEAR
- No Face ID required
- Credentials accessible immediately

**Configuration:**
```bash
export ARM_PROX_MODE=auto_unlock
```

**⚠️ Security Warning:** This mode bypasses biometric authentication. Only use in highly trusted environments.

**Flow:**
```
1. Device comes NEAR → state = NearUnlocked (automatic)
2. cred.get → 200 (no prompt)
```

---

## Pause/Resume

All modes support temporary suspension via `prox.pause` / `prox.resume` commands.

**Usage:**
```json
// Pause for 30 seconds
{"type": "prox.pause", "seconds": 30}

// Resume immediately
{"type": "prox.resume"}
```

**While Paused:**
- All gated operations return `403 proximity_paused`
- Useful for temporary lockdown during presentations, etc.

---

## Error Codes

| Code | Reason | Meaning | Action |
|------|--------|---------|--------|
| 401 | `session_unlock_required` | Device NEAR but session locked | Approve Face ID on iOS |
| 401 | `prox_intent_required` | Intent mode: need explicit intent | Send `prox.intent` from extension |
| 401 | `proximity_far` | iOS device not detected | Bring device near Mac |
| 403 | `proximity_paused` | Proximity temporarily paused | Send `prox.resume` or wait for timeout |

---

## Status Query

Query current proximity state:

```json
// Request
{"type": "prox.status"}

// Response
{
  "type": "prox.status",
  "mode": "first_use",           // first_use | intent | auto_unlock
  "state": "near_unlocked",      // far | near_locked | near_unlocked | paused
  "near": true,                  // boolean: device detected
  "unlocked": true,              // boolean: session unlocked
  "grace_remaining_ms": 0,       // grace period for unlock
  "pause_remaining_s": 0         // pause countdown
}
```

---

## Configuration

### Environment Variables

```bash
# Mode selection
ARM_PROX_MODE=first_use          # first_use (default) | intent | auto_unlock

# Grace period (milliseconds)
ARM_PROX_GRACE_MS=15000          # default: 15 seconds

# Default pause duration (seconds)
ARM_PROX_PAUSE_DEFAULT_S=1800    # default: 30 minutes

# Session TTL (seconds)
ARM_PROX_SESSION_TTL_S=300       # default: 5 minutes
```

---

## Gated Operations

The following operations enforce the proximity gate:

- `cred.get` - Retrieve stored credentials
- `vault.read` - Read vault entries
- `vault.write` - Write vault entries

**Note:** System operations like `pairing.init`, `trust.add`, `prox.status` are NOT gated.

---

## Security Model

### Threat Model
- **Physical proximity** as first factor
- **Face ID** as second factor (FirstUse, Intent modes)
- **Session reuse** to reduce friction while maintaining security
- **Immediate lock** on distance (FAR state)

### Attack Scenarios
1. **Stolen Mac + nearby phone:** Requires Face ID to unlock session
2. **Stolen Mac, no phone:** All gated ops fail with `proximity_far`
3. **Replay attack:** Nonce-based auth prevents reuse
4. **Man-in-the-middle:** TLS + certificate pinning
5. **Session fixation:** Session IDs are cryptographically random

### Recommended Settings
- **Production:** `FirstUse` mode (default)
- **High-security:** `Intent` mode + short grace period
- **Development only:** `AutoUnlock` mode (disable for production)

---

## Migration

### From No Proximity
If upgrading from a version without proximity:

1. Existing sessions continue working
2. Next unlock will establish proximity session
3. No data migration required
4. Vault remains encrypted with same keys

### Changing Modes
Modes can be changed at any time:

```bash
# Change from FirstUse to Intent
export ARM_PROX_MODE=intent
# Restart agent
```

Sessions will re-lock and require re-authentication under the new mode.

---

## Troubleshooting

### "proximity_far" when device is near
- Check Bluetooth is enabled on both devices
- Verify pairing is active (iOS app should show "Connected")
- Check TLS connection is established

### Session unlocks but immediately re-locks
- Check grace period isn't too short (`ARM_PROX_GRACE_MS`)
- Verify stable BLE signal (move devices closer)
- Check device didn't go to sleep (disable auto-sleep during use)

### "prox_intent_required" in FirstUse mode
- Configuration error: check `ARM_PROX_MODE=first_use`
- Restart agent to apply config changes

---

## Audit Trail

Proximity events are logged to the audit trail:

- `proximity.intent` - Intent signal received
- `proximity.paused` - Manual pause activated
- `proximity.resumed` - Pause lifted
- `proximity.unlocked` - Session unlocked after Face ID
- `presence.enter` - Device came NEAR (TLS up)
- `presence.leave` - Device went FAR (TLS down)

Verify audit integrity:
```bash
agent-cli audit verify
```
