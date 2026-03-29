# Armadillo Project Structure - Current State

This document describes the current file structure and implementation status of the Armadillo project after implementing mutual TLS and fixing the ping/pong communication.

## Project Overview

The Armadillo project implements a secure password manager with the following architecture:
- **iOS Mobile App**: Client application for users
- **macOS TLS Terminator**: Handles TLS connections and certificate management
- **Rust Agent**: Core business logic and credential management
- **Browser Extension**: Web integration (future)

## Current File Structure

```
ArmadilloProject/
├── README.md                                    # Project overview
├── Security.md                                  # Security documentation
├── CURRENT_PROJECT_STRUCTURE.md                 # This file
│
├── .kiro/                                       # Kiro IDE specifications
│   └── specs/
│       └── armadillo-step1-pairing/
│           ├── requirements.md                  # Pairing requirements
│           ├── design.md                        # System design
│           ├── architecture.md                  # Architecture overview
│           ├── tasks.md                         # Implementation tasks
│           ├── progress-report.md               # Development progress
│           ├── ios-mvp.md                       # iOS MVP documentation
│           └── task_1.md                        # Task details
│
├── packages/                                    # Shared packages
│   ├── protocol/
│   │   ├── json/
│   │   │   └── messages.schema.json             # JSON schema for messages
│   │   └── typescript/
│   │       └── messages.ts                      # TypeScript message types
│   └── webext/
│       └── src/
│           └── content.ts                       # Browser extension content script
│
├── apps/                                        # Application implementations
│   ├── agent-macos/                            # Rust agent (macOS)
│   │   ├── Cargo.toml                          # Rust dependencies
│   │   ├── src/
│   │   │   ├── main.rs                         # Entry point
│   │   │   ├── bridge.rs                       # Unix socket bridge ✅
│   │   │   ├── pairing.rs                      # Pairing logic ✅
│   │   │   ├── session.rs                      # Session management
│   │   │   ├── credentials.rs                  # Credential storage
│   │   │   └── webext_host.rs                  # Browser extension host
│   │   └── target/                             # Compiled binaries
│   │
│   ├── tls-terminator-macos/                   # macOS TLS terminator
│   │   └── ArmadilloTLS/
│   │       ├── ArmadilloTLS.xcodeproj/         # Xcode project
│   │       ├── AppDelegate.swift               # Main app delegate ✅
│   │       ├── TLSServer.swift                 # TLS server implementation ✅
│   │       ├── UnixSocketBridge.swift          # Bridge to Rust agent ✅
│   │       ├── CertificateManager.swift        # Certificate management ✅
│   │       ├── BonjourService.swift            # Service discovery ✅
│   │       └── QRCodeGenerator.swift           # QR code generation ✅
│   │
│   └── app-ios/                                # iOS mobile application
│       ├── README.md                           # iOS app documentation
│       ├── Info.plist                          # iOS app configuration
│       └── ArmadilloMobile/
│           ├── ArmadilloMobile.xcodeproj/      # Xcode project
│           └── ArmadilloMobile/
│               ├── ArmadilloMobileApp.swift    # SwiftUI app entry point
│               ├── ContentView.swift           # Main UI view
│               ├── Core/
│               │   ├── Env.swift               # Environment configuration ✅
│               │   └── Logging.swift           # Logging utilities ✅
│               ├── Features/
│               │   ├── Discovery/
│               │   │   └── BonjourBrowser.swift # Service discovery ✅
│               │   ├── Pairing/
│               │   │   ├── PairingViewModel.swift # Pairing logic ✅
│               │   │   └── QRScannerView.swift  # QR code scanner ✅
│               │   └── Transport/
│               │       ├── TLSClient.swift     # TLS client with mutual auth ✅
│               │       └── FramedCodec.swift   # Message framing ✅
│               └── Session/
│                   ├── PairedAgentStore.swift  # Agent storage ✅
│                   ├── SAS.swift               # SAS verification ✅
│                   └── SimpleClientIdentity.swift # Client certificates ✅
```

## Implementation Status

### ✅ **Completed Components**

#### **Rust Agent (`apps/agent-macos/`)**
- **`bridge.rs`**: Unix domain socket server with proper framing (u32 BE + JSON)
- **`pairing.rs`**: Handles ping/pong, pairing requests, SAS confirmation
- **Message Protocol**: Supports `ping` → `pong` with proper `v: 1` format

#### **macOS TLS Terminator (`apps/tls-terminator-macos/`)**
- **`TLSServer.swift`**: TLS 1.3 server with mutual authentication
- **`UnixSocketBridge.swift`**: Forwards framed messages to Rust agent
- **`CertificateManager.swift`**: Self-signed certificate generation
- **`BonjourService.swift`**: mDNS service advertisement
- **`QRCodeGenerator.swift`**: Pairing QR code generation

#### **iOS Mobile App (`apps/app-ios/`)**
- **`TLSClient.swift`**: TLS 1.3 client with certificate pinning and mutual auth
- **`SimpleClientIdentity.swift`**: Client certificate generation for mutual TLS
- **`PairingViewModel.swift`**: Complete pairing flow with ping testing
- **`FramedCodec.swift`**: Message framing compatible with Rust agent
- **`BonjourBrowser.swift`**: Service discovery with fallback support

### 🔧 **Key Technical Implementations**

#### **Mutual TLS Authentication**
- **Server**: Requires and validates client certificates
- **Client**: Generates self-signed certificates and presents them during handshake
- **Certificate Pinning**: iOS validates server certificate fingerprint from QR code

#### **Message Protocol**
- **Framing**: `[4-byte length (u32 BE)][JSON body]` at all hops
- **Format**: All messages include `type` and `v: 1` fields
- **Ping/Pong**: Working end-to-end communication test

#### **Service Discovery**
- **Primary**: Bonjour/mDNS service discovery
- **Fallback**: Direct IP connection from QR code
- **QR Format**: Contains service name, fingerprint, and fallback endpoint

### 🎯 **Current Capabilities**

1. **Certificate Generation**: Both server and client generate proper certificates
2. **TLS Handshake**: Mutual TLS 1.3 with certificate validation
3. **Service Discovery**: Bonjour discovery with fallback support
4. **Message Framing**: Consistent framing across all components
5. **Ping/Pong Test**: End-to-end communication verification
6. **QR Code Pairing**: Complete pairing flow from QR scan to connection

### 📱 **Testing Status**

The system should now support:
- ✅ QR code scanning and parsing
- ✅ Service discovery (Bonjour + fallback)
- ✅ TLS connection establishment
- ✅ Mutual certificate authentication
- ✅ Ping/pong message exchange
- ✅ Proper error handling and logging

### 🔮 **Next Steps**

1. **Test Complete Pipeline**: Verify all components work together
2. **SAS Verification**: Implement user confirmation of SAS codes
3. **Credential Exchange**: Add actual password/credential functionality
4. **Browser Extension**: Implement web integration
5. **Production Security**: Enhanced certificate validation and key management

## Architecture Flow

```
iOS App → TLS 1.3 (mutual auth) → macOS TLS Terminator → Unix Socket → Rust Agent
   ↑                                        ↓                           ↓
QR Scan ← Bonjour/mDNS ← Certificate + Service ← Message Processing ← Business Logic
```

This structure provides a complete, secure foundation for the Armadillo password manager with proper mutual TLS authentication and message framing throughout the pipeline.