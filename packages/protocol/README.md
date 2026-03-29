# Armadillo Protocol Definitions

This package contains shared protocol definitions and message schemas used across all Armadillo components.

## Structure

- `json/` - JSON Schema definitions for all message types
- Generated TypeScript types for the Chrome extension
- Rust type definitions for the agent

## Usage

### TypeScript (Chrome Extension)
```typescript
import { PairingRequest, PairingResponse } from './generated/types';

const request: PairingRequest = {
  type: 'pairingRequest',
  sid: 'session-id',
  tok: 'pairing-token',
  deviceId: 'iPhone-Alice',
  clientFp: 'sha256:fingerprint'
};
```

### Rust (Agent)
```rust
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
struct PairingRequest {
    #[serde(rename = "type")]
    msg_type: String,
    sid: String,
    tok: String,
    device_id: String,
    client_fp: String,
}
```

### Swift (iOS/macOS)
```swift
struct PairingRequest: Codable {
    let type: String
    let sid: String
    let tok: String
    let deviceId: String
    let clientFp: String
}
```

## Schema Validation

All messages should be validated against the JSON schema to ensure compatibility across components. Use appropriate validation libraries for each platform:

- **TypeScript**: `ajv` or similar JSON Schema validator
- **Rust**: `jsonschema` crate
- **Swift**: `JSONSerialization` with custom validation