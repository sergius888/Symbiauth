# Message Schema Documentation

## Overview

Armadillo uses a unified JSON message schema across all components to ensure type safety and consistency. The schema is defined in `packages/protocol/json/messages.schema.json`.

## Message Types

### Pairing Messages

#### PairingRequest
Sent by iOS app to initiate pairing with macOS agent.

```json
{
  "type": "pairingRequest",
  "sid": "session-id-from-qr",
  "tok": "one-time-pairing-token",
  "deviceId": "iPhone-Alice",
  "clientFp": "sha256:client-cert-fingerprint"
}
```

#### PairingResponse
Response from macOS agent with SAS code for verification.

```json
{
  "type": "pairingResponse",
  "success": true,
  "sasRequired": true,
  "error": null
}
```

### Credential Messages

#### RequestCredential
Sent by Chrome extension to request credentials for a domain.

```json
{
  "type": "requestCredential",
  "domain": "example.com"
}
```

#### Credential
Response containing username/password for autofill.

```json
{
  "type": "credential",
  "username": "user@example.com",
  "password": "secure-password"
}
```

### Session Messages

#### EndSession
Terminates the current session and locks the desktop.

```json
{
  "type": "endSession",
  "reason": "user-requested"
}
```

#### Error
Generic error message for any failure condition.

```json
{
  "type": "error",
  "code": "INVALID_TOKEN",
  "message": "Pairing token has expired"
}
```

## Transport Framing

### Unix Domain Socket (Swift ↔ Rust)
- **Format**: `u32` big-endian length + UTF-8 JSON
- **Max Frame Size**: 64KB
- **Socket Path**: `/var/run/armadillo.sock` (production), `/tmp/armadillo.sock` (development)

### Chrome Native Messaging (Rust ↔ Extension)
- **Format**: `u32` little-endian length + UTF-8 JSON (Chrome standard)
- **Max Message Size**: 1MB (Chrome limit)
- **Transport**: stdin/stdout pipes