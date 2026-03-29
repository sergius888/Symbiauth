# Symbiauth Supply Chain Security

## Overview

Supply chain attacks target dependencies and build processes to inject malicious code. Symbiauth mitigates these risks through **dependency auditing**, **minimal features**, **lockfile pinning**, and **fuzzing**.

---

## Rust (Agent)

### **cargo-audit**

Checks dependencies against RustSec Advisory Database for known vulnerabilities.

**CI Integration** (`.github/workflows/cargo-audit.yml`):

```yaml
name: cargo-audit
on:
  push:
  schedule:
    - cron: '0 0 * * *' # Daily at midnight UTC

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo install cargo-audit
      - run: cargo audit --deny warnings
```

**Properties**:
- **Fail on warnings**: Any advisory triggers failure
- **Daily runs**: Catches newly disclosed vulnerabilities
- **Advisory DB**: Updated automatically by `cargo-audit`

### **cargo-deny**

Enforces policies on licenses, banned crates, and sources.

**Config** (`.cargo/deny.toml`):

```toml
[advisories]
yanked = "deny"
ignore = []

[licenses]
allow = ["MIT", "Apache-2.0", "BSD-3-Clause"]
deny = ["AGPL-3.0", "GPL-3.0"]

[bans]
multiple-versions = "deny"
deny = [
    { name = "openssl" },  # Use rustls instead
]

[sources]
allow-git = []  # Only allow crates.io
required-git-spec = "deny"
```

**CI Integration**:

```yaml
- run: cargo install cargo-deny
- run: cargo deny check
```

**Properties**:
- **No GPL/AGPL**: Avoids copyleft licenses
- **No OpenSSL**: Prefers pure-Rust `rustls` for security
- **No git deps**: Only audited crates.io packages
- **No yanked crates**: Prevents supply chain attacks via yanking

### **Lockfile Committed**

`Cargo.lock` is **committed to git** for reproducible builds:

```bash
git add Cargo.lock
git commit -m "chore: update dependencies"
```

**Properties**:
- Ensures CI and local use exact same versions
- Prevents automatic updates that introduce vulnerabilities
- Explicit `cargo update` required to change versions

### **Minimal Features**

Only enable necessary features to reduce attack surface:

```toml
[dependencies]
tokio = { version = "1", features = ["rt-multi-thread", "net", "macros"] }
# ❌ NOT: features = ["full"]
```

**Benefits**:
- Smaller binary size
- Fewer dependencies pulled in
- Reduced code audit surface

---

## iOS (Swift)

### **Swift Package Manager (SPM) Pins**

`Package.resolved` pins exact versions:

```json
{
  "pins": [
    {
      "package": "swift-crypto",
      "repositoryURL": "https://github.com/apple/swift-crypto.git",
      "state": {
        "revision": "75ec60b8b4cc0f085c3ac414f3dca5625fa3588e",
        "version": "2.6.0"
      }
    }
  ]
}
```

**CI**: Commit `Package.resolved` to git.

### **Shared Scheme for CI**

Xcode projects must use **shared schemes** for CI to build them:

```bash
# Create shared scheme (run once)
xcodebuild -project ArmadilloMobile.xcodeproj \
  -scheme ArmadilloMobile \
  -showBuildSettings > /dev/null 2>&1

# Commit scheme to git
git add ArmadilloMobile.xcodeproj/xcshareddata/
```

### **Disable Signing in CI**

CI builds don't need code signing:

```yaml
- name: Xcode build
  run: |
    xcodebuild -project apps/app-ios/ArmadilloMobile/ArmadilloMobile.xcodeproj \
      -scheme ArmadilloMobile \
      -configuration Debug \
      -sdk iphonesimulator \
      CODE_SIGNING_ALLOWED=NO
```

**Benefits**:
- No need for provisioning profiles in CI
- Faster builds
- Prevents cert-related failures

---

## Browser Extension (WebExt)

### **MV3 Minimal Permissions**

Manifest V3 restricts permissions to minimum necessary:

```json
{
  "manifest_version": 3,
  "permissions": [
    "nativeMessaging"
  ],
  "host_permissions": [
    "http://localhost/*",
    "https://localhost/*"
  ]
}
```

**No broad permissions**:
- ❌ `<all_urls>` (access to all websites)
- ❌ `tabs` (read browsing history)
- ❌ `cookies` (steal session tokens)

### **Lockfile Committed**

`package-lock.json` is **committed to git**:

```bash
npm install
git add package-lock.json
git commit -m "chore: add package-lock.json"
```

**Properties**:
- Exact versions for all transitive dependencies
- Prevents npm from pulling latest (potentially compromised) versions

### **Pin Node Version**

CI uses specific Node version:

```yaml
- uses: actions/setup-node@v4
  with:
    node-version: '20'
```

### **Signed Releases (Future)**

> [!NOTE]
> Planned for Phase 5+.

After distributing to Chrome Web Store, enable **signed updates**:

