### Current Codebase & File Tree

This document captures the repository layout, primary languages/build systems, where binaries/artifacts are produced, existing IPC schemas, and the current build/run flow. It reflects the code as it exists now.

### Top‑Level Layout

```text
/
  apps/
    agent-macos/                 # Rust agent (UDS server + core logic)
    app-ios/                     # iOS app (Swift)
    tls-terminator-macos/        # macOS TLS terminator app (Swift)
  docs/                          # Architecture and protocol docs
  packages/                      # Protocol + web extension scaffolding
  scripts/                       # Dev helpers
  tooling/                       # Lint/format configs
  README.md, Security.md, Makefile
```

### apps/ (by product)

```text
apps/agent-macos/
  Cargo.toml                     # Rust workspace member
  src/
    main.rs                      # Entrypoint; tracing subscriber
    bridge.rs                    # UDS framed server; spans (conn/sid/fp_suffix)
    pairing.rs                   # Pairing/session helpers
    session.rs                   # Session management
    credentials.rs               # Identity helpers
    webext_host.rs               # Native messaging scaffold (future)
  tests/
    bridge_test.rs               # UDS framing tests

apps/app-ios/ArmadilloMobile/
  ArmadilloMobile/
    ArmadilloMobileApp.swift     # App entry
    ContentView.swift            # Root UI
    Core/
      Env.swift
      Logging.swift              # Structured logging helpers
    Features/
      Discovery/BonjourBrowser.swift
      Pairing/
        PairingViewModel.swift   # Pairing + auto-connect + persistence
        QRPayload.swift
        QRScannerView.swift
      Transport/
        FramedCodec.swift        # 4-byte BE length frames
        Messages.swift
        TLSClient.swift          # TLS 1.3 client, mTLS, pinning
    Session/
      PairedAgentStore.swift     # Last endpoint cache (host/port/fp/name)
      Pinning.swift              # Fingerprint pinning
      SAS.swift                  # Short Authentication String
      SimpleClientIdentity.swift # CSR (swift-certificates) + SecIdentity
  ArmadilloMobile.xcodeproj/

apps/tls-terminator-macos/
  ArmadilloTLS/
    AppDelegate.swift
    BonjourService.swift         # mDNS advertise; stable instance; TXT fp_full
    CertificateManager.swift     # Persist server identity (Keychain + DER on disk)
    EnrollmentServer.swift       # Port 8444: CSR HTTP endpoint → issues client cert
    TLSServer.swift              # Port 8443: main mTLS server
    UnixSocketBridge.swift       # UDS client to Rust agent; framed IPC
    AppGroup.swift, Info.plist, entitlements, assets, xib
  ArmadilloTLS.xcodeproj/
```

### Languages & Build Systems

- **Swift (iOS/macOS)**: Xcode projects build the iOS app and the macOS TLS app.
- **Rust (agent)**: Cargo builds the agent (`cargo build`, `cargo run`).
- **TypeScript (web extension scaffold)**: `packages/webext` (not part of the main runtime yet).
- **Python (scripts)**: small helpers in `scripts/` for dev.

### Binaries / Artifacts

- **macOS TLS Terminator**: produces a `.app` bundle via Xcode (`ArmadilloTLS.app`).
- **iOS App**: built/run via Xcode onto device/simulator (no standalone binary in repo).
- **Rust Agent**: produces native binaries under `apps/agent-macos/target/{debug,release}/`.
- **Persisted Identity**: server certificate DER stored at `~/.armadillo/server_identity.der`; also in Keychain under label "Armadillo TLS Dev Identity".

### IPC / API Specs

- **UDS Framed Protocol**: 4‑byte big‑endian length prefix followed by payload bytes (Swift ↔ Rust).
- **Message Schema**: `packages/protocol/json/messages.schema.json` (and TS stub in `packages/protocol/typescript/messages.ts`).
- **TLS Enrollment**: HTTP over port 8444 accepts a PKCS#10 CSR (DER) and returns a signed client certificate.

### Build & Run Flow (development)

