// STATUS: ACTIVE
// PURPOSE: owns TLS connection, BLE advertiser, and vault ops — handles all Mac↔iOS messaging
import Foundation
import SwiftUI
import Combine
import CryptoKit
import LocalAuthentication

@MainActor
class PairingViewModel: ObservableObject {
    struct LogEntry: Identifiable {
        enum Category: String, CaseIterable {
            case trust
            case connection
            case session
        }

        let id = UUID()
        let timestamp: Date
        let category: Category
        let title: String
        let detail: String
    }

    enum DataConnectionState {
        case offline
        case connecting
        case online
        case recovering
    }

    @Published var showingQRScanner = false
    @Published var isConnected = false
    @Published var statusMessage = ""
    @Published var hasError = false
    @Published var trustSessionActive = false
    @Published var lastProofSentAt: Date?
    @Published var lastTrustMode: String = "background_ttl"
    @Published private(set) var trustStateRaw: String = "locked"
    @Published private(set) var trustDeadlineMs: UInt64?
    @Published private(set) var dataConnectionState: DataConnectionState = .offline
    @Published private(set) var logEntries: [LogEntry] = []
    @Published var deviceFingerprint = ""
    @Published var sasCode = ""
    private var currentAuthCorrId: String?
    
    private let bonjourBrowser = BonjourBrowser()
    private let tlsClient = TLSClient()
    private let agentStore = PairedAgentStore()
    private let macStore = PairedMacStore()
    @Published var pairedMacs: [PairedMac] = []
    var activeMacId: String? { macStore.activeMacId() }
    var activeMacLabel: String {
        macStore.activeMac()?.label ?? "Unknown Mac"
    }
    
    private var currentPayload: QRPayload?
    private var cancellables = Set<AnyCancellable>()
    
    // Track current endpoint for persistence
    private var currentHost: String = ""
    private var currentPort: Int = 0
    private var currentAgentFingerprint: String = ""
    private var currentAgentName: String = ""
    private var lastLoggedConnectionState: DataConnectionState?
    
    @Published var autoConnectEnabled: Bool = AppSettings.shared.autoConnectEnabled
    @Published var autoConnectPausedUntil: Date?
    var hasActiveMacWithTrustKeys: Bool {
        macStore.activeMac()?.wrapPubB64?.isEmpty == false
    }

    var dataConnectionTitle: String {
        switch dataConnectionState {
        case .offline:
            return "Offline"
        case .connecting:
            return "Connecting"
        case .online:
            return "Connected"
        case .recovering:
            return "Reconnecting"
        }
    }

    var dataConnectionDetail: String {
        if statusMessage.isEmpty { return "No data connection activity." }
        return statusMessage
    }

    var dataConnectionTint: Color {
        switch dataConnectionState {
        case .online:
            return .green
        case .recovering:
            return .orange
        case .connecting:
            return .blue
        case .offline:
            return .secondary
        }
    }

    var trustSessionTitle: String {
        switch normalizedTrustVisualState() {
        case .trusted:
            return "Trusted"
        case .gracePeriod:
            return "Grace Period"
        case .syncing:
            return "Syncing"
        case .reconnecting:
            return "Reconnecting"
        case .locked:
            return "Locked"
        }
    }

    var trustSessionDetail: String {
        trustSessionDetail(at: Date())
    }

    func trustSessionDetail(at now: Date) -> String {
        switch normalizedTrustVisualState() {
        case .trusted:
            if dataConnectionState == .recovering || dataConnectionState == .offline {
                return "BLE proofs are holding the session while the data link recovers."
            }
            return "Phone proofs accepted by Mac."
        case .gracePeriod:
            if let remaining = graceRemainingText(now: now) {
                return "Signal lost. Revoking in \(remaining)."
            }
            return "Signal lost. Grace window active."
        case .syncing:
            return "Session started. Waiting for the Mac to confirm trust."
        case .reconnecting:
            return "Session started. Waiting for proof sync."
        case .locked:
            if trustSessionActive {
                return "Session started. Waiting for first proof."
            }
            return "Start Session to enable BLE trust proofs."
        }
    }

    var trustSessionTint: Color {
        switch normalizedTrustVisualState() {
        case .trusted:
            return .green
        case .gracePeriod:
            return .orange
        case .syncing:
            return .blue
        case .reconnecting:
            return .blue
        case .locked:
            return .secondary
        }
    }

    var trustSessionSymbol: String {
        switch normalizedTrustVisualState() {
        case .trusted:
            return "checkmark.shield.fill"
        case .gracePeriod:
            return "hourglass"
        case .syncing:
            return "dot.radiowaves.left.and.right"
        case .reconnecting:
            return "arrow.triangle.2.circlepath"
        case .locked:
            return "lock.shield"
        }
    }
    
    // Prevent Bonjour multiple-connect race condition
    private var scanNonce = UUID()
    private var connectAttemptedForNonce: UUID? = nil
    
    @Published var devMode: Bool = false
    @Published var showRecoveryPhraseAlert: Bool = false
    @Published var recoveryPhraseAlertText: String = ""
    
    // Keep strong references to prevent cancellation
    private var enrollSession: URLSession?
    private var pendingTask: URLSessionTask?
    private var discoveryTimer: Timer?
    private var vaultStatusTimer: Timer?
    private var periodicBonjourTimer: Timer?
    private var heartbeatTimer: Timer?
    private var bleTrustServer: BLETrustServer?
    private var rekeyTimer: Timer?
    @Published var rekeySecondsLeft: Int = 0
    private var rekeyDeadline: Date?
    
    // Auto-connect retry control
    private var autoConnectInProgress: Bool = false
    private var autoConnectRetries: Int = 0
    private let maxAutoConnectRetries: Int = 3
    private let backoffSchedule: [TimeInterval] = [0.5, 1.0, 2.0, 4.0]
    private var suppressAutoConnect: Bool = false

    private enum TrustVisualState {
        case trusted
        case gracePeriod
        case syncing
        case reconnecting
        case locked
    }

    var trustedSessionLinkTitle: String {
        if !trustSessionActive {
            return "BLE OFF"
        }
        switch normalizedTrustVisualState() {
        case .trusted, .gracePeriod:
            return "BLE ACTIVE"
        case .syncing:
            return lastProofSentAt == nil ? "BLE SYNCING" : "BLE ACTIVE"
        case .reconnecting:
            return "BLE ACTIVE"
        case .locked:
            return "BLE OFF"
        }
    }

    var trustedSessionLinkDetail: String {
        if !trustSessionActive {
            return "No active foreground trust session."
        }
        guard let sentAt = lastProofSentAt else {
            return "Preparing first proof for the Mac."
        }
        let delta = max(0, Int(Date().timeIntervalSince(sentAt)))
        return "Last proof \(delta)s ago."
    }

    var trustedSessionLinkTint: Color {
        if !trustSessionActive {
            return .secondary
        }
        switch normalizedTrustVisualState() {
        case .trusted, .gracePeriod:
            return .green
        case .syncing, .reconnecting:
            return .blue
        case .locked:
            return .secondary
        }
    }

    var trustedSessionDataLinkTitle: String {
        switch dataConnectionState {
        case .online:
            return "ONLINE"
        case .connecting:
            return "CONNECTING"
        case .recovering:
            return "RECOVERING"
        case .offline:
            return trustSessionActive ? "OFFLINE" : "OFFLINE"
        }
    }

    var trustedSessionDataLinkDetail: String {
        switch dataConnectionState {
        case .online:
            return "Secure data link is active."
        case .connecting:
            return "Establishing secure data link."
        case .recovering:
            if normalizedTrustVisualState() == .trusted || normalizedTrustVisualState() == .gracePeriod {
                return "BLE proofs are keeping trust alive while data reconnects."
            }
            return "Attempting to reconnect secure data link."
        case .offline:
            if normalizedTrustVisualState() == .trusted || normalizedTrustVisualState() == .gracePeriod {
                return "Data link is down, but BLE trust is still active."
            }
            return "No active secure data link."
        }
    }
    
