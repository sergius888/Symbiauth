# Armadillo Project Overview

## What Is This?

**Armadillo** is a next-generation credential management system designed to replace traditional password managers with a more secure, privacy-focused architecture. Think of it as "1Password meets hardware security," but built from the ground up with zero-trust principles and proximity-based authentication.

## The Problem We're Solving

### Current Password Manager Limitations

Traditional password managers (1Password, LastPass, Bitwarden) have fundamental security trade-offs:

1. **Cloud Sync Risk**: Your encrypted vault lives on someone else's servers
2. **Master Password Weakness**: One weak password compromises everything
3. **Browser Extension Vulnerabilities**: Extensions run in untrusted web contexts
4. **No Physical Proximity**: Works fine when you're 1000 miles away (bad for security)
5. **Trust in Vendor**: You must trust the company won't be breached or coerced

### What Armadillo Does Differently

Armadillo uses a **local-first, proximity-based** architecture where:
- Your credentials **never leave your Mac**
- Authentication requires **physical proximity** (your iPhone nearby)
- No master password to remember or leak
- Zero cloud dependencies (optional iCloud for backup only)
- Browser extension communicates through **local TLS** (not cloud)

---

## How It Works (User Experience)

### Setup (One-Time)

1. **Install on Mac**: User installs Armadillo agent (runs in background)
2. **Pair iPhone**: Scan QR code with iOS app
3. **Set Up Security**:
   - Device pairing with end-to-end encryption
   - Face ID/Touch ID as authentication method
   - Optional recovery phrase for backup

### Daily Usage

#### Saving a Credential

```
User on browser:
1. Visit gmail.com and create account
2. Browser extension detects password field
3. Armadillo offers to save it
4. iPhone prompts: "Save password for gmail.com?"
5. User approves with Face ID on iPhone
6. Credential saved ONLY on Mac (encrypted vault)
```

#### Using a Credential

```
User on browser:
1. Visit gmail.com login page
2. Browser extension requests credential
3. Mac agent checks: "Is iPhone nearby?" ✓
4. Mac agent checks: "Session unlocked?" ✓
5. Auto-fills password
```

If session expired (>5 minutes) or iPhone not nearby:
```
1. Mac blocks access
2. iPhone prompts: "Unlock Armadillo?"
3. User approves with Face ID
4. Session starts, credentials available for 5 min
```

### Security Model

**Three Layers of Protection:**

1. **Proximity** - iPhone must be physically near Mac (Bluetooth/WiFi)
2. **Biometric** - Face ID/Touch ID on iPhone
3. **Session TTL** - Auto-locks after 5 minutes of approved access

**Threat Model:**
- ✅ Protects against: Stolen laptop (no iPhone nearby)
- ✅ Protects against: Remote malware (requires proximity)
- ✅ Protects against: Forgotten lock (auto-expires)
- ✅ Protects against: Cloud breaches (nothing in cloud)

---

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                         USER'S MAC                          │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐ │
│  │   Browser    │───▶│ TLS Terminator│───▶│  Agent       │ │
│  │  Extension   │    │  (localhost)  │    │  (Rust)      │ │
│  │  (Chrome)    │    │               │    │              │ │
│  └──────────────┘    └──────────────┘    └──────────────┘ │
│                             │                     │         │
│                             │                     │         │
│                             └─────────────────────┘         │
│                              Encrypted Vault (vault.bin)    │
└─────────────────────────────────────────────────────────────┘
                                    │
                                    │ Bluetooth/WiFi
                                    │ (local network only)
                                    ▼
                          ┌──────────────────┐
                          │  USER'S iPHONE   │
                          │                  │
                          │  Armadillo App   │
                          │  + Face ID Auth  │
                          └──────────────────┘
```

### Component Details

#### 1. **macOS Agent** (Rust)
- **Location**: `apps/agent-macos/`
- **Purpose**: Core credential storage and policy enforcement
- **Key Features**:
  - Encrypted vault (ChaCha20-Poly1305)
  - Unix domain socket for local IPC
  - Proximity detection (Bluetooth/WiFi)
  - Rate limiting and audit logging
  - TLS certificate rotation
  - Session management with monotonic TTL

#### 2. **TLS Terminator** (Swift)
- **Location**: `apps/tls-terminator-macos/`
- **Purpose**: HTTPS endpoint for browser extension
- **Why Needed**: Browser extensions can't use Unix sockets
- **Security**: Self-signed TLS cert, rotates every 7 days
- **Listens**: `https://localhost:7734`

