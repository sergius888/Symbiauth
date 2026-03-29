# ADR-0001: Use TLS 1.3 Mutual Authentication Instead of Noise Protocol

## Status
Accepted

## Context
We need to establish a secure communication channel between iOS and macOS for the Armadillo pairing system. Two main options were considered:

1. **Noise XX Protocol**: Custom cryptographic protocol with Ed25519/X25519 keys
2. **TLS 1.3 Mutual Authentication**: Platform-native TLS with P-256 keys in hardware

## Decision
We will use TLS 1.3 mutual authentication with P-256 keys stored in platform security modules (Secure Enclave on iOS, Keychain on macOS).

## Rationale

### Advantages of TLS 1.3 Approach
- **Platform Integration**: Native support on iOS/macOS with hardware-backed keys
- **Reduced Complexity**: No custom crypto implementation needed
- **Hardware Security**: P-256 keys can be non-exportable in Secure Enclave
- **Solo Builder Friendly**: Leverages well-tested platform APIs
- **Future Migration**: Clean abstraction allows switching to Noise later if needed

### Disadvantages of Noise Protocol
- **Implementation Risk**: No mature, first-party Noise stack on iOS/Swift
- **Custom Crypto**: Higher risk of implementation errors for solo developer
- **Limited Hardware Integration**: Harder to leverage Secure Enclave features

## Implementation Details
- **iOS**: Generate P-256 keypair in Secure Enclave (non-exportable)
- **macOS**: P-256 keys in Keychain with appropriate access controls
- **ALPN**: Use "armadillo/1.0" to prevent protocol confusion
- **Certificate Pinning**: Pin certificate fingerprints during pairing
- **SAS Verification**: Use TLS Exporter for Short Authentication String derivation

## Consequences
- Faster development timeline for solo builder
- Reduced security audit surface area
- Platform-specific implementation (iOS/macOS only initially)
- Dependency on Apple's TLS implementation
- Clean migration path to Noise protocol if cross-platform support needed later

## Alternatives Considered
- **Noise XX with libsodium**: Rejected due to iOS integration complexity
- **WebRTC**: Rejected due to unnecessary complexity for local network use
- **Custom protocol**: Rejected due to security implementation risks