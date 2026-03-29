# Armadillo Codebase Map
### THIS IS PREPIVOT MAP 
This is the definitive, up-to-date map of the Armadillo codebase. It outlines the exact file tree, the purpose of each component, and where key logic resides. 

## High-Level Architecture
The system consists of **4 primary components**:
1. **`apps/agent-macos`** (Rust): The core brain. Runs on the Mac, enforces policy, manages the vault, tracks proximity state, handles UDS requests, and scans for BLE.
2. **`apps/tls-terminator-macos`** (Swift): macOS companion app. Advertises Mac via Bonjour, terminates mTLS connections from the iPhone, and acts as a bridge forwarding iOS requests over UDS to the Rust agent.
3. **`apps/app-ios`** (Swift): The iPhone app. Handles Face ID biometric gating, captures QR codes for pairing, establishes mTLS connections to the Mac, and acts as a BLE peripheral (iBeacon/GATT).
4. **`packages/webext`** (TS/JS): Browser extension. Communicates via Native Messaging with the Rust agent to fill passwords.

---

## 1. Rust Core Agent (`apps/agent-macos/`)

The core authority evaluating trust and proximity. It exposes a Unix Domain Socket (UDS) for communication with the extension and the TLS terminator.

- **`src/main.rs`** - App entry point. Sets up logging, UDS listener, and starts the TLS/BLE background tasks.
- **`src/bridge.rs`** - The UDS framed server logic. Translates UDS packets into typed Rust requests and delegates out to vault/pairing/session subsystems.
- **`src/pairing.rs`** - Logic for handling the initial QR-based pairing flow, generating keys, and returning `wrap_pub_mac`.
- **`src/proximity.rs`** - Proximity State Machine. Owns Near/Far/Grace transitions and expiry logic based on BLE ticks and MAC idle time.
- **`src/ble_scanner.rs`** - CoreBluetooth-based (via `btleplug`) BLE scanner. Used to scan for iOS iBeacons/GATT, reconstruct tokens, validate HMACs (using `k_ble`), and emit `ble.token.valid` / `prox.ble_seen` events.
- **`src/vault.rs`** - Logic handling credential requests/decryption (the vault).
- **`src/policy.rs`** - Policy enforcement rules mapping.
- **`src/wrap.rs`** - Cryptography core. Derives `k_ble` via ECDH + HKDF from pairing material (`device_fp`, `mac_wrap_priv`, `ios_wrap_pub`).
- **`src/session.rs`** - Active session TTL validation and cleanup.
- **`src/mac_idle.rs`** - Interacts with macOS specific APIs (I/O Kit) to determine how long the user has been idle (no mouse/keyboard).

## 2. macOS Swift Companion (`apps/tls-terminator-macos/`)

Provides native macOS network and UI interfaces (Bonjour, TLS) that route down to the Rust agent via UDS.

- **`ArmadilloTLS/AppDelegate.swift`** - Entry point for the macOS App. Spins up servers.
- **`ArmadilloTLS/TLSServer.swift`** - Main mTLS server on ephemeral port (8443). Terminates iOS encrypted connections and bridges frames to UDS.
- **`ArmadilloTLS/EnrollmentServer.swift`** - HTTP port (8444) for initial CSR enrollment and returning client certificates.
- **`ArmadilloTLS/BonjourService.swift`** - Announces the Mac over mDNS (`_armadillo._tcp`) with `fp_full` inside the TXT record so iOS can auto-discover the dynamic port.
- **`ArmadilloTLS/UnixSocketBridge.swift`** - UDS client connecting to the Rust agent.
- **`ArmadilloTLS/CertificateManager.swift`** - Persists server certificates in the macOS Keychain so the device fingerprint `fp` remains stable across restarts.
- **`ArmadilloTLS/BLE/BLEScanner.swift`** *(in progress/planned)* - Swift-native BLE central logic for future GATT connections.

## 3. iOS Swift App (`apps/app-ios/ArmadilloMobile/`)

The user's mobile authenticator.

- **`ArmadilloMobile/ArmadilloMobileApp.swift`** & **`ContentView.swift`** - iOS App entry points and root navigation.
- **`ArmadilloMobile/Features/Pairing/`**
  - **`QRScannerView.swift`** - Scans the QR code shown by the Mac to initiate pairing.
  - **`QRPayload.swift`** - Model representing the parsed QR data.
  - **`PairingViewModel.swift`** - Triggers Face ID, orchestrates the entire protocol flow, TLS auth, and saves to UserDefaults.
  - **`PairedMacListView.swift`** - (NEW) UI for managing multiple paired Macs.
- **`ArmadilloMobile/Session/`**
  - **`SessionKeyDerivation.swift`** - ECDH + HKDF computations mirroring Rust's `wrap.rs` to derive matching `k_ble`.
  - **`PairedMacStore.swift`** - (NEW) Persistence for multiple paired Macs and defining the explicitly "Active" Mac.
  - **`SimpleClientIdentity.swift`** - Generates the CSR logic for enrollment.
  - **`CertificatePinner.swift`** & **`Pinning.swift`** - Validates the mTLS server fingerprint against the `agent_fp` captured during pairing.
- **`ArmadilloMobile/Features/Transport/`**
  - **`TLSClient.swift`** - SwiftNIO or Network framework-based client connecting to Mac's 8443 port.
  - **`FramedCodec.swift`** - Framing mechanism (4-byte length prefix).
  - **`Messages.swift`** - JSON structures for `auth.begin`, `vault.*`, `trust.granted`.
- **`ArmadilloMobile/Features/BLE/`**
  - **`BLEAdvertiser.swift`** - **IMPORTANT:** Currently implements an iBeacon advertiser using `CLBeaconRegion`. Contains the `startAdvertising()` and `rotateEveryBucket` logic that was proven to fail in iOS Background states. Planned to pivot to a GATT Peripheral service.
- **`ArmadilloMobile/Features/Discovery/BonjourBrowser.swift`** - Scans local WiFi for `_armadillo._tcp` to resolve Mac's IP/port transparently.
- **`Symbiauthwidget/`** - iOS Widget extension providing lockscreen/homescreen interactive widgets for quick flows.

## 4. Browser Extension (`packages/webext/`)

Intercepts page contexts and communicates with nmhost. 

- **`public/background.js`** / **`src/background.ts`** - Extension service worker. Relays UI fill requests to Rust.
- **`public/content.js`** / **`src/content.ts`** - Injected into pages to read DOM and execute autofill.
- **`public/popup.html`** / **`src/messaging.ts`** - The dropdown UI shown when clicking the browser extension logo.

---

## Shared Contracts & Docs

- **`packages/protocol/json/messages.schema.json`** - Schema validation for IPC data exchanged across components.
- **`docs/`** - Contains overarching design documents and pivot plans:
  - `docs/Pivot_docs/Pivot_foreground_gatt.md` - (Active Pivot) Explaining transition from background iBeacon to foreground GATT.
  - `docs/Pivot_docs/V1_state_machine.md` - Foreground GATT Trust State Machine.
  - `docs/BLE_IMPLEMENTATION.md` - Original documentation outlining the history of BLE methods tried.
  - `docs/SYSTEM_OVERVIEW.md` - High-level semantic rules.