#### 3. **Browser Extension** (JavaScript)
- **Location**: `apps/webext/`
- **Purpose**: Auto-fill interface in browser
- **Communication**: HTTPS to TLS terminator → Unix socket → Agent
- **Features**:
  - Auto-fill detection
  - Save credential prompts
  - Cross-origin isolation

#### 4. **iOS App** (Swift/SwiftUI)
- **Location**: `apps/app-ios/`
- **Purpose**: Approval device (like hardware security key)
- **Features**:
  - QR code pairing
  - Face ID authentication
  - Push notifications for approval requests
  - Bluetooth/WiFi proximity beaconing

---

## Security Features (Implemented)

### ✅ Milestone 1: Core Security (Complete)

#### M1.1: Secure Permissions
- Directory permissions enforcement (0700 for ~/.armadillo)
- Database file permissions (0600)
- Startup validation

#### M1.2: TLS Certificate Rotation
- Weekly automatic rotation
- Secure storage of private keys
- Graceful browser reconnection

#### M1.3: Hash-Chained Audit Log
- Tamper-evident logging
- Cryptographic verification
- CLI audit verification tool

#### M1.4a: Proximity Actor (FSM)
- Finite state machine for proximity states
- Configurable modes: FirstUse, Intent, AutoUnlock
- Pause/resume functionality
- Grace periods and session TTLs

#### M1.4b: Proximity Integration (Complete)
- Bridge integration with proximity actor
- Gate enforcement before sensitive operations
- Real UDS commands (prox.status, prox.pause, prox.resume, prox.intent)
- Session unlock marking
- Audit emits for proximity events

#### M1.5: Monotonic TTL (95% Complete)
- Clock abstraction (immune to system time manipulation)
- Session expiry based on monotonic time
- Clock skew detection and degraded mode
- **Status**: Infrastructure complete, needs 4 bridge integration points

### 🚧 In Progress

#### M1.5: Monotonic TTL (Final 5%)
- **What's left**: Add session checks in bridge.rs handlers
- **Why**: Prevent clock manipulation attacks

### 📋 Planned (Milestone 2 & 3)

#### M2: Remote Approvals
- TOTP-based approval system
- Push notifications to iPhone
- Out-of-band verification

#### M3: iOS MVP
- Full-featured iOS app UI
- Pairing workflow
- Approval interface
- Settings and management

---

## Current Status

### What Works Today

✅ **Core Functionality**:
- Credential storage in encrypted vault
- Rate limiting per origin
- Idempotency for write operations
- Policy-based access control
- Audit logging with verification

✅ **Security**:
- Secure file permissions
- TLS certificate rotation
- Hash-chained audit trail
- Proximity-based gating
- Session management

✅ **Developer Tools**:
- CLI for audit verification
- Test suite (47/47 tests passing)
- Comprehensive logging

### What Needs Work

🔨 **M1.5 Completion** (1-2 hours):
- Finish bridge integration for session TTL checks
- Add clock skew detection in iOS handshake
- Add M1.5 tests

🔨 **M2: Remote Approvals** (1-2 weeks):
- Implement TOTP generation
- Add push notification support
- Build approval request/response flow

🔨 **M3: iOS UI** (2-3 weeks):
- Design and implement pairing flow
- Approval notification UI
- Settings and management screens

🔨 **Browser Extension Polish** (1 week):
- Icon and branding
- Auto-fill UX improvements
- Better error handling

---

## Technology Stack

### Backend (macOS Agent)
- **Language**: Rust
- **Key Dependencies**:
  - `tokio` - Async runtime
  - `rusqlite` - SQLite database
  - `chacha20poly1305` - Encryption
  - `serde_json` - JSON serialization
  - `tracing` - Structured logging

### iOS App
- **Language**: Swift 5.9
- **Framework**: SwiftUI
- **Min iOS**: 17.0
- **Key Features**:
  - Face ID/Touch ID (LocalAuthentication)
  - Bluetooth (CoreBluetooth)
  - Push Notifications (UserNotifications)

### Browser Extension
- **Language**: JavaScript (ES6+)
- **Target**: Chrome/Chromium (extensible to Firefox)
- **Manifest**: v3

### TLS Terminator
- **Language**: Swift
- **Framework**: Network.framework
- **Purpose**: Bridge HTTPS ↔ Unix socket

---

## Development Workflow

### Building

```bash
# macOS Agent
cd apps/agent-macos
cargo build --release

# iOS App
cd apps/app-ios
xcodebuild -scheme ArmadilloMobile build

# Browser Extension
cd apps/webext
npm install
npm run build
```