- Chrome validates extension signature against developer account
- Prevents MitM attacks during update
- Users can verify signature with `chrome://extensions`

---

## Fuzzing

### **cargo-fuzz for UDS Parser**

Fuzz the Unix Domain Socket frame parser to catch buffer overflows, panics, etc.

**Setup** (`apps/agent-macos/fuzz/fuzz_targets/uds_frame.rs`):

```rust
#![no_main]
use libfuzzer_sys::fuzz_target;
use agent_macos::parse_frame;

fuzz_target!(|data: &[u8]| {
    // Should never panic, even on malformed input
    let _ = parse_frame(data);
});
```

**Run locally**:

```bash
cd apps/agent-macos
cargo fuzz run uds_frame -- -max_total_time=60
```

**CI Integration** (nightly):

```yaml
name: fuzz
on:
  schedule:
    - cron: '0 2 * * *' # 2 AM UTC daily

jobs:
  fuzz:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@nightly
      - run: cargo install cargo-fuzz
      - run: cd apps/agent-macos && cargo fuzz run uds_frame -- -max_total_time=300
```

**Properties**:
- Catches panics, buffer overruns, infinite loops
- Runs nightly (not on every push, too slow)
- Uses `libfuzzer` (LLVM coverage-guided fuzzing)

### **Fuzz Targets**

| Target | Code Under Test | Priority |
|--------|----------------|----------|
| `uds_frame` | UDS frame parsing | High (external input) |
| `json_parse` | JSON message deserialization | High (untrusted data) |
| `policy_eval` | YAML policy evaluation | Medium (user-controlled) |
| `ble_decrypt` | BLE advertisement decryption | Medium (proximity spoofing) |

---

## Summary

### **Rust**
- ✅ **cargo-audit**: Daily checks for known vulnerabilities
- ✅ **cargo-deny**: Enforce licenses, ban dangerous crates, deny git deps
- ✅ **Lockfile committed**: Reproducible builds
- ✅ **Minimal features**: Reduce attack surface

### **iOS**
- ✅ **SPM pins**: Exact versions via `Package.resolved`
- ✅ **Shared scheme**: CI can build without local Xcode state
- ✅ **No code signing in CI**: Faster builds, no cert issues

### **WebExt**
- ✅ **MV3 minimal permissions**: No `<all_urls>`, no broad access
- ✅ **Lockfile committed**: `package-lock.json` in git
- ✅ **Pin Node**: Specific Node version in CI
- ⚠️ **Signed releases** (future): Chrome Web Store signatures

### **Fuzzing**
- ✅ **cargo-fuzz**: UDS frame parser, JSON deserialization
- ✅ **Nightly CI**: 5-minute fuzzing runs daily
- ⚠️ **Property tests** (future): QuickCheck for invariant testing

All CI workflows configured to **fail-fast** on security issues, preventing vulnerable code from merging.

---

## WebExt Permissions (Planned Features)

**Current MVP**:
```json
{
  "permissions": ["nativeMessaging"]
}
```

**Future (autofill, cookies)**:
```json
{
  "manifest_version": 3,
  "permissions": [
    "nativeMessaging",
    "scripting",
    "activeTab"
  ],
  "optional_host_permissions": [
    "http://*/*",
    "https://*/*"
  ]
}
```

**No broad permissions**:
- ❌ `"cookies"` in main permissions (only request when user enables cookie sync)
- ❌ `<all_urls>` (use `activeTab` + user-granted per-site permissions)
- ✅ `scripting` (inject autofill content script in isolated world)

**Principles**:
- Request minimum permissions at install
- Use `optional_permissions` for features users can enable later
- Prefer `activeTab` over broad host permissions

---

## npm Hardening

**Use `npm ci` (not `npm install`)**:

```yaml
- run: npm ci  # Uses package-lock.json verbatim
# ❌ NOT: npm install (may update lockfile)
```

**Add npm audit to CI**:

```yaml
- run: npm audit --production --audit-level=high
# Fail on high/critical vulnerabilities in runtime deps
```

**Properties**:
- `npm ci` is reproducible (never modifies lockfile)
- Audit catches known vulnerabilities before deploy
- Use `--production` to ignore devDependencies

---

## macOS App Signing & Notarization (Release)

**Developer ID signing** (required for Gatekeeper):

```bash
# Sign native messaging host
codesign --sign "Developer ID Application: Your Name" \
  --timestamp \
  --options runtime \
  --entitlements nmhost.entitlements \
  dist/nmhost

# Sign agent binary
codesign --sign "Developer ID Application: Your Name" \
  --timestamp \
  --options runtime \
  --entitlements agent.entitlements \
  dist/agent-macos
```

**Notarization** (upload to Apple for malware scan):

```bash
# Create ZIP
ditto -c -k --keepParent dist/nmhost nmhost.zip

# Submit to Apple
xcrun notarytool submit nmhost.zip \
  --apple-id "you@example.com" \
  --password "@keychain:AC_PASSWORD" \
  --team-id "TEAMID" \
  --wait

# Staple ticket (offline verification)
xcrun stapler staple dist/nmhost
```