    init() {
        // Observe TLS client state changes
        tlsClient.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleTLSStateChange(state)
            }
            .store(in: &cancellables)
        
        // Observe auth.request from agent
        tlsClient.$pendingAuthRequest
            .compactMap { $0 }  // Filter out nil
            .receive(on: DispatchQueue.main)
            .sink { [weak self] authRequest in
                self?.handleAuthRequest(corrId: authRequest.corrId)
            }
            .store(in: &cancellables)
        
        // Load persisted paired macs list
        pairedMacs = macStore.loadAll()
        // Load Dev Mode
        self.devMode = UserDefaults.standard.object(forKey: "dev_mode") as? Bool ?? false
        attemptAutoConnectIfPossible()

        // Widget intent: FaceID succeeded → send intent.ok to Mac
        NotificationCenter.default
            .publisher(for: AuthorizeCoordinator.didReceiveIntent)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendIntentOKTask() }
            .store(in: &cancellables)

        // Background energy: slow heartbeat to 60s when backgrounded, 10s in foreground
        NotificationCenter.default
            .publisher(for: .heartbeatIntervalChanged)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.userInfo?["interval"] as? TimeInterval }
            .sink { [weak self] interval in self?.setHeartbeatInterval(interval) }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .trustSessionShouldStop)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.endTrustSession(reason: "background")
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .trustEventReceived)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleTrustEvent(notification.userInfo)
            }
            .store(in: &cancellables)
    }
    
    func startQRScanning() {
        // Suppress auto-connect while scanning to keep camera open
        suppressAutoConnect = true
        autoConnectInProgress = false
        // Stop timers and disconnect to avoid immediate reconnects
        discoveryTimer?.invalidate(); discoveryTimer = nil
        periodicBonjourTimer?.invalidate(); periodicBonjourTimer = nil
        vaultStatusTimer?.invalidate(); vaultStatusTimer = nil
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        tlsClient.disconnect()
        showingQRScanner = true
        updateStatus("Ready to scan QR code", isError: false)
    }
    
    func handleQRPayload(_ payload: QRPayload) {
        currentPayload = payload
        showingQRScanner = false
        suppressAutoConnect = false
        updateStatus("QR scanned successfully. Discovering service...", isError: false)
        
        // Upsert Mac record immediately at scan time (wrapPubB64 filled later on ack)
        let mac = PairedMac(
            macId: payload.agent_fp,
            label: payload.name,
            fpSuffix: String(payload.agent_fp.suffix(12)),
            wrapPubB64: nil,
            pairedAt: Date()
        )
        macStore.save(mac)
        macStore.setActiveMacId(payload.agent_fp)
        pairedMacs = macStore.loadAll()
        
        discoverService(payload)
    }
    
    func sendPing() {
        guard isConnected else {
            updateStatus("Not connected", isError: true)
            return
        }
        
        updateStatus("Sending ping...", isError: false)
        
        Task {
            do {
                try await tlsClient.testConnection()
                updateStatus("Ping successful! ✅", isError: false)
            } catch {
                updateStatus("Ping failed: \(error.localizedDescription)", isError: true)
            }
        }
    }
    
    func disconnect() {
        tlsClient.disconnect()
        endTrustSession(reason: "disconnect")
        // Pause auto-connect for 60 seconds when user explicitly disconnects
        autoConnectPausedUntil = Date().addingTimeInterval(60)
        
        isConnected = false
        dataConnectionState = .offline
        deviceFingerprint = ""
        sasCode = ""
        currentPayload = nil
        
        // Clean up timers and sessions
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        pendingTask?.cancel()
        enrollSession?.invalidateAndCancel()
        pendingTask = nil
        enrollSession = nil
        
        updateStatus("Disconnected", isError: false)
    }
    
    private func discoverService(_ payload: QRPayload) {
        // Reset the nonce for a new discovery session
        scanNonce = UUID()
        connectAttemptedForNonce = nil
        let nonce = scanNonce
        
        // Add discovery timeout (2-3s)
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if let fallback = payload.fallbackEndpoint {
                    self.connectOnce(
                        host: fallback.host, port: Int(fallback.port), payload: payload,
                        reason: "Bonjour timeout, using QR endpoint...", nonce: nonce
                    )
                }
            }
        }
        
        bonjourBrowser.discover(serviceName: payload.svc) { [weak self] result in
            DispatchQueue.main.async {
                // Cancel discovery timer since we got a result
                self?.discoveryTimer?.invalidate()
                
                switch result {
                case .success(let endpoint):
                    self?.connectOnce(
                        host: endpoint.host, port: Int(endpoint.port), payload: payload,
                        reason: "Service discovered. Connecting...", nonce: nonce
                    )
                    
                case .failure(let error):
                    // Only fallback if discovery truly failed (timeout or browserFailed),
                    // not if we already saw a .ready / found service event.
                    if case .browserFailed = error {
                        if let fallback = payload.fallbackEndpoint {
                            self?.connectOnce(
                                host: fallback.host, port: Int(fallback.port), payload: payload,
                                reason: "Bonjour failed, trying fallback...", nonce: nonce
                            )
                        } else {
                            self?.updateStatus("Discovery failed: \(error.localizedDescription)", isError: true)
                        }
                    } else {
                        // resolutionFailed etc. — don't spam fallback if you still have QR host anyway;
                        // prefer using the QR host for ENROLL directly.
                        if let fallback = payload.fallbackEndpoint {
                            self?.connectOnce(
                                host: fallback.host, port: Int(fallback.port), payload: payload,
                                reason: "Using QR endpoint...", nonce: nonce
                            )
                        } else {
                            self?.updateStatus("Discovery failed: \(error.localizedDescription)", isError: true)
                        }
                    }
                }
            }
        }
    }
    
    private func connectOnce(host: String, port: Int, payload: QRPayload, reason: String, nonce: UUID) {
        guard nonce == scanNonce else { return }                 // stale callback
        guard connectAttemptedForNonce == nil else { return }    // already connecting for this scan
        connectAttemptedForNonce = nonce
        updateStatus(reason, isError: false)
        connectToAgent(host: host, port: port, payload: payload)
    }
    
    private func connectToAgent(host: String, port: Int, payload: QRPayload) {
        // Cancel any existing task before starting a new one
        pendingTask?.cancel()
        enrollSession?.invalidateAndCancel()
        pendingTask = nil
        enrollSession = nil
        
        // Track endpoint details for persistence
        currentHost = host
        currentPort = port
        currentAgentFingerprint = payload.agent_fp
        currentAgentName = payload.name
        
        Task {
            do {
                // Step 1: Check if we have a client identity, if not, enroll first
                let clientIdentity: SecIdentity
                do {
                    clientIdentity = try SimpleClientIdentity.getOrCreate(
                        host: host,
                        expectedFingerprint: payload.agent_fp
                    )
                    updateStatus("Using existing client identity", isError: false)
                } catch SimpleClientIdentityError.identityNotFound {
                    // Need to enroll first
                    updateStatus("No client identity found. Enrolling...", isError: false)
                    clientIdentity = try await enrollWithServer(host: host, payload: payload)
                    updateStatus("Enrollment successful! Connecting...", isError: false)
                } catch {
                    throw error
                }
                
                // Step 2: Compute client fingerprint from the actual client identity (no mocks)
                    deviceFingerprint = try generateFingerprintFromIdentity(clientIdentity)
                ArmadilloLogger.pairing.info("Client fingerprint derived from identity")
                
                // Step 3: Connect with mutual TLS to the main port (8443)
                tlsClient.connect(
                    host: host,
                    port: UInt16(port), // This should be 8443 (main mTLS port)
                    serverFingerprint: payload.agent_fp,
                    clientIdentity: clientIdentity
                )
                
            } catch {
                updateStatus("Failed to prepare connection: \(error.localizedDescription)", isError: true)
            }
        }
    }
    
    private func enrollWithServer(host: String, payload: QRPayload) async throws -> SecIdentity {
        // Generate new client identity via CSR enrollment with fingerprint pinning
        return try SimpleClientIdentity.getOrCreate(host: host, expectedFingerprint: payload.agent_fp) // *
    }
    
    private func generateFingerprintFromIdentity(_ identity: SecIdentity) throws -> String {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let cert = certificate else {
            throw SimpleClientIdentityError.certificateCreationFailed
        }
        
        let certData = SecCertificateCopyData(cert)
        let digest = SHA256.hash(data: certData as Data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
    
    
    
    private func handleTLSStateChange(_ state: TLSClient.ConnectionState) {
        switch state {
        case .idle:
            dataConnectionState = .offline
            appendLog(category: .connection, title: "Connection Ready", detail: "TLS transport is idle and ready to connect.")
            updateStatus("Ready", isError: false)
            
        case .connecting:
            dataConnectionState = .connecting
            appendLog(category: .connection, title: "Connecting", detail: "Establishing secure connection to the active Mac.")
            updateStatus("Establishing secure connection...", isError: false)
            
        case .ready:
            dataConnectionState = .online
            appendLog(category: .connection, title: "Connection Restored", detail: "Secure data link is active.")
            if currentPayload != nil {
                updateStatus("Connected! Completing pairing...", isError: false)
            } else {
                updateStatus("Connected to agent", isError: false)
            }
            // Stop any background discovery when connected
            periodicBonjourTimer?.invalidate()
            periodicBonjourTimer = nil
            // Start periodic vault.status telemetry
            vaultStatusTimer?.invalidate()
            vaultStatusTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { [weak self] in
                    guard let self = self else { return }
                    do {
                        try await self.tlsClient.send(["type":"vault.status"])
                        _ = try? await self.tlsClient.waitForMessage(type: "vault.ack", timeout: 2.0)
                    } catch { /* ignore */ }
                }
            }

            completePairing()
            // Start BLE advertiser if enabled
            startBleAdvertisingIfEnabled()
            
        case .failed(let error):
            ArmadilloLogger.transport.error("TLS connection failed: \(error.localizedDescription)")
            
            // If we have a known endpoint, enter reconnect mode even if not previously in it
            if !autoConnectInProgress && !currentHost.isEmpty {
                autoConnectInProgress = true
                autoConnectRetries = 0
            }
            
            if autoConnectInProgress {
                dataConnectionState = .recovering
                appendLog(category: .connection, title: "Connection Recovering", detail: "Data link dropped. Attempting reconnect.")
                let msg = error.localizedDescription.lowercased()
                let shouldRetry = msg.contains("connection refused") || msg.contains("timed out") || msg.contains("timeout")
                if shouldRetry {
                    scheduleBackoffReconnect()
                    return
                } else {
                    attemptBonjourRefreshAndReconnect()
                    return
                }
            }
            
            updateStatus("Connection failed: \(error.localizedDescription)", isError: true)
            appendLog(category: .connection, title: "Connection Failed", detail: error.localizedDescription)
            isConnected = false
            dataConnectionState = .offline
            
        case .cancelled:
            ArmadilloLogger.transport.info("TLS connection cancelled")
            updateStatus("Connection closed", isError: false)
            appendLog(category: .connection, title: "Connection Closed", detail: "Secure link to the Mac closed.")
            isConnected = false
            dataConnectionState = .offline
            vaultStatusTimer?.invalidate()
            vaultStatusTimer = nil
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            
            // If we have a known endpoint, attempt silent reconnect
            if !autoConnectInProgress && !currentHost.isEmpty && !suppressAutoConnect {
                autoConnectInProgress = true
                autoConnectRetries = 0
                dataConnectionState = .recovering
                scheduleBackoffReconnect()
                return
            }
            // Ensure periodic discovery stops when fully cancelled without reconnect intent
            if !autoConnectInProgress {
                periodicBonjourTimer?.invalidate()
                periodicBonjourTimer = nil
            }
        }
    }
    
    private func completePairing() {
        guard let payload = currentPayload else {
            // Auto-connect path (no QR payload present)
            Task {
                do {
                    isConnected = true
                    updateStatus("Connected! Testing connection...", isError: false)
                    
                    // Test the connection with a ping
                    try await tlsClient.testConnection()
                    
                    // Persist the endpoint on success (update port if changed)
                    agentStore.saveLastAgentEndpoint(
                        host: currentHost,
                        port: UInt16(currentPort),
                        fingerprint: currentAgentFingerprint,
                        name: currentAgentName
                    )
                    
                    // End auto-connect flow
                    autoConnectInProgress = false
                    updateStatus("Connection test successful! ✅", isError: false)
                } catch {
                    autoConnectInProgress = false
                    updateStatus("Pairing failed: \(error.localizedDescription)", isError: true)
                }
            }
            return
        }
        
        Task {
            do {
                // Generate SAS code
                let generatedSAS = SAS.derive(from: tlsClient, sessionId: payload.sid)
                sasCode = SAS.format(generatedSAS)
                
                // Send PairingComplete to agent over mTLS
                let msg: [String: Any] = [
                    "type": "pairing.complete",
                    "sid": payload.sid,
                    "device_fp": deviceFingerprint,
                    "agent_fp": payload.agent_fp,
                    "sas": sasCode,
                    // Provide iOS wrap public key (SEC1 uncompressed) for stable wrap derivation
                    "wrap_pub_ios_b64": (try? WrapKeyManager.publicKeyBase64(x963: true)) ?? ""
                ]
                try await tlsClient.send(msg)
                // Wait up to 3s for ack; capture mac wrap pub for ECDH
                do {
                    if let ack = try await tlsClient.waitForMessage(type: "pairing.ack", timeout: 3.0) as? SimpleMessage,
                       let wrapMac = ack.data["wrap_pub_mac_b64"] as? String {
                        // Race-safe: bind wrap key to THIS mac's fingerprint, not activeMac()
                        let boundMacId = self.currentAgentFingerprint
                        self.macStore.setWrapPub(wrapMac, forMacId: boundMacId)
                        self.pairedMacs = self.macStore.loadAll()
                        // Clear payload so we don't re-pair on reconnect
                        self.currentPayload = nil
                        // Start BLE using the active mac's (now complete) wrap pub
                        self.startBleAdvertisingIfEnabled()
                    }
                    self.updateStatus("Paired successfully", isError: false)
                } catch {
                    self.updateStatus("Paired (no ack received)", isError: false)
                }

                // Store paired agent info (skip keychain for MVP)
                do {
                    try agentStore.storePairedAgent(
                        fingerprint: payload.agent_fp,
                        name: payload.name,
                        sessionId: payload.sid
                    )
                } catch {
                    ArmadilloLogger.pairing.warning("Keychain storage failed (MVP mode): \(error.localizedDescription)")
                }
                
                isConnected = true
                updateStatus("Connected! Testing connection...", isError: false)
                
                // Test the connection with a ping
                try await tlsClient.testConnection()
                
                // Persist the endpoint on success
                agentStore.saveLastAgentEndpoint(
                    host: currentHost,
                    port: UInt16(currentPort),
                    fingerprint: currentAgentFingerprint,
                    name: currentAgentName
                )
                
                // Stop all discovery/reconnect timers since we're successfully connected
                discoveryTimer?.invalidate()
                discoveryTimer = nil
                periodicBonjourTimer?.invalidate()
                periodicBonjourTimer = nil
                autoConnectInProgress = false
                
                // Now that pairing is complete, start heartbeat monitoring
                startHeartbeatTimer()
                
                updateStatus("Connection test successful! ✅", isError: false)
                
            } catch {
                updateStatus("Pairing failed: \(error.localizedDescription)", isError: true)
            }
        }
    }
    
    func startTrustSession() {
        guard macStore.activeMac()?.wrapPubB64?.isEmpty == false else {
            updateStatus("No paired Mac with valid keys", isError: true)
            return
        }
        guard AppSettings.shared.blePresence else {
            updateStatus("BLE trust is disabled in Settings", isError: true)
            return
        }
        Task { @MainActor in
            do {
                try await promptFaceIDForTrustSession()
                trustSessionActive = true
                lastProofSentAt = nil
                appendLog(category: .session, title: "Session Started", detail: "Foreground trust session started for \(activeMacLabel).")
                startBleAdvertisingIfEnabled()
                refreshTrustStatusFromMac()
                updateStatus("Trust session active (foreground only)", isError: false)
            } catch {
                updateStatus("Face ID failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func endTrustSession(reason: String = "user_end") {
        let hadActiveSession = trustSessionActive || (bleTrustServer != nil)
        trustSessionActive = false
        guard hadActiveSession else {
            print("[ios] ble.vm stop ignored reason=\(reason) already_inactive=true")
            return
        }
        appendLog(category: .session, title: "Session Ended", detail: sessionEndDetail(reason: reason))
        // Background behavior by policy:
        // - strict: immediate revoke
        // - background_ttl / office: immediate signal_lost (start ttl/idle now)
        // Explicit user/device-stop reasons still revoke immediately.
        if reason == "background" {
            if lastTrustMode == "strict" {
                sendTrustRevoke(reason: reason)
            } else {
                sendTrustSignalLost(reason: reason)
            }
        } else if reason != "mac_revoked" {
            sendTrustRevoke(reason: reason)
        }
        stopBleAdvertising(reason: reason)
    }

    private func sendTrustRevoke(reason: String) {
        guard isConnected else {
            print("[ios] trust.revoke skip: tls_disconnected reason=\(reason)")
            return
        }
        let corr = UUID().uuidString.prefix(8)
        let msg: [String: Any] = [
            "type": "trust.revoke",
            "v": 1,
            "corr_id": String(corr),
            "reason": reason
        ]
        Task {
            do {
                try await tlsClient.send(msg)
                print("[ios] trust.revoke sent corr=\(corr) reason=\(reason)")
            } catch {
                print("[ios] trust.revoke send failed corr=\(corr) reason=\(reason) err=\(error.localizedDescription)")
            }
        }
    }

    private func sendTrustSignalLost(reason: String) {
        guard isConnected else {
            print("[ios] trust.signal_lost skip: tls_disconnected reason=\(reason)")
            return
        }
        let corr = "sl_" + UUID().uuidString.prefix(8)
        let msg: [String: Any] = [
            "type": "trust.signal_lost",
            "v": 1,
            "corr_id": String(corr),
            "reason": reason
        ]
        Task {
            do {
                try await tlsClient.send(msg)
                print("[ios] trust.signal_lost sent corr=\(corr) reason=\(reason)")
            } catch {
                print("[ios] trust.signal_lost send failed corr=\(corr) reason=\(reason) err=\(error.localizedDescription)")
            }
        }
    }

    private func handleTrustEvent(_ userInfo: [AnyHashable: Any]?) {
        guard let event = userInfo?["trust_event"] as? String else { return }
        let trustId = (userInfo?["trust_id"] as? String) ?? ""
        let reason = userInfo?["reason"] as? String
        if let mode = userInfo?["mode"] as? String, !mode.isEmpty {
            lastTrustMode = mode
        }
        switch event {
        case "granted", "signal_present":
            trustStateRaw = "trusted"
        case "signal_lost", "deadline_started":
            trustStateRaw = "degraded"
        case "revoked":
            trustStateRaw = "locked"
            trustDeadlineMs = nil
        default:
            break
        }
        print("[ios] trust.event.recv event=\(event) trust_id=\(trustId.isEmpty ? "<none>" : trustId)")
        appendTrustLog(event: event, reason: reason)
        refreshTrustStatusFromMac()

        // Mac is the source of truth for trust lifetime. On revoke, force-close local BLE session/UI.
        if event == "revoked" {
            endTrustSession(reason: "mac_revoked")
            updateStatus("Session ended on Mac", isError: false)
        }
    }

    func refreshTrustStatusFromMac() {
        guard isConnected else { return }
        Task { [weak self] in
            guard let self else { return }
            let corr = String(UUID().uuidString.prefix(8))
            let req: [String: Any] = [
                "type": "trust.status",
                "corr_id": corr
            ]
            do {
                try await tlsClient.send(req)
                let response = try await tlsClient.waitForMessage(type: "trust.status_response", timeout: 2.0)
                guard let msg = response as? SimpleMessage else { return }
                await MainActor.run {
                    let state = (msg.data["state"] as? String ?? "").lowercased()
                    if !state.isEmpty {
                        self.trustStateRaw = state
                    }
                    self.trustDeadlineMs = self.parseUInt64(msg.data["deadline_ms"])
                    let mode = (msg.data["mode"] as? String ?? "").lowercased()
                    if !mode.isEmpty {
                        self.lastTrustMode = mode
                    }
                }
            } catch {
                print("[ios] trust.status refresh failed err=\(error.localizedDescription)")
            }
        }
    }

    private func promptFaceIDForTrustSession() async throws {
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            throw authError ?? NSError(domain: "SymbiAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Biometric auth unavailable"])
        }
        _ = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Start SymbiAuth trust session"
        )
    }

    private func startBleAdvertisingIfEnabled() {
        guard AppSettings.shared.blePresence else {
            print("[ios] ble.vm skip: feature disabled")
            return
        }
        guard trustSessionActive else {
            print("[ios] ble.vm skip: trust session inactive")
            return
        }
        guard let activeMac = macStore.activeMac() else {
            print("[ios] ble.vm skip: no active mac")
            return
        }
        guard let wrapPubB64 = activeMac.wrapPubB64 else {
            print("[ios] ble.vm skip: active mac \(activeMac.macId.suffix(12)) has no wrapPubB64 yet")
            return
        }
        // Require device fingerprint
        var deviceFp = self.deviceFingerprint
        if deviceFp.isEmpty {
            if let identity = try? SimpleClientIdentity.loadExistingIdentity(),
               let fp = try? generateFingerprintFromIdentity(identity) {
                self.deviceFingerprint = fp
                deviceFp = fp
                print("[ios] ble.vm populated device fingerprint from identity")
            }
        }
        guard !deviceFp.isEmpty else {
            print("[ios] ble.vm skip: missing device fingerprint")
            return
        }
        // Log mac wrap pub sanity
        if let raw = Data(base64Encoded: wrapPubB64) {
            let first = raw.first ?? 0xff
            print("[ios] ble.vm macWrapPub len=\(raw.count) first=0x\(String(format: "%02x", first)) macId=...\(activeMac.macId.suffix(12))")
        } else {
            print("[ios] ble.vm macWrapPub invalid base64")
        }
        guard let kBle = try? SessionKeyDerivation.deriveBleKey(macWrapPubSec1Base64: wrapPubB64, deviceFingerprint: deviceFp) else {
            print("[ios] ble.vm error: deriveBleKey failed")
            return
        }
        bleTrustServer?.stop(reason: "restart")
        bleTrustServer = BLETrustServer(kBle: kBle, phoneFp: deviceFp, onProofSent: { [weak self] sentAt in
            self?.lastProofSentAt = sentAt
        })
        bleTrustServer?.start()
        print("[ios] ble.vm started trust server macId=...\(activeMac.macId.suffix(12))")
    }
    
    private func stopBleAdvertising(reason: String) {
        guard let server = bleTrustServer else {
            print("[ios] ble.vm stop noop reason=\(reason) server=nil")
            return
        }
        server.stop(reason: reason)
        bleTrustServer = nil
        print("[ios] ble.vm stopped trust server reason=\(reason)")
    }

    func lastProofText(at now: Date = Date()) -> String {
        guard let sentAt = lastProofSentAt else { return "Never" }
        let delta = max(0, Int(now.timeIntervalSince(sentAt)))
        return "\(delta)s ago"
    }

    private func normalizedTrustVisualState() -> TrustVisualState {
        let raw = trustStateRaw.lowercased()
        if raw == "trusted" {
            return .trusted
        }
        if raw == "degraded" || raw == "revoking" {
            return .gracePeriod
        }
        if trustSessionActive {
            return .syncing
        }
        return .locked
    }

    private func graceRemainingText(now: Date = Date()) -> String? {
        guard let deadlineMs = trustDeadlineMs else { return nil }
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000.0)
        if deadlineMs <= nowMs {
            return "0:00"
        }
        let totalSecs = Int((deadlineMs - nowMs) / 1000)
        return String(format: "%d:%02d", totalSecs / 60, totalSecs % 60)
    }

    private func parseUInt64(_ value: Any?) -> UInt64? {
        if let v = value as? UInt64 { return v }
        if let v = value as? Int, v >= 0 { return UInt64(v) }
        if let v = value as? NSNumber {
            let n = v.int64Value
            return n >= 0 ? UInt64(n) : nil
        }
        return nil
    }
    
    // MARK: - Public Mac management (for UI)
    
    /// Switch active Mac explicitly. Restarts BLE so new token is derived immediately.
    func setActiveMac(_ macId: String) {
        macStore.setActiveMacId(macId)
        pairedMacs = macStore.loadAll()
        startBleAdvertisingIfEnabled()  // idempotent: stops old, starts new
        
        // If auto-connect is enabled, we are not paused, and not already connected/connecting -> connect now
        startAutoConnectIfEnabled()
    }
    
    /// Remove a paired Mac. If it was active, BLE stops.
    func removeMac(_ macId: String) {
        let wasActive = macStore.activeMacId() == macId
        macStore.remove(macId: macId)
        pairedMacs = macStore.loadAll()
        if wasActive {
            endTrustSession(reason: "active_mac_removed")
            print("[ios] ble.vm active mac removed — BLE stopped, user must select a new active mac")
        }
    }

    /// Rename a paired Mac label to help users distinguish multiple devices.
    func renameMac(_ macId: String, label: String) {
        macStore.rename(macId: macId, label: label)
        pairedMacs = macStore.loadAll()
    }
    
    func setBlePresence(_ enabled: Bool) {
        AppSettings.shared.blePresence = enabled
        if enabled {
            print("[ios] ble.vm toggle: ON")
            if trustSessionActive {
                startBleAdvertisingIfEnabled()
            }
        } else {
            print("[ios] ble.vm toggle: OFF")
            endTrustSession(reason: "feature_disabled")
        }
    }
    
    private func updateStatus(_ message: String, isError: Bool) {
        statusMessage = message
        hasError = isError
        
        if isError {
            ArmadilloLogger.pairing.error("\(message)")
        } else {
            ArmadilloLogger.pairing.info("\(message)")
        }
    }

    private func appendTrustLog(event: String, reason: String?) {
        switch event {
        case "granted":
            appendLog(category: .trust, title: "Trust Granted", detail: "Proof accepted for \(activeMacLabel).")
        case "signal_present":
            appendLog(category: .trust, title: "Phone Detected", detail: "Nearby presence was detected by the Mac.")
        case "signal_lost":
            appendLog(category: .trust, title: "Signal Lost", detail: "Nearby presence was lost.")
        case "deadline_started":
            appendLog(category: .trust, title: "Grace Period Started", detail: "Trust remains active temporarily after signal loss.")
        case "revoked":
            appendLog(category: .trust, title: "Trust Revoked", detail: trustRevokedDetail(reason: reason))
        default:
            break
        }
    }

    private func trustRevokedDetail(reason: String?) -> String {
        switch reason {
        case "user_end":
            return "Trust was revoked after you ended the session."
        case "background":
            return "Trust was revoked because the app moved to the background."
        case "proof_timeout":
            return "Trust was revoked after proof refresh timed out."
        case "mac_revoked":
            return "Trust was revoked by the Mac."
        case let value?:
            return "Trust was revoked: \(value)."
        default:
            return "Trust was revoked."
        }
    }

    private func sessionEndDetail(reason: String) -> String {
        switch reason {
        case "user_end":
            return "You manually ended the foreground trust session."
        case "background":
            return "The app moved to the background."
        case "disconnect":
            return "The secure data connection was disconnected."
        case "mac_revoked":
            return "The Mac ended the trust session."
        case "active_mac_removed":
            return "The active Mac was removed."
        case "feature_disabled":
            return "BLE trust was disabled in Settings."
        default:
            return "The trust session ended."
        }
    }

    private func appendLog(category: LogEntry.Category, title: String, detail: String) {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = logEntries.first,
           last.title == title,
           last.detail == trimmedDetail,
           Date().timeIntervalSince(last.timestamp) < 1.0 {
            return
        }

        logEntries.insert(
            LogEntry(timestamp: Date(), category: category, title: title, detail: trimmedDetail),
            at: 0
        )
        if logEntries.count > 200 {
            logEntries.removeLast(logEntries.count - 200)
        }
    }
    
    // Attempt auto-connect using last saved endpoint
    private func attemptAutoConnectIfPossible() {
        guard autoConnectEnabled else { return }
        if let pausedUntil = autoConnectPausedUntil, Date() < pausedUntil { return }
        guard let last = agentStore.loadLastAgentEndpoint() else {
            ArmadilloLogger.transport.info("No cached endpoint; staying in QR flow")
            return
        }
        ArmadilloLogger.transport.info("Found cached endpoint: \(last.host):\(last.port), name=\(last.name) fp=\(last.fingerprint) — attempting auto-connect")
        
        // Track as current endpoint
        currentHost = last.host
        currentPort = Int(last.port)
        currentAgentFingerprint = last.fingerprint
        currentAgentName = last.name
        autoConnectInProgress = true
        autoConnectRetries = 0
        
        Task {
            // Load identity; if missing, fall back to QR
            guard let identity = try? SimpleClientIdentity.loadExistingIdentity() else {
                ArmadilloLogger.transport.warning("No existing client identity found; fallback to QR")
                autoConnectInProgress = false
                return
            }
            updateStatus("Reconnecting…", isError: false)
            tlsClient.connect(
                host: last.host,
                port: last.port,
                serverFingerprint: last.fingerprint,
                clientIdentity: identity
            )
        }
    }

    func resumeAutoConnectTapped() {
        autoConnectPausedUntil = nil
        startAutoConnectIfEnabled()
    }
    
    private func startAutoConnectIfEnabled() {
        guard autoConnectEnabled else { return }
        if let pausedUntil = autoConnectPausedUntil, Date() < pausedUntil {
            print("[ios] startAutoConnectIfEnabled skipped: user paused until \(pausedUntil)")
            return
        }
        guard !isConnected else { return }
        if case .connecting = tlsClient.state { return }
        
        // Connect to the ACTIVE mac, not just any last endpoint
        guard let active = macStore.activeMac() else { return }
        
        if let endpoint = agentStore.loadLastAgentEndpoint() {
            ArmadilloLogger.transport.info("Found cached endpoint for active mac, attempting auto-connect to \(endpoint.host):\(endpoint.port)")
            currentHost = endpoint.host
            currentPort = Int(endpoint.port)
            currentAgentFingerprint = endpoint.fingerprint
            currentAgentName = endpoint.name
            
            autoConnectInProgress = true
            autoConnectRetries = 0
            scheduleBackoffReconnect()
        }
    }
    
    private func scheduleBackoffReconnect() {
        guard autoConnectEnabled else {
            autoConnectInProgress = false
            return
        }
        if let pausedUntil = autoConnectPausedUntil, Date() < pausedUntil {
            autoConnectInProgress = false
            return
        }
        
        let delay = autoConnectRetries < backoffSchedule.count ? backoffSchedule[autoConnectRetries] : backoffSchedule.last!
        dataConnectionState = .recovering
        updateStatus("Reconnecting in \(delay)s...", isError: false)
        ArmadilloLogger.transport.info("Scheduling reconnect in \(delay)s (attempt \(self.autoConnectRetries + 1))")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.autoConnectEnabled else {
                    self.autoConnectInProgress = false
                    return
                }
                if let pausedUntil = self.autoConnectPausedUntil, Date() < pausedUntil {
                    self.autoConnectInProgress = false
                    return
                }
                if self.autoConnectRetries >= self.maxAutoConnectRetries {
                    self.attemptBonjourRefreshAndReconnect()
                    return
                }
                self.autoConnectRetries += 1 // Increment AFTER checking max retries
                guard let identity = try? SimpleClientIdentity.loadExistingIdentity() else {
                    self.autoConnectInProgress = false
                    self.updateStatus("Identity missing; fallback to QR", isError: true)
                    return
                }
                self.tlsClient.connect(
                    host: self.currentHost,
                    port: UInt16(self.currentPort),
                    serverFingerprint: self.currentAgentFingerprint,
                    clientIdentity: identity
                )
            }
        }
    }
    
    private func shouldRetryAutoConnect(for error: Error) -> Bool {
        // Heuristic: retry on connection refused or timeout-like errors
        let msg = error.localizedDescription.lowercased()
        if autoConnectRetries >= maxAutoConnectRetries { return false }
        if msg.contains("connection refused") || msg.contains("timed out") || msg.contains("timeout") || msg.contains("reset by peer") {
            return true
        }
        return false
    }
    
    private func attemptBonjourRefreshAndReconnect() {
        guard autoConnectEnabled else { return }
        if let pausedUntil = autoConnectPausedUntil, Date() < pausedUntil { return }
        autoConnectRetries += 1
        let attempt = autoConnectRetries
        ArmadilloLogger.transport.info("Auto-connect retry #\(attempt): multi-discover and reconnect by fingerprint")
        
        // Discover all candidates for a short window
        bonjourBrowser.discoverAll(timeout: 2.0) { [weak self] candidates in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if candidates.isEmpty {
                    // Do not auto-open QR. Keep retrying Bonjour in background.
                    self.dataConnectionState = .recovering
                    self.updateStatus("No agent nearby (data connection only)", isError: false)
                    self.startPeriodicBonjourIfNeeded()
                    return
                }
                // Prefer IPv4 candidates first
                let sorted = candidates.sorted { (a, b) in
                    let aIsIPv4 = !a.host.contains(":")
                    let bIsIPv4 = !b.host.contains(":")
                    return aIsIPv4 && !bIsIPv4
                }
                self.tryCandidatesSerially(sorted, maxAttempts: 3)
            }
        }
    }
    
    private func tryCandidatesSerially(_ candidates: [(host: String, port: UInt16, name: String)], maxAttempts: Int) {
        guard autoConnectEnabled else { return }
        if let pausedUntil = autoConnectPausedUntil, Date() < pausedUntil { return }
        var remaining = Array(candidates.prefix(maxAttempts))
        guard !remaining.isEmpty else {
            // Do not auto-open QR; keep discovering periodically
            startPeriodicBonjourIfNeeded()
            return
        }
        
        func attemptNext() {
            if remaining.isEmpty {
                // Do not auto-open QR during reconnect; keep discovering periodically
                self.startPeriodicBonjourIfNeeded()
                return
            }
            let next = remaining.removeFirst()
            ArmadilloLogger.transport.info("Trying candidate: \(next.host):\(next.port) (\(next.name)) with pinned fp")
            
            guard let identity = try? SimpleClientIdentity.loadExistingIdentity() else {
                autoConnectInProgress = false
                updateStatus("Identity missing; fallback to QR", isError: true)
                return
            }
            
            // Temporarily hook a one-shot observer to detect success/failure
            let cancellable = tlsClient.$state
                .dropFirst()
                .sink { [weak self] st in
                    guard let self = self else { return }
                    switch st {
                    case .ready:
                        // Success path continues in completePairing()
                        break
                    case .failed:
                        // Try next candidate
                        attemptNext()
                    case .cancelled:
                        // Try next candidate
                        attemptNext()
                    default:
                        break
                    }
                }
            self.cancellables.insert(cancellable)
            
            // Connect
            self.currentHost = next.host
            self.currentPort = Int(next.port)
            self.tlsClient.connect(
                host: next.host,
                port: next.port,
                serverFingerprint: self.currentAgentFingerprint,
                clientIdentity: identity
            )
        }
        
        attemptNext()
    }
    
    private func tryBonjourAnyAndReconnect() {
        // Deprecated path: any-instance fallback removed in favor of discoverAll + fingerprint sweep
        startPeriodicBonjourIfNeeded()
    }
    
    private func reconnectUsingRefreshedEndpoint(_ endpoint: (host: String, port: UInt16)) {
        self.currentHost = endpoint.host
        self.currentPort = Int(endpoint.port)
        guard let identity = try? SimpleClientIdentity.loadExistingIdentity() else {
            self.autoConnectInProgress = false
            self.updateStatus("Identity missing; fallback to QR", isError: true)
            return
        }
        self.tlsClient.connect(
            host: endpoint.host,
            port: endpoint.port,
            serverFingerprint: self.currentAgentFingerprint,
            clientIdentity: identity
        )
    }

    private func startPeriodicBonjourIfNeeded() {
        if periodicBonjourTimer != nil { return }
        ArmadilloLogger.transport.info("Starting periodic Bonjour rediscovery")
        periodicBonjourTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.autoConnectInProgress { return }
                self.attemptBonjourRefreshAndReconnect()
            }
        }
    }

    // Manual vault write/read echo for QA
    func vaultTestEcho() {
        Task {
            do {
                let key = "sample_test"
                let valuePlain = "hello"
                let value = valuePlain.data(using: .utf8)!.base64EncodedString()
                try await tlsClient.send([
                    "type":"vault.write",
                    "key": key,
                    "value_b64": value,
                    "idempotency_key": UUID().uuidString
                ])
                _ = try? await tlsClient.waitForMessage(type: "vault.ack", timeout: 2.0)
                try await tlsClient.send(["type":"vault.read","key": key])
                if let msg = try? await tlsClient.waitForMessage(type: "vault.value", timeout: 2.0),
                   let sm = msg as? SimpleMessage,
                   let vb64 = sm.data["value_b64"] as? String,
                   let decoded = Data(base64Encoded: vb64),
                   let text = String(data: decoded, encoding: .utf8) {
                    self.updateStatus("Vault test OK (\(key)=\(text))", isError: false)
                } else {
                    self.updateStatus("Vault test: no value returned", isError: true)
                }
            } catch {
                self.updateStatus("Vault test failed: \(error.localizedDescription)", isError: true)
            }
        }
    }
    
    // Dev helpers to exercise scoped auth with different keys
    func devVaultWrite(key: String, value: String) {
        Task {
            do {
                let vb64 = value.data(using: .utf8)!.base64EncodedString()
                try await tlsClient.send([
                    "type":"vault.write",
                    "key": key,
                    "value_b64": vb64,
                    "idempotency_key": UUID().uuidString
                ])
                _ = try? await tlsClient.waitForMessage(type: "vault.ack", timeout: 2.0)
                self.updateStatus("Wrote \(key)=\(value)", isError: false)
            } catch {
                self.updateStatus("Vault write failed: \(error.localizedDescription)", isError: true)
            }
        }
    }
    
    func devVaultRead(key: String) {
        Task {
            do {
                try await tlsClient.send(["type":"vault.read","key": key])
                if let msg = try? await tlsClient.waitForMessage(type: "vault.value", timeout: 2.0),
                   let sm = msg as? SimpleMessage,
                   let vb64 = sm.data["value_b64"] as? String,
                   let decoded = Data(base64Encoded: vb64),
                   let text = String(data: decoded, encoding: .utf8) {
                    self.updateStatus("Read \(key)=\(text)", isError: false)
                } else {
                    self.updateStatus("No value for \(key)", isError: true)
                }
            } catch {
                self.updateStatus("Vault read failed: \(error.localizedDescription)", isError: true)
            }
        }
    }
    
    // Dev helper to trigger cred.get against a target origin/user
    func devCredGet(origin: String, user: String) {
        Task {
            do {
                try await tlsClient.send([
                    "type": "cred.get",
                    "origin": origin,
                    "username": user
                ])
                if let msg = try? await tlsClient.waitForMessage(type: "cred.secret", timeout: 2.0),
                   let sm = msg as? SimpleMessage,
                   let pw = sm.data["password_b64"] as? String {
                    self.updateStatus("Cred get ok for \(origin)/\(user) pw_b64=\(pw)", isError: false)
                } else if let msg = try? await tlsClient.waitForMessage(type: "error", timeout: 2.0),
                          let sm = msg as? SimpleMessage,
                          let code = sm.data["code"] as? String {
                    self.updateStatus("Cred get error: \(code)", isError: true)
                } else {
                    self.updateStatus("Cred get: no response", isError: true)
                }
            } catch {
                self.updateStatus("Cred get failed: \(error.localizedDescription)", isError: true)
            }
        }
    }
    
    // Dev helper to seed a demo credential
    func devSeedCred(origin: String, user: String, secret: String) {
        Task {
            do {
                try await tlsClient.send([
                    "type": "cred.write",
                    "origin": origin,
                    "user": user,
                    "secret": secret
                ])
                if let msg = try? await tlsClient.waitForMessage(type: "cred.ack", timeout: 2.0),
                   let sm = msg as? SimpleMessage,
                   let ok = sm.data["ok"] as? Bool, ok {
                    self.updateStatus("Seeded cred for \(origin)/\(user)", isError: false)
                } else {
                    self.updateStatus("Seed cred: no ack", isError: true)
                }
            } catch {
                self.updateStatus("Seed cred failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // Dev helper to trigger proximity intent (prox_intent mode)
    func devProxIntent() {
        Task {
            do {
                try await tlsClient.send([
                    "type": "prox.intent"
                ])
                if let msg = try? await tlsClient.waitForMessage(type: "prox.ack", timeout: 2.0),
                   let sm = msg as? SimpleMessage,
                   let state = sm.data["state"] as? String {
                    self.updateStatus("Prox intent ack, state=\(state)", isError: false)
                } else {
                    self.updateStatus("Prox intent: no ack", isError: true)
                }
            } catch {
                self.updateStatus("Prox intent failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Kicks off sendIntentOK as a Task — called from Combine sink (non-async context).
    func sendIntentOKTask() {
        Task { await sendIntentOK() }
    }

    /// Sends intent.ok to Mac over TLS. BLE will continue via its existing periodic timer.
    func sendIntentOK() async {
        let msg: [String: Any] = [
            "type": "intent.ok",
            "corr_id": UUID().uuidString,
            "ts": Int(Date().timeIntervalSince1970)
        ]
        do {
            try await tlsClient.send(msg)
            ArmadilloLogger.transport.info("intent.ok sent to Mac")
        } catch {
            ArmadilloLogger.transport.warning("intent.ok send failed: \(error.localizedDescription)")
        }
    }



    func devProxPause(seconds: Int) {
        Task {
            do {
                try await tlsClient.send([
                    "type": "prox.pause",
                    "seconds": seconds
                ])
                if let msg = try? await tlsClient.waitForMessage(type: "prox.ack", timeout: 2.0),
                   let sm = msg as? SimpleMessage,
                   let state = sm.data["state"] as? String {
                    self.updateStatus("Prox paused (\(seconds)s) state=\(state)", isError: false)
                } else {
                    self.updateStatus("Prox pause: no ack", isError: true)
                }
            } catch {
                self.updateStatus("Prox pause failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func devProxResume() {
        Task {
            do {
                try await tlsClient.send([
                    "type": "prox.resume"
                ])
                if let msg = try? await tlsClient.waitForMessage(type: "prox.ack", timeout: 2.0),
                   let sm = msg as? SimpleMessage,
                   let state = sm.data["state"] as? String {
                    self.updateStatus("Prox resumed, state=\(state)", isError: false)
                } else {
                    self.updateStatus("Prox resume: no ack", isError: true)
                }
            } catch {
                self.updateStatus("Prox resume failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func devProxStatus() {
        Task {
            do {
                try await tlsClient.send([
                    "type": "prox.status"
                ])
                if let msg = try? await tlsClient.waitForMessage(type: "prox.status", timeout: 2.0),
                   let sm = msg as? SimpleMessage {
                    let mode = sm.data["mode"] as? String ?? "?"
                    let state = sm.data["state"] as? String ?? "?"
                    let tlsUp = sm.data["tls_up"] as? Bool ?? false
                    self.updateStatus("Prox status mode=\(mode) state=\(state) tls_up=\(tlsUp)", isError: false)
                } else {
                    self.updateStatus("Prox status: no response", isError: true)
                }
            } catch {
                self.updateStatus("Prox status failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Recovery UI hooks
    func generateRecoveryPhrase() {
        Task {
            do {
                try await tlsClient.send(["type":"recovery.phrase.generate"])
                if let msg = try? await tlsClient.waitForMessage(type: "recovery.phrase", timeout: 3.0),
                   let sm = msg as? SimpleMessage,
                   let phrase = sm.data["mnemonic"] as? String {
                    self.updateStatus("Recovery phrase generated. Write it down securely.", isError: false)
                    if self.devMode {
                        self.recoveryPhraseAlertText = phrase
                        self.showRecoveryPhraseAlert = true
                    }
                } else {
                    self.updateStatus("Failed to get recovery phrase", isError: true)
                }
            } catch {
                self.updateStatus("Recovery phrase error: \(error.localizedDescription)", isError: true)
            }
        }
    }

    @Published var pendingRekeyToken: String?

    func startRekey(countdown: Int = 30) {
        Task {
            do {
                try await tlsClient.send(["type":"vault.rekey.start","reason":"manual","countdown_secs": countdown])
                if let msg = try? await tlsClient.waitForMessage(type: "vault.ack", timeout: 3.0),
                   let sm = msg as? SimpleMessage,
                   let op = sm.data["op"] as? String, op == "rekey.start",
                   let token = sm.data["token"] as? String {
                    self.pendingRekeyToken = token
                    self.updateStatus("Rekey started. Token: \(token)", isError: false)
                    // Start client-side countdown
                    self.rekeyDeadline = Date().addingTimeInterval(TimeInterval(countdown))
                    self.rekeySecondsLeft = countdown
                    self.rekeyTimer?.invalidate()
                    self.rekeyTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                        Task { @MainActor in
                            guard let self = self else { return }
                            guard let deadline = self.rekeyDeadline else { return }
                            let left = Int(max(0, deadline.timeIntervalSinceNow.rounded()))
                            self.rekeySecondsLeft = left
                            if left <= 0 {
                                self.rekeyTimer?.invalidate()
                                self.rekeyTimer = nil
                                // Hide banner
                                self.pendingRekeyToken = nil
                                self.updateStatus("Rekey expired", isError: true)
                            }
                        }
                    }
                } else {
                    self.updateStatus("Rekey start failed", isError: true)
                }
            } catch {
                self.updateStatus("Rekey start error: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func commitRekey() {
        guard let tok = pendingRekeyToken else {
            updateStatus("No pending rekey", isError: true); return
        }
        Task {
            do {
                try await tlsClient.send(["type":"vault.rekey.commit","token": tok])
                if let msg = try? await tlsClient.waitForMessage(type: "vault.ack", timeout: 3.0),
                   let sm = msg as? SimpleMessage,
                   let op = sm.data["op"] as? String, op == "rekey.commit" {
                    self.updateStatus("Rekey committed", isError: false)
                    self.pendingRekeyToken = nil
                    self.rekeyTimer?.invalidate()
                    self.rekeyTimer = nil
                } else {
                    self.updateStatus("Rekey commit failed", isError: true)
                }
            } catch {
                self.updateStatus("Rekey commit error: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func abortRekey() {
        guard let tok = pendingRekeyToken else {
            updateStatus("No pending rekey", isError: true); return
        }
        Task {
            do {
                try await tlsClient.send(["type":"vault.rekey.abort","token": tok])
                if let msg = try? await tlsClient.waitForMessage(type: "vault.ack", timeout: 3.0),
                   let sm = msg as? SimpleMessage,
                   let op = sm.data["op"] as? String, op == "rekey.abort" {
                    self.updateStatus("Rekey aborted", isError: false)
                    self.pendingRekeyToken = nil
                    self.rekeyTimer?.invalidate()
                    self.rekeyTimer = nil
                } else {
                    self.updateStatus("Rekey abort failed", isError: true)
                }
            } catch {
                self.updateStatus("Rekey abort error: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // Dev-only: Request recovery phrase and copy to clipboard
    func copyRecoveryPhraseDev() {
        Task {
            do {
                try await tlsClient.send(["type":"recovery.phrase.generate"])
                if let msg = try? await tlsClient.waitForMessage(type: "recovery.phrase", timeout: 3.0),
                   let sm = msg as? SimpleMessage,
                   let phrase = sm.data["mnemonic"] as? String {
                    #if os(iOS)
                    if #available(iOS 16.0, *) {
                        UIPasteboard.general.setItems(
                            [[UIPasteboard.typeAutomatic: phrase]],
                            options: [UIPasteboard.OptionsKey.expirationDate: Date().addingTimeInterval(60)]
                        )
                    } else {
                        UIPasteboard.general.string = phrase
                        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                            UIPasteboard.general.string = ""
                        }
                    }
                    #endif
                    self.updateStatus("Recovery phrase copied to clipboard (dev)", isError: false)
                } else {
                    self.updateStatus("Failed to get recovery phrase", isError: true)
                }
            } catch {
                self.updateStatus("Recovery phrase error: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Developer toggles
    func setAutoConnectEnabled(_ enabled: Bool) {
        autoConnectEnabled = enabled
        AppSettings.shared.autoConnectEnabled = enabled
        if !enabled {
            // Stop reconnect background loops, but preserve any active connection
            discoveryTimer?.invalidate(); discoveryTimer = nil
            periodicBonjourTimer?.invalidate(); periodicBonjourTimer = nil
            autoConnectInProgress = false
            updateStatus("Auto-connect disabled", isError: false)
        } else {
            updateStatus("Auto-connect enabled", isError: false)
            if !isConnected {
                attemptAutoConnectIfPossible()
            }
        }
    }

    func forgetEndpoint() {
        // Best-effort: clear current in-memory endpoint and disable auto-connect
        currentHost = ""
        currentPort = 0
        autoConnectEnabled = false
        AppSettings.shared.autoConnectEnabled = false
        tlsClient.disconnect()
        isConnected = false
        updateStatus("Endpoint forgotten; scan QR to connect", isError: false)
    }

    func setDevMode(_ enabled: Bool) {
        devMode = enabled
        UserDefaults.standard.set(enabled, forKey: "dev_mode")
        updateStatus(enabled ? "Dev Mode enabled" : "Dev Mode disabled", isError: false)
    }
    
    // MARK: - Face ID Authentication Handler
    
    /// Handle auth.request from agent by prompting Face ID and sending auth.proof
    private func handleAuthRequest(corrId: String) {
        // Idempotency check: ignore duplicate requests for the same correlation ID
        if let current = currentAuthCorrId, current == corrId {
            ArmadilloLogger.security.info("Ignoring duplicate auth.request for corr_id=\(corrId)")
            return
        }
        
        currentAuthCorrId = corrId
        ArmadilloLogger.security.info("Handling auth.request with corr_id=\(corrId)")
        
        Task {
            do {
                // Get client identity for signing
                guard let identity = try? SimpleClientIdentity.loadExistingIdentity() else {
                    ArmadilloLogger.security.error("Cannot generate auth.proof: client identity not found")
                    updateStatus("Authentication failed: identity not found", isError: true)
                    self.currentAuthCorrId = nil
                    return
                }
                
                // Prompt Face ID and generate auth.proof
                let authProofMsg = try await FaceIDAuthenticator.generateAuthProof(
                    corrId: corrId,
                    clientIdentity: identity
                )
                
                // Send auth.proof to agent
                try await tlsClient.send(authProofMsg)
                ArmadilloLogger.security.info("Sent auth.proof to agent")
                
                // Clear the pending request
                await MainActor.run {
                    tlsClient.pendingAuthRequest = nil
                    self.currentAuthCorrId = nil
                }
                
            } catch FaceIDAuthenticator.AuthError.biometryNotEnrolled {
                updateStatus("Face ID not set up. Please enable Face ID in Settings.", isError: true)
                self.currentAuthCorrId = nil
            } catch FaceIDAuthenticator.AuthError.authenticationFailed(let error) {
                updateStatus("Face ID failed: \(error.localizedDescription)", isError: true)
                self.currentAuthCorrId = nil
            } catch {
                ArmadilloLogger.security.error("Auth request handling failed: \(error.localizedDescription)")
                updateStatus("Authentication error: \(error.localizedDescription)", isError: true)
                self.currentAuthCorrId = nil
            }
        }
    }
    
    private var heartbeatInterval: TimeInterval = 10.0

    /// Call from app scenePhase to reduce energy use in background.
    func setHeartbeatInterval(_ interval: TimeInterval) {
        guard interval != heartbeatInterval else { return }
        heartbeatInterval = interval
        if heartbeatTimer != nil { startHeartbeatTimer() } // restart with new interval
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { [weak self] in
                guard let self = self else { return }
                do {
                    _ = try await self.tlsClient.sendRequest(["type":"ping"], timeout: 2.0)
                } catch {
                    // Missed pong within budget: close and let reconnect logic handle recovery
                    await MainActor.run {
                        self.tlsClient.disconnect()
                        self.isConnected = false
                        self.updateStatus("Connection lost (heartbeat)", isError: true)
                    }
                }
            }
        }
    }
}