### Testing

```bash
# Rust tests
cargo test -p agent-macos

# Audit verification
cargo run --bin agent-cli -- audit verify

# Smoke test
./scripts/smoke-test.sh
```

### Running

```bash
# Start agent
./target/release/agent-macos

# Install TLS terminator (in separate terminal)
cd apps/tls-terminator-macos
xcodebuild # installs to /Applications

# Load extension in Chrome
chrome://extensions → Load unpacked → apps/webext/dist
```

---

## Target Users

### Primary Users

1. **Security-Conscious Professionals**
   - Developers, security engineers, journalists
   - Need strong security without complexity
   - Willing to use iPhone + Mac ecosystem

2. **Privacy Advocates**
   - Don't trust cloud password managers
   - Want local-only solution
   - Comfortable with slightly more friction for better security

3. **Enterprise Users** (Future)
   - IT admins who want on-premise credential management
   - Zero cloud dependency requirement
   - Audit trail for compliance

### Not For

- Users who need cross-platform (Windows/Android)
- Users who need cloud sync for multiple devices
- Users who don't have both Mac and iPhone
- Users who want "just works" simplicity (this requires setup)

---

## Competitive Landscape

### vs. 1Password / Bitwarden / LastPass

| Feature | Armadillo | Cloud Password Managers |
|---------|-----------|------------------------|
| Cloud Dependency | None | Required |
| Master Password | None (Face ID) | Yes |
| Proximity Check | Yes | No |
| Audit Trail | Cryptographic | Basic logs |
| Browser Extension | Local TLS | Cloud sync |
| Cross-Platform | Mac + iOS only | All platforms |
| Ease of Setup | Medium | Easy |

**Trade-off**: Armadillo is more secure but less convenient.

### vs. Hardware Security Keys (YubiKey)

| Feature | Armadillo | Hardware Keys |
|---------|-----------|---------------|
| Credential Storage | Yes | No (just auth) |
| Auto-fill | Yes | No |
| Proximity | Automatic | Manual plug |
| Lost Device | Recoverable | Lost forever |
| Cost | Free | $50-100 |

---

## Vision for 1.0 Release

### Must-Have Features

- [x] Secure credential storage
- [x] Proximity-based access control
- [x] Session management
- [ ] iOS app with full pairing flow
- [ ] Remote approval via iPhone
- [ ] Browser extension with polished UX
- [ ] Recovery flow for lost iPhone
- [ ] Migration tool from 1Password/etc

### Nice-to-Have

- [ ] Safari extension support
- [ ] Firefox extension support
- [ ] iPad app
- [ ] Hardware security key fallback
- [ ] Enterprise admin console
- [ ] Encrypted export/import

### Success Metrics

**Security**:
- Zero credential exposure in logs/memory dumps
- Audit trail passes cryptographic verification
- Resistance to common attack vectors

**Usability**:
- Setup < 5 minutes
- Auto-fill latency < 500ms
- Approval flow < 3 seconds

**Reliability**:
- 99.9% uptime (local, no cloud dependency)
- Zero data loss
- Seamless TLS rotation

---

## Contributing

### Getting Started

1. Clone the repo
2. Read `docs/` for architecture details
3. Check `task.md` for current work
4. Run tests: `cargo test -p agent-macos`
5. See open issues for contribution ideas

### Code Standards

- **Rust**: Follow `rustfmt` + `clippy` recommendations
- **Swift**: Follow Swift style guide
- **Commits**: Conventional commits (feat:/fix:/docs:)
- **Tests**: Required for new features
- **Documentation**: Update docs/ for architectural changes

---

## License

[TBD - likely MIT or Apache 2.0]

---

## Contact

- **Project Lead**: [Your name/contact]
- **Repository**: https://github.com/sergius888/Armadilo
- **Documentation**: See `docs/` directory

---

## Appendix: Key Milestones Roadmap

### Phase 1: Security Foundation (Complete ✅)
- M1.1: Secure permissions
- M1.2: TLS rotation
- M1.3: Audit logging
- M1.4a/b: Proximity system
- M1.5: Monotonic TTL (95% done)

### Phase 2: Remote Approvals (Next)
- TOTP implementation
- Push notification system
- Approval request/response flow

### Phase 3: User Experience
- iOS app MVP
- Browser extension polish
- Onboarding flow
- Recovery system

### Phase 4: Release
- Security audit
- Performance optimization
- Documentation
- Public beta

### Future Phases
- Enterprise features
- Cross-platform (maybe)
- Advanced policy engine
- Integration APIs
