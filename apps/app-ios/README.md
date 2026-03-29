# Armadillo Mobile - iOS MVP

This is the minimal viable product (MVP) iOS app for testing the Armadillo pairing system.

## ⚠️ Current MVP Status

This is a **simplified MVP version** designed to test the core pairing flow. Several features are intentionally simplified and will be enhanced for production:

### What Works Now:
- ✅ QR code scanning and payload parsing
- ✅ Bonjour service discovery with fallback
- ✅ TLS connection with server certificate pinning
- ✅ ALPN protocol negotiation
- ✅ Message framing and ping/pong testing
- ✅ SAS code generation and display

### What's Simplified (MVP Limitations):
- 🔄 **Client certificates**: Currently using server-only TLS verification
- 🔄 **Mutual TLS**: Will be added with proper swift-certificates integration
- 🔄 **Secure Enclave**: Using software keys for development
- 🔄 **Certificate generation**: Placeholder implementation

## Project Setup

### 1. Xcode Project Configuration

**Important**: When creating the Xcode project, you selected:
- Testing: **None** 
- Storage: **None**

These will need to be configured later for production. For MVP testing, this is fine.

### 2. Required Permissions (Info.plist)

Add these permissions to your Info.plist:

```xml
<!-- Camera permission for QR scanning -->
<key>NSCameraUsageDescription</key>
<string>Scan QR code to pair with your Mac securely</string>

<!-- Local network permission for Bonjour discovery -->
<key>NSLocalNetworkUsageDescription</key>
<string>Discover your Mac on the local network for secure pairing</string>

<!-- Bonjour services -->
<key>NSBonjourServices</key>
<array>
    <string>_armadillo._tcp</string>
</array>

<!-- Development flag -->
<key>ARM_DEV</key>
<string>1</string>
```

### 3. Add Files to Xcode Project

You need to add all the created Swift files to your Xcode project:

1. **Right-click on your project** in Xcode navigator
2. **Add Files to "ArmadilloMobile"**
3. **Select all the Swift files** in the folder structure:
   - `Core/` folder (Env.swift, Logging.swift)
   - `Features/` folder (all subfolders and files)
   - `Session/` folder (Pinning.swift, SAS.swift, PairedAgentStore.swift)

### 4. Build Configurations

Create two build configurations:

**Debug-Dev** (for testing):
- Set `ARM_DEV = 1` in Info.plist
- Bundle ID: `com.armadillo.mobile.dev`

**Release-Prod** (for production):
- Set `ARM_DEV = 0` in Info.plist  
- Bundle ID: `com.armadillo.mobile`

## Project Structure

```
ArmadilloMobile/
├── ArmadilloMobileApp.swift    # Main app entry point
├── ContentView.swift           # Main UI
├── Core/
│   ├── Env.swift              # Environment configuration
│   └── Logging.swift          # Logging utilities
├── Features/
│   ├── Pairing/
│   │   ├── QRPayload.swift    # QR code data structure
│   │   ├── QRScannerView.swift # Camera-based QR scanner
│   │   └── PairingViewModel.swift # Main pairing logic
│   ├── Discovery/
│   │   └── BonjourBrowser.swift # mDNS service discovery
│   └── Transport/
│       ├── TLSClient.swift    # TLS client (simplified for MVP)
│       ├── FramedCodec.swift  # Message framing
│       └── Messages.swift     # Protocol messages
└── Session/
    ├── Pinning.swift         # Certificate pinning
    ├── SAS.swift             # Short Authentication String
    └── PairedAgentStore.swift # Keychain storage (simplified)
```

## Testing Flow

1. **Start Rust Agent**: Run the Rust agent on your Mac
2. **Start Mac TLS Terminator**: Run the Swift TLS terminator app
3. **Build iOS App**: Open in Xcode and build to device
4. **Scan QR**: Tap "Scan QR to Pair" and scan the QR from Mac app
5. **Verify Connection**: Should show "Connected to Mac" with SAS code
6. **Test Ping**: Tap "Ping Test" to verify end-to-end communication

## Known MVP Limitations

### Certificate Management
- Currently using simplified TLS without client certificates
- Will be enhanced with swift-certificates for proper X.509 generation
- Secure Enclave integration will be added for production

### Error Handling
- Basic error handling and UI feedback
- Will be enhanced with comprehensive error recovery

### Security
- Server certificate pinning works correctly
- Client certificate authentication will be added
- SAS derivation uses deterministic hash (will use TLS exporter in production)

## Next Steps for Production

1. **Integrate swift-certificates** for proper X.509 certificate generation
2. **Implement mutual TLS** with client certificate authentication
3. **Add Secure Enclave support** for hardware-backed keys
4. **Implement TLS exporter** for proper SAS derivation
5. **Add comprehensive error handling** and recovery
6. **Polish UI/UX** for production release
7. **Add push notifications** for credential approval requests
8. **Add testing and storage frameworks** as needed

## Troubleshooting

### Build Issues
- Make sure all Swift files are added to the Xcode project
- Check that Info.plist permissions are correctly set
- Verify bundle identifier matches your development team

### Runtime Issues
- Check camera permissions are granted
- Verify local network permissions are granted
- Ensure Mac TLS terminator is running and discoverable
- Check console logs for detailed error information

### Connection Issues
- Verify QR code contains valid JSON payload
- Check Bonjour service is published correctly
- Ensure firewall allows local network connections
- Verify certificate fingerprint matching