**CI vs Release**:
- **CI**: `CODE_SIGNING_ALLOWED=NO` (skip signing for PRs)
- **Release pipeline**: Sign + notarize before distribution

**Entitlements** (`nmhost.entitlements`):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
  <key>com.apple.security.network.client</key>
  <true/>
  <key>com.apple.security.files.user-selected.read-write</key>
  <true/>
</dict>
</plist>
```

---

## Automated Dependency Updates

**Dependabot / Renovate**:

```.github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "cargo"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5
    
  - package-ecosystem: "npm"
    directory: "/apps/webext"
    schedule:
      interval: "weekly"
    
  - package-ecosystem: "swift"
    directory: "/apps/app-ios"
    schedule:
      interval: "weekly"
```

**Properties**:
- PRs with CI gates (test must pass before merge)
- Weekly schedule prevents noise
- Limit open PRs to avoid spam

---

## Native Messaging Host Allow-List

**Extension ID validation**:

```rust
const ALLOWED_EXTENSION_IDS: &[&str] = &[
    "abcdefghijklmnopqrstuvwxyz123456", // Production extension ID
];

fn verify_extension_origin(origin: &str) -> Result<()> {
    let extension_id = parse_extension_id(origin)?;
    
    if !ALLOWED_EXTENSION_IDS.contains(&extension_id.as_str()) {
        tracing::error!(
            extension_id = %extension_id,
            "Rejected unknown extension"
        );
        return Err(Error::UnauthorizedExtension);
    }
    
    Ok(())
}
```

**Signed handshake** (challenge-response):

```rust
// 1. nmhost sends nonce
let nonce = generate_random_32bytes();
send_message(&Message::Challenge { nonce })?;

// 2. Extension signs nonce with its private key
// (stored in extension storage, generated on install)
let signature = extension_private_key.sign(&nonce);
send_message(&Message::ChallengeResponse { signature })?;

// 3. nmhost verifies with extension's public key
if !verify_signature(&nonce, &signature, extension_public_key) {
    return Err(Error::InvalidHandshake);
}
```

**Prevents**: Random extensions connecting to nmhost.

---

## Provenance & Build Metadata

**Attach metadata to binaries**:

```rust
// Embed at compile time
const BUILD_COMMIT: &str = env!("GIT_COMMIT");
const BUILD_TIMESTAMP: &str = env!("BUILD_TIME");
const RUSTC_VERSION: &str = env!("RUSTC_VERSION");

fn version_info() {
    println!("agent-macos {} ({})", VERSION, BUILD_COMMIT);
    println!("rustc {}, built at {}", RUSTC_VERSION, BUILD_TIMESTAMP);
}
```

**CI workflow**:

```yaml
- run: |
    echo "GIT_COMMIT=$(git rev-parse HEAD)" >> $GITHUB_ENV
    echo "BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> $GITHUB_ENV
- run: cargo build --release
  env:
    RUSTFLAGS: "--cfg git_commit=\"$GIT_COMMIT\" --cfg build_time=\"$BUILD_TIME\""
```

**Future**: SLSA provenance attestation (Phase 5+).

---

## Swift Fuzz/Property Tests

**TLS framing fuzzer** (SwiftPM target):

```swift
// Tests/TLSFuzzTests/FramingFuzzTests.swift
import XCTest
@testable import ArmadilloTLS

final class FramingFuzzTests: XCTestCase {
    func testFrameParserFuzz() throws {
        // Random byte sequences
        for _ in 0..<10000 {
            let randomBytes = (0..<1024).map { _ in UInt8.random(in: 0...255) }
            
            // Should never crash or hang
            _ = try? TLSFrameParser.parse(Data(randomBytes))
        }
    }
}
```

**Property test** (using swift-check or similar):

```swift
func testRouterInvariant() {
    property("corr_id always unbound after response") <- forAll { (corrId: String) in
        let router = Router()
        router.bind(corrId, conn: "conn1")
        router.send_response(corrId, value: "ok")
        
        return !router.is_bound(corrId) // Must be unbound
    }
}
```

---

## Summary Updates

### **Rust**
- ✅ cargo-audit, cargo-deny, lockfile, minimal features
- ✅ Signed releases with provenance metadata

### **iOS**
- ✅ SPM pins, shared scheme, no code signing in CI

### **WebExt**
- ✅ MV3 minimal permissions, `npm ci + audit`, lockfile
- ✅ Extension ID allow-list + signed handshake at nmhost
- ✅ `activeTab` + optional per-site permissions (no `<all_urls>`)

### **macOS**
- ✅ Developer ID signing + notarization for release
- ✅ Entitlements defined, CI skips signing

### **Automation**
- ✅ Dependabot/Renovate for Rust, npm, Swift deps
- ✅ Fuzzing: Rust UDS parser, Swift TLS framing