- **Rust Agent**
  - From repo root: `cargo run -p agent-macos`
  - Or: `cd apps/agent-macos && cargo run`

- **macOS TLS Terminator**
  - Open `apps/tls-terminator-macos/ArmadilloTLS.xcodeproj` and Run (Debug) in Xcode.
  - Alternative CLI build is possible with `xcodebuild` if desired.

- **iOS App**
  - Open `apps/app-ios/ArmadilloMobile/ArmadilloMobile.xcodeproj` (or workspace) in Xcode and Run on device/simulator.
  - First run: scan QR to capture the server fingerprint and initial endpoint; app performs CSR enrollment and mTLS connect.
  - Subsequent runs: auto‑connect using cached endpoint with Bonjour discovery fallback, enforcing pinned fingerprint.

### Notes

- Discovery via Bonjour/mDNS with stable instance name and `fp_full` in TXT record.
- Server identity persistence ensures stable fingerprint across restarts (required for pinning).
- Clean EOF handling on iOS prevents framing errors on disconnect.
- Structured logging across layers with correlation IDs (`conn`, `sid`, `fp_suffix`).

### Exact Network & Service Parameters

- Main TLS server (mTLS): dynamic ephemeral port selected at runtime by `TLSServer`.
  - ALPN: `"armadillo/1.0"`.
  - Client auth: required by default; can be toggled off in dev via env (see below).
- Enrollment server (HTTP over TLS): fixed port `8444` (see `EnrollmentServer`).
  - ALPN: `"http/1.1"`.
- Bonjour service (discovery): type `_armadillo._tcp.` with a stable instance name (persisted).
  - TXT keys: `v="1"`, `fp` (short suffix), `fp_full` (full SHA‑256), `port` (TLS port), `caps="pairing,auth"`.

### Socket & IPC Details

- UDS framed protocol: 4‑byte big‑endian length + payload.
- Socket path resolution (Swift TLS terminator):
  1) `ARMADILLO_SOCKET_PATH` env override (tilde expanded)
  2) `~/.armadillo/a.sock` if present
  3) App Group `group.com.armadillo` container at `…/ipc/a.sock` if present
  4) Fallback `~/.armadillo/a.sock`
- Helper script to compute path (creates parent dir if needed): `swift get_socket_path.swift`.
- Rust agent binds the socket path and sets `0600` permissions; removes stale file on start.

### Environment Variables & Toggles

- Rust logging:
  - `ARMADILLO_LOG` (e.g., `info`, or module filters)
  - `ARMADILLO_LOG_FORMAT=json` (JSON output)
- Socket override used by both sides: `ARMADILLO_SOCKET_PATH=/absolute/path/to/a.sock`
- TLS server dev toggles (Swift):
  - `DEV_NO_CLIENT_AUTH=1` or `MVP_MODE=1` → disable client cert authentication (dev only). Default is mutual auth required.

### Identity Persistence (macOS TLS)

- Server certificate DER on disk: `~/.armadillo/server_identity.der`.
- Keychain label: `Armadillo TLS Dev Identity` (used for reuse across restarts).
- CN format: `ArmadilloTLS-<12‑char id>` persisted in `UserDefaults` to maintain identity continuity.

### Verification / Smoke Tests

- Agent UDS round‑trip (no iOS needed):
  1) Start agent: `cargo run -p agent-macos`
  2) Confirm socket path: `swift get_socket_path.swift` (or set `ARMADILLO_SOCKET_PATH`)
  3) Ping: `python3 scripts/ping_agent.py`
- TLS startup:
  - Run the macOS TLS app in Xcode; observe log lines for: ready port, Bonjour publish, and server fingerprint.
- iOS pairing:
  - First launch: scan QR, observe enrollment success and mTLS connect; then ping.
  - Restart TLS (port changes), relaunch iOS: auto‑connect via Bonjour with pinning should succeed; cache updates.

### Branding

- Dev phase: keep "Armadillo" names internally.
- Target brand: "DreiGlaser" (`com.dreiglaser.*`).
- See Rebranding Plan in the roadmap: `../DEVELOPMENT_ROADMAP.md`.


