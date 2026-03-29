# TLS Certificate Rotation Guide

## Overview

Armadillo supports zero-downtime TLS certificate rotation using a dual-pin approach. During rotation, both the current and next certificate fingerprints are included in pairing QR codes, allowing iOS devices to accept either certificate during the overlap window.

## Prerequisites

- Updated iOS app with dual-pin support (PR2+)
- New certificate PEM file
- Access to `agent-cli` binary

## Standard Rotation (Recommended)

Safe rotation with 7-day overlap window for gradual rollout.

### 1. Generate or Obtain New Certificate

```bash
# Option 1: Self-signed (development)
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout /secure/path/new-cert.key \
  -out /secure/path/new-cert.pem \
  -subj "/CN=Armadillo TLS"

# Option 2: Use cert from your CA
# Place cert at /secure/path/new-cert.pem
```

**Security:** Set restrictive permissions:
```bash
chmod 600 /secure/path/new-cert.pem
chmod 600 /secure/path/new-cert.key
```

### 2. Stage the New Certificate

```bash
agent-cli tls rotate --cert /secure/path/new-cert.pem
```

**Expected Output:**
```
✅ Certificate staged successfully

Rotation Status:
  Current FP: sha256:abc123...
  Next FP:    sha256:def456...
  Days remaining: 7

Run 'agent-cli tls promote' to complete rotation
```

**What Happens:**
- New fingerprint stored as `fp_next` in config
- QR codes now include **both** fingerprints
- iOS apps accept connections using current **or** next certificate
- Audit event: `cert.rotate.staged`

### 3. Deploy Updated iOS App (If Needed)

If this is your first rotation, ensure iOS apps have dual-pin support:
```bash
# Check iOS app version
# Minimum: v2.0+ (PR2)
```

Wait for adoption before promoting (recommended: 80%+ of users).

### 4. Monitor the Rotation Window

```bash
# Check status anytime
agent-cli tls status

# JSON output for scripting
agent-cli tls status --json
```

**Sample Output:**
```json
{
  "is_rotating": true,
  "fp_current": "sha256:abc123...",
  "fp_next": "sha256:def456...",
  "days_remaining": 5,
  "window_expired": false
}
```

### 5. Promote the New Certificate

After sufficient adoption period:

```bash
agent-cli tls promote
```

**Expected Output:**
```
✅ Certificate promoted successfully
⚠️  Restart TLS server to apply new certificate

Current FP: sha256:def456...
```

**What Happens:**
- `fp_current` swapped to new fingerprint
- `fp_next` cleared
- QR codes revert to single fingerprint
- Audit event: `cert.rotate.promoted`

### 6. Restart TLS Server

```bash
# Restart your TLS terminator
sudo systemctl restart armadillo-tls
# or
launchctl kickstart -k armadillo.tls
```

**Verification:**
- New QR codes show only new fingerprint
- Old iOS devices (dual-pinned) continue working
- New pairings use only new certificate

---

## Emergency Rotation (Compromise Scenario)

Use when immediate rotation is required (e.g., private key compromised).

⚠️ **WARNING:** This will break all existing paired devices!

### Emergency Rotation Command

```bash
agent-cli tls rotate \
  --cert /secure/path/emergency-cert.pem \
  --no-overlap \
  --force
```

**Expected Output:**
```
⚠️  WARNING: Emergency rotation mode!
⚠️  This will immediately activate the new certificate.
⚠️  All paired devices must re-scan QR code to reconnect.

✅ Certificate staged successfully
🚨 Promoting immediately (emergency mode)...
✅ Emergency rotation complete
⚠️  Restart TLS server to apply new certificate
⚠️  All devices must re-pair with new QR code
```

**What Happens:**
- New certificate activated **immediately**
- No dual-pin window
- All iOS devices must re-pair
- Audit events: `cert.rotate.staged` + `cert.rotate.promoted`

### After Emergency Rotation

1. Restart TLS server immediately
2. Generate fresh pairing QR codes
3. Distribute QR codes to users via secure channel
4. Users must re-scan and re-pair their devices

---

## Rollback/Cancel Rotation

If you need to abort a rotation in progress:

```bash
agent-cli tls cancel
```

**Expected Output:**
```
✅ Rotation canceled
Current certificate unchanged: sha256:abc123...
```

**What Happens:**
- Staged certificate discarded
- `fp_next` cleared
- QR codes revert to single fingerprint (current)
- Audit event: `cert.rotate.canceled`

---

## Configuration

### Environment Variables

