### Armadillo — Current Technology Overview (as of Oct 2025)

This document summarizes the system that exists today: what components we have, how they interact, the security model, what persists across restarts, how reconnection works, what’s running in development, and known limitations. It is intentionally scoped to the current implementation (not future plans).

### High‑Level Architecture

```text
    iOS App (Swift, TLS client)
          │
          │  TLS 1.3 with mutual authentication (mTLS)
          ▼
 macOS TLS Terminator (Swift, server + local CA)
          │
          │  Unix Domain Socket (UDS), framed messages (len:4BE + body)
          ▼
       Rust Agent (UDS server, business logic)
```

### Components

- **iOS App (Swift)**
  - Discovers the macOS TLS terminator via Bonjour/mDNS.
  - Establishes a TLS 1.3 connection with mutual authentication.
  - Enforces certificate pinning against the server’s SHA‑256 fingerprint (from first‑pair QR or cache).
  - Sends/receives framed messages over the TLS channel; handles clean EOFs.
  - Persists the last known agent endpoint and paired fingerprint for auto‑connect.

- **macOS TLS Terminator (Swift)**
  - Listens on two ports:
    - 8444: Enrollment endpoint (receives CSR, issues client certificate).
    - 8443: Main mTLS endpoint (iOS connects here for normal operation).
  - Acts as a minimal local CA to sign iOS client certificates during enrollment.
  - Persists its own server identity (key + self‑signed cert) to keep a stable fingerprint across restarts.
  - Bridges plaintext IPC to the Rust agent over a Unix Domain Socket using a framed protocol.
  - Advertises itself via Bonjour with a stable instance name and TXT metadata.

- **Rust Agent (Rust + tracing)**
  - Hosts a UDS server that accepts a single framed plaintext stream per connection.
  - Implements connection‑scoped spans (conn/sid/fp_suffix) for correlated logs.
  - Acts as the integration point for future features (browser extension/native integrations).

### Security Model (implemented today)

- **Mutual TLS (TLS 1.3)**: Both sides present certificates. The iOS app holds a client `SecIdentity`. The macOS TLS server presents a self‑signed server certificate.
- **Server Certificate Pinning**: iOS pins the server’s SHA‑256 fingerprint captured during initial pairing (QR) and enforces it on every connect.
- **Client Certificate Enrollment**: iOS generates a keypair and PKCS#10 CSR using `swift‑certificates`; the macOS TLS terminator (local CA) issues a client certificate over HTTPS (port 8444).
- **Key Storage**:
  - iOS: client `SecIdentity` (private key + cert) stored in Keychain.
  - macOS: server identity persisted to Keychain and DER on disk to keep a stable fingerprint.
- **IPC Isolation**: The TLS terminator terminates TLS and forwards plaintext to the Rust agent only over a local UDS.

### Discovery and Pairing

- **Bonjour/mDNS**: The macOS TLS terminator advertises a persistent instance name and includes the full SHA‑256 fingerprint (`fp_full`) in the TXT record.
- **First Pair (QR)**: The iOS app scans a QR that conveys the expected server fingerprint and initial endpoint. After successful pin + TLS + ping, the endpoint is cached.
- **Auto‑Reconnect**:
  - iOS first attempts the cached host:port with the pinned fingerprint.
  - On connection‑refused/timeout, iOS performs Bonjour discovery and tries candidates (preferring IPv4) but still enforces the same pinned fingerprint.
  - On success, the endpoint cache is updated.

### Persistence Details

- **macOS TLS Server Identity**
  - Stored at: `~/.armadillo/server_identity.der` (certificate) and in Keychain (label: "Armadillo TLS Dev Identity").
  - On launch: load from disk → else Keychain → else generate new keypair/cert and persist.
  - Outcome: server fingerprint remains stable across restarts, enabling reliable pinning.

- **Bonjour Instance**
  - Instance name persisted via `UserDefaults` to remain stable across runs.
  - TXT record includes `fp_full` for clients to correlate identity during discovery.

