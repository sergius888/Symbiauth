# Armadillo Development Roadmap

## Current Status: Pre-App Groups Phase

**Context**: App Groups entitlements require Apple Developer Program ($99/year). Payment planned for end of month. Until then, we focus on high-value work that doesn't require App Groups.

## What We Can Do Now (No App Groups Needed)

### 🍎 iOS Critical Polish

#### Bonjour Bug Fix (HIGH PRIORITY)
- **Issue**: Currently canceling after `didFindService` - too early
- **Fix**: Wait for `netServiceDidResolveAddress` before making decisions
- **Implementation**:
  - Log each resolved IP:port from `addresses` array
  - Only fallback to QR if NO valid addresses are resolved
  - Add retry with exponential backoff for failed resolutions
- **Files**: `BonjourBrowser.swift` - delegate methods and call sites

#### Pairing State Machine
- **Goal**: Enforce proper sequence: Discover → Enroll (8444) → Store identity → Reconnect mTLS (8443) → Ping/Pong
- **Requirements**:
  - Make it idempotent (safe on app relaunch)
  - Clear state transitions with proper error handling
  - Prevent accessing 8443 without valid identity

#### Auto-Renewal System
- **Trigger**: Detect cert expiry (<7 days remaining)
- **Process**: Silent CSR re-enroll → replace cert in Keychain
- **Implementation**: Background task to check cert validity

#### Error Surfacing
- **User-friendly toasts for**:
  - Enroll port unreachable (8444)
  - Certificate parse failure (DER format issues)
  - Identity missing from Keychain
  - mTLS "certificate required" errors
- **Goal**: Replace technical errors with actionable messages

#### SAS UX Enhancement
- **Feature**: Show 6-digit SAS code
- **Requirement**: User must confirm SAS before enabling the identity
- **Security**: Prevents MITM attacks during pairing

### 🖥️ macOS TLS Terminator

#### Dual Listeners (CRITICAL)
- **Port 8444**: No client-auth required, server cert pinned (enrollment only)
- **Port 8443**: Require client-auth, server cert pinned (main mTLS)
- **Status**: Need to finish implementation

#### Real Client Certificate Verification
- **Current**: Using `complete(true)` - INSECURE
- **Required Implementation**:
  - Build SecTrust with client-auth CA as anchor
  - Check Extended Key Usage = clientAuth
  - Verify validity period
  - Match CN/serial to paired device record
- **File**: Need to see current `verifyCertificate` implementation

#### Enrollment Hardening
- **CSR Validation**:
  - Key type must be P-256
  - Subject must be present and valid
- **Security**:
  - Bind CSR to pairing session/SAS
  - Return DER format (or PKCS#7) with chain
  - Rate limiting per device/IP
  - Structured error codes
- **Output**: Always DER format for `SecCertificateCreateWithData`

#### Logging & Metrics
- **Format**: Structured JSON logs
- **Include**: Device ID, cert serial, failure reasons
- **Scope**: Both enrollment (8444) and mTLS (8443) operations

### 🦀 Rust Agent

#### Bridge Robustness
- **Features Needed**:
  - Backpressure handling
  - Heartbeat mechanism
  - Auto-reconnect to terminator
  - Exponential backoff on failures

#### Protocol Guards
- **Requirements**:
  - Strict schema validation
  - Version handling (v:1)
  - Unknown message handling
  - Proper error responses

#### Testing
- **Unit Tests**: Message framing, ping/pong
- **Integration Tests**: End-to-end communication

### 🧪 Testing Harness (Super Useful)

#### OpenSSL Test Scripts
```bash
# Test 8443 requires cert
openssl s_client -connect <mac-ip>:8443

# Test 8444 enrollment
curl -X POST https://<mac-ip>:8444/enroll -d @test.csr

# Parse returned DER
openssl x509 -inform DER -text -noout < returned_cert.der
```

#### End-to-End Validation
- **Goal**: iOS-less enrollment using test CSR
- **Validates**: Server signer + certificate chain
- **Benefit**: Fast iteration without iOS simulator

### 🔒 Security Checkups

#### Certificate Lifecycle
- **Lifetimes**: Short (7-30 days) + renewal path implemented
- **Key Usage**: Correct KeyUsage/EKU in issued client certs
- **Validation**: Proper certificate chain validation

#### Pinning Strategy
- **Current**: Single pin (fragile)
- **Upgrade**: Dual pins (old+new) during rotation
- **Benefit**: Prevents pin breakage during updates

#### Revocation System
- **Format**: Simple JSON list for now
- **Behavior**: Server rejects revoked certificate serials
- **Future**: Proper OCSP/CRL support

### 📋 XPC Planning (Design Only)

#### Interface Design
- **Protocol**: Define AgentProtocol interface
- **Lifecycle**: Process management and cleanup
- **Architecture**: FFI vs subprocess decision

#### Migration Path
- **Goal**: Clean transition from Unix sockets to XPC
- **Timing**: After App Groups are available
- **Benefit**: Apple-native IPC with proper sandboxing

## What to Avoid Until App Groups

### ❌ Don't Do These Yet
- **Running with Sandbox ON + Unix socket in /tmp** (will fail)
- **Shipping security workarounds** (Sandbox stays ON for production)
- **Hardcoding paths outside App Group containers**

### 🚧 Temporary Dev Mode (If Needed)
- **Option**: Run Sandbox OFF temporarily for testing
- **Purpose**: Unblock development while waiting for App Groups
- **Reminder**: This is DEV ONLY - flip Sandbox back ON for production
- **Code Impact**: None - same code works with/without sandbox

## Next Actions Needed

### Immediate Code Reviews Required
1. **BonjourBrowser.swift**: Delegate methods and cancel/resolve call sites
2. **Current verifyCertificate**: Server-side client cert verification
3. **TLS Server**: Dual listener implementation status

### Priority Order
1. **Fix Bonjour resolution** (blocks iOS testing)
2. **Implement real client cert verification** (security critical)
3. **Complete dual listeners** (architecture foundation)
4. **Add comprehensive logging** (debugging essential)
5. **Build testing harness** (development velocity)

## Rebranding Plan (record for post‑MVP)

- Dev phase (now): keep all names as "Armadillo" in code, projects, logs.
- Target brand: "DreiGlaser"; bundle prefix: `com.dreiglaser.*`.
- Pre‑ship/investor demo (half‑day):
  - Add branding indirection: `Branding.xcconfig` (iOS/macOS), `branding.rs` (agent), `constants.ts` (webext).
  - Update bundle IDs, App Group/Keychain groups, logging subsystem, Bonjour service type, Keychain labels.
  - Perform full pairing reset (new server fingerprint QR) and re‑sign/notarize binaries.
  - Verify entitlements and provisioning with new IDs.


## Reminders

### 🎯 North Star
- **Commercial-grade local pairing stack**
- **mTLS everywhere after bootstrap**
- **Sandbox ON (no compromises)**
- **DER format only for certificates**
- **Short socket paths (sun_path limit)**

### 🔐 Security Rules
- **Pinning everywhere**: iOS pins server cert on both 8444 & 8443
- **No self-signed client certs**: Only server-issued certificates
- **Identity persistence**: Reuse Keychain identity, renew before expiry
- **Proper validation**: Every certificate must be validated properly

### 📅 Timeline
- **Now - End of Month**: Work on items in "What We Can Do Now"
- **End of Month**: Pay for Apple Developer Program
- **After Payment**: Enable App Groups, complete sandbox integration
- **Production**: Full security model with XPC migration

---

**Remember**: We're building the hard, correct solution. No shortcuts on security, even during development.