```bash
# Rotation window duration (days)
export ARM_CERT_ROTATION_WINDOW_DAYS=7  # Default: 7, Min: 1, Max: 30

# Config file location
export ARM_TLS_CONFIG_PATH="~/.armadillo/tls_config.json"

# Behavior when rotation window expires
export ARM_ROTATION_EXPIRED=warn  # Options: warn | rollback | block
```

### Config File Location

Default: `~/Library/Application Support/Symbiauth/tls.json`

**Permissions:** Ensure `0600` on config file:
```bash
chmod 600 ~/Library/Application\ Support/Symbiauth/tls.json
```

---

## Troubleshooting

### Certificate File Not Found

**Error:**
```
Error: Certificate file not found: /path/to/cert.pem
```

**Solution:**
- Verify file path is correct
- Check file exists: `ls -l /path/to/cert.pem`
- Ensure you have read permissions

### Invalid Certificate Format

**Error:**
```
Error: Certificate file is too small to be valid
```

**Solution:**
- Ensure certificate is in PEM format (starts with `-----BEGIN CERTIFICATE-----`)
- Verify certificate is not corrupted: `openssl x509 -in cert.pem -text`
- Check file is not empty: `wc -c cert.pem`

### Rotation Already in Progress

**Error:**
```
Error: Failed to stage rotation: New certificate is identical to current certificate
```

**Solutions:**
- Check current status: `agent-cli tls status`
- Cancel existing rotation: `agent-cli tls cancel`
- Then retry with new certificate

### Window Expired

**Status shows:**
```
Window expired:      ⚠️  YES

Rotation window has expired. Options:
  - Run 'tls promote' to complete rotation
  - Run 'tls cancel' to rollback
```

**Solution:**
Choose one:
```bash
# Complete the rotation
agent-cli tls promote

# OR rollback to current cert
agent-cli tls cancel
```

---

## Audit Trail

All rotation operations emit audit events:

### Event Types

**cert.rotate.staged:**
```json
{
  "event": "cert.rotate.staged",
  "old_fp": "sha256:abc123...",
  "new_fp": "sha256:def456...",
  "window_days": 7,
  "timestamp": "2025-12-15T11:00:00Z"
}
```

**cert.rotate.promoted:**
```json
{
  "event": "cert.rotate.promoted",
  "new_fp": "sha256:def456...",
  "timestamp": "2025-12-15T11:07:00Z"
}
```

**cert.rotate.canceled:**
```json
{
  "event": "cert.rotate.canceled",
  "old_fp": "sha256:abc123...",
  "new_fp": "sha256:def456...",
  "timestamp": "2025-12-15T11:05:00Z"
}
```

### Audit Log Location

Check your audit log configuration for events:
```bash
tail -f /var/log/armadillo/audit.log | grep "cert.rotate"
```

---

## Best Practices

1. **Test First:** Test rotation on staging environment before production
2. **Monitor Adoption:** Wait for 80%+ iOS app adoption before promoting
3. **Backup Certs:** Keep old certificates for emergency rollback
4. **Secure Storage:** Store private keys with `0600` permissions in encrypted storage
5. **Rotate Regularly:** Schedule rotations every 90 days for security
6. **Document**: Log rotation dates and reasons in runbook
7. **Alert on Expiry:** Set monitoring alerts for window expiration

---

## Quick Reference

```bash
# Check status
agent-cli tls status
agent-cli tls status --json

# Standard rotation
agent-cli tls rotate --cert /path/to/new.pem
agent-cli tls promote

# Emergency rotation
agent-cli tls rotate --cert /path/to/new.pem --no-overlap --force

# Cancel rotation
agent-cli tls cancel
```

---

## Security Considerations

### Threat T16: Certificate Expiration/Compromise

**Mitigation:** Dual-pin rotation allows certificate updates without service interruption.

**Coverage:**
- ✅ Proactive rotation before expiration
- ✅ Emergency rotation on compromise
- ✅ Zero-downtime during rotation window
- ✅ Audit trail for compliance

### Private Key Protection

- Store keys in HSM or encrypted filesystem
- Use `0600` permissions minimum
- Rotate regularly (every 90 days recommended)
- Destroy old keys after successful rotation

### Pairing Security During Rotation

- QR codes include both fingerprints only during window
- iOS validates against current OR next
- After promotion, only new fingerprint accepted
- Compromised old cert can't be used after window expires

---

## Support

For issues or questions:
- Check audit logs for rotation events
- Run `agent-cli tls status` for current state
- Review this guide's troubleshooting section
- Contact security team for emergency rotations