- **iOS Paired Agent Cache**
  - Stored via `UserDefaults` as `host`, `port`, `name`, and `fingerprint` of the last good connection.
  - Used to auto‑connect on app launch and to constrain discovery to the pinned identity.

- **iOS Client Identity**
  - Private key and issued certificate stored in Keychain.
  - CSR created with `swift‑certificates` and signed via Secure Enclave/Keychain key.

### IPC Protocol (TLS Terminator ↔ Rust Agent)

- **Transport**: Unix Domain Socket on the local machine.
- **Framing**: 4‑byte big‑endian length prefix followed by `length` bytes of payload.
- **EOF Handling**: Clean EOFs are treated as normal disconnects; no spurious framing errors on close.

### Logging and Observability

- **Swift (iOS + macOS)**: Structured logging categories with contextual prefix fields (`role`, `cat`, `sid`, `conn`, `fp_suffix`). Hex dumps capped for safety.
- **Rust**: `tracing` with spans that carry `role="agent"`, `cat="uds"`, `conn`, and (after first message) `sid` and `fp_suffix`.
- **Env Controls (Rust)**: `ARMADILLO_LOG` and `ARMADILLO_LOG_FORMAT` control verbosity and format (compact/JSON).

### Developer Runbook (current dev flow)

- **Start Rust Agent**
  - From repo root: `cargo run -p agent-macos`
  - Or: `cd apps/agent-macos && cargo run`

- **Start macOS TLS Terminator**
  - Xcode: open `apps/tls-terminator-macos/ArmadilloTLS.xcodeproj`, build & run.
  - CLI (example): `xcodebuild -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj -scheme ArmadilloTLS -configuration Debug -derivedDataPath build && open build/Build/Products/Debug/ArmadilloTLS.app`

- **Run iOS App**
  - Open the iOS project in Xcode and run on device/simulator.
  - First time: scan the QR to pair (captures server fingerprint). Thereafter: auto‑connect uses cache + discovery.

### Notable Engineering Fixes Achieved

- **EOF framing fix**: iOS reader handles clean closes without "Invalid frame header" errors.
- **HTTP enrollment delivery**: Server retains `NWConnection` until full body sent; headers/body sent atomically; clean close semantics.
- **Valid CSR generation**: iOS uses `swift‑certificates` to build correct PKCS#10 DER CSR.
- **Stable server identity**: macOS TLS server identity persisted (Keychain + disk) to prevent fingerprint drift.
- **Resilient auto‑reconnect**: iOS falls back to Bonjour discovery on refusal/timeout while enforcing the pinned fingerprint.
- **Structured logs**: Correlated by `conn`, with `sid` and `fp_suffix` threaded across layers; hex dumps capped.

### Current Limitations (by design, today)

- **No password management or proximity gating of browser autofill** yet; current focus is secure pairing and transport.
- **No WebAuthn/passkey integration** yet; can be layered on where sites support it.
- **No UDS ping CLI tool** yet; debugging currently via app logs (planned utility).
- **Single‑machine scope**: The Rust agent runs locally; multi‑device federation is not implemented.
- **Windows/Linux**: Not targeted yet.

### Security Posture (today)

- mTLS for transport confidentiality and mutual authentication.
- Certificate pinning to a persisted, stable server identity.
- Keys and identities stored in platform key stores (Keychain) where applicable.
- Conservative error handling (clear cache on pin mismatch or fatal TLS errors; do not silently downgrade).

### What This Enables Right Now

- A robust, secure, and observable channel from iOS to a local macOS process (Rust agent) with auto‑reconnection and identity guarantees.
- A clean foundation to layer higher‑level features (e.g., approvals, proximity hints, browser‑facing workflows) without revisiting core crypto/IPC plumbing.

### Branding

- Internal name: Armadillo (development phase).
- Planned external brand: DreiGlaser (`com.dreiglaser.*`).
- Rebranding steps are recorded in `../DEVELOPMENT_ROADMAP.md` and will be applied post‑MVP.


