# Armadillo Architecture

## Overview

Armadillo implements a secure pairing system between iOS and macOS using QR codes and TLS 1.3 mutual authentication. The system prioritizes simplicity and security for solo development.

## Component Architecture

```
┌─────────────────┐         ┌─────────────────┐
│   iOS App       │         │  macOS Agent    │
│                 │         │                 │
│ ┌─────────────┐ │         │ ┌─────────────┐ │
│ │QR Scanner   │ │   mDNS  │ │Bonjour Svc  │ │
│ │             │◄├─────────┤►│             │ │
│ └─────────────┘ │         │ └─────────────┘ │
│                 │         │                 │
│ ┌─────────────┐ │         │ ┌─────────────┐ │
│ │TLS Client   │ │  TLS1.3 │ │Swift TLS    │ │
│ │(Network.fw) │◄├─────────┤►│Terminator   │ │
│ └─────────────┘ │         │ └──────┬──────┘ │
│                 │         │        │        │
│ ┌─────────────┐ │         │ ┌──────▼──────┐ │
│ │Secure       │ │         │ │Rust Agent  │ │
│ │Enclave      │ │         │ │(Business    │ │
│ │(P-256 keys) │ │         │ │Logic)       │ │
│ └─────────────┘ │         │ └─────────────┘ │
└─────────────────┘         └─────────────────┘
```

## Communication Flow

1. **iOS ↔ macOS TLS Terminator**: TLS 1.3 mutual authentication over local network
2. **TLS Terminator ↔ Rust Agent**: Unix domain socket with framed JSON messages
3. **Rust Agent ↔ Chrome Extension**: Native Messaging (stdin/stdout JSON)

## Security Boundaries

- **TLS Layer**: Handles all cryptographic operations, certificate management
- **Business Logic**: Rust agent manages pairing state, credentials, session logic
- **UI Layer**: iOS app and Chrome extension handle user interactions

## Identity Persistence and Reconnect

- The macOS TLS terminator persists its server identity:
  - Reuses a Keychain certificate labeled "Armadillo TLS Dev Identity"
  - Writes DER copy to `~/.armadillo/server_identity.der`
  - Result: the server fingerprint stays stable across restarts (ports may change)
- iOS pins the server fingerprint on first pairing and persists the last working endpoint.
- On reconnect failures (ECONNREFUSED/timeout), the iOS app browses `_armadillo._tcp` briefly, prefers IPv4, and retries candidates; it only updates the cached endpoint after pin + ping succeed.

## Message Protocol

All components use the same JSON message schema defined in `packages/protocol/json/messages.schema.json` to ensure consistency and type safety across the system.