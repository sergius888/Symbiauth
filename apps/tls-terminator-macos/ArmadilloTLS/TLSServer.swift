import Foundation
import Network
import Security
import CryptoKit // *
import AppKit // *
import os.log

class TLSServer {
    
    private let logger = Logger(subsystem: "com.armadillo.tls", category: "TLSServer")
    
    private let identity: SecIdentity
    private let fingerprint: String
    private let socketBridge: UnixSocketBridge
    private var bleScanner: BLEScanner?
    private var bleTrustCentral: BLETrustCentral?
    private(set) var latestTrustState: BLETrustCentral.TrustStateSnapshot?
    
    // ✅ CRITICAL: Strict corr_id → NWConnection router
    private let router = CorrRouter()
    
    private var listener: NWListener?
    private var _port: UInt16 = 0
    private let jsonLogs: Bool = ProcessInfo.processInfo.environment["ARMADILLO_LOG_FORMAT"] == "json"
    private let redactLogs: Bool = ProcessInfo.processInfo.environment["ARMADILLO_LOG_REDACT"] == "1"
    private let logToFile: Bool = ProcessInfo.processInfo.environment["ARM_LOG_FILE"] == "1"
    private var corrIdByConn: [ObjectIdentifier: String] = [:]
    private var ndjsonWriter: NDJSONWriter?
    private var startTimeByConn: [ObjectIdentifier: Date] = [:]
    private var activeConns: [ObjectIdentifier: NWConnection] = [:]
    private var lastIosSeen: [ObjectIdentifier: Date] = [:]
    // Cache latest vault.open from iOS so we can replay it after auth.ok
    private var lastVaultOpenObj: [String: Any]?
    private var routerGCTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private let logLevel: String = {
        let v = ProcessInfo.processInfo.environment["ARM_LOG_LEVEL"]?.lowercased() ?? "info"
        switch v {
        case "error","warn","info","debug": return v
        default: return "info"
        }
    }()
    
    // Callback for when the server is ready with actual port
    var onReady: ((UInt16) -> Void)?
    
    // Notify UI to refresh when allowed clients change
    static let allowedClientsChangedNotification = Notification.Name("AllowedClientsChanged")
    static let trustStateChangedNotification = Notification.Name("TrustStateChanged")
    
    var port: UInt16 {
        return _port
    }
    
    // Public logging entry for external UI actions (NDJSON + stdout when enabled)
    func publicLog(_ obj: [String: Any]) {
        emitJSONLog(obj)
    }

    // Generic passthrough for menubar-to-agent requests.
    // Keeps launcher logic out of TLSServer while allowing AppDelegate to use UDS.
    func sendToAgent(json: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        socketBridge.send(json: json) { data in
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion([:])
                return
            }
            completion(obj)
        }
    }

    // Runtime BLE trust config update so mode/timers changed from UI apply immediately
    // without restarting processes or relying on startup env vars.
    func applyTrustRuntimeConfig(mode: String, backgroundTtlSecs: UInt64) {
        bleTrustCentral?.updateRuntimeConfig(mode: mode, ttlSecs: backgroundTtlSecs)
        bleTrustCentral?.requestImmediateProof(reason: "trust_mode_updated")
        emitJSONLog([
            "event": "ble.trust_central.runtime_config_applied",
            "mode": mode,
            "ttl_secs": backgroundTtlSecs
        ])
    }
    
    init(identity: SecIdentity, fingerprint: String) throws {
        self.identity = identity
        self.fingerprint = fingerprint
        
        // ✅ Create bridge with router (callback set after init)
        self.socketBridge = try UnixSocketBridge(router: router)
        
        // ✅ Set callback now that self is initialized
        self.socketBridge.forwardToIOS = { [unowned self] data, targetConn in
            self.sendResponse(data, to: targetConn)
        }
        // Observe messages coming back from agent (e.g., auth.ok)
        self.socketBridge.onAgentMessage = { [unowned self] json in
            guard let t = json["type"] as? String else { return }
            if t == "auth.ok" {
                self.resendVaultOpen()
            } else if t == "trust.event" {
                let snapshot = self.bleTrustCentral?.ingestTrustEvent(json)
                DispatchQueue.main.async { [weak self] in
                    self?.latestTrustState = snapshot
                    NotificationCenter.default.post(name: TLSServer.trustStateChangedNotification, object: nil)
                }
                let trustEvent = (json["trust_event"] as? String) ?? (json["event"] as? String) ?? ""
                self.emitJSONLog([
                    "role": "tls",
                    "event": "trust.event.recv",
                    "trust_event": trustEvent,
                    "trust_id": json["trust_id"] as? String ?? ""
                ])
            }
        }
        
        if logToFile {
            do {
                ndjsonWriter = try NDJSONWriter()
            } catch {
                logger.warning("Failed to initialize NDJSON writer: \(error.localizedDescription), continuing without file logging")
            }
        }
    }
    
    func start() throws {
        // Create TLS options with mutual authentication
        let tlsOptions = createTLSOptions()

        // Ensure UDS bridge is connected and announce route log path
        try socketBridge.start(sid: nil, fingerprint: fingerprint)
        startRouterGC()
        
        // Create listener parameters
        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        
        // Create listener on fixed port 8443 (main mTLS endpoint)
        guard let nwPort = NWEndpoint.Port(rawValue: 8443) else {
            throw TLSServerError.listenerCreationFailed
        }
        listener = try NWListener(using: parameters, on: nwPort)
        
        guard let listener = listener else {
            throw TLSServerError.listenerCreationFailed
        }
        
        // Set up connection handler
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        
        // Set up state change handler
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerStateChange(state)
        }
        
        // Start listening
        listener.start(queue: .main)
        
        // Get the actual port
        if case .ready = listener.state,
           let port = listener.port {
            _port = port.rawValue
        }
        
        logger.info("TLS server started on port \(self._port)")
        
        // Register for sleep notifications and forward to agent
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let obj: [String: Any] = ["type": "host.sleep"]
            self.socketBridge.send(json: obj) { _ in /* ignore */ }
            self.emitJSONLog(["role": "tls", "event": "host.sleep"])
        }
        
        // Periodic vault.status emission (every 60s)
        let timer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let req: [String: Any] = ["type": "vault.status"]
            self.socketBridge.send(json: req) { response in
                if let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any] {
                    var out: [String: Any] = [
                        "ts": ISO8601DateFormatter().string(from: Date()),
                        "role": "tls",
                        "event": "vault.status"
                    ]
                    if let unlocked = obj["unlocked"] { out["unlocked"] = unlocked }
                    if let entries = obj["entries"] { out["entries"] = entries }
                    if let idle = obj["idle_ms"] { out["idle_ms"] = idle }
                    self.emitJSONLog(out)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        
        // Trust-v1 BLE central (Phase 3): always-on scan when enabled.
        if ProcessInfo.processInfo.environment["ARM_TRUST_V1"] == "1" {
            let allowed = loadAllowedClientFingerprints()
            if let phoneFp = allowed.first {
                let mode = parseTrustModeEnv()
                let ttl = parseTrustTtlEnv()
                self.bleTrustCentral = BLETrustCentral(
                    socketBridge: self.socketBridge,
                    phoneFp: phoneFp,
                    mode: mode,
                    ttlSecs: ttl,
                    onEvent: { [weak self] obj in self?.emitJSONLog(obj) }
                )
                self.bleTrustCentral?.start()
                emitJSONLog([
                    "event": "ble.trust_central.enabled",
                    "phone_fp": phoneFp,
                    "mode": mode,
                    "ttl_secs": ttl
                ])
            } else {
                emitJSONLog(["event": "ble.trust_central.disabled", "reason": "no_allowed_clients"])
            }
        }

        // Legacy BLE scanner remains available when trust-v1 path is disabled.
        if ProcessInfo.processInfo.environment["ARM_FEATURE_BLE"] == "1"
            && ProcessInfo.processInfo.environment["ARM_TRUST_V1"] != "1" {
            let allowed = loadAllowedClientFingerprints()
            if let deviceFp = allowed.first {
                let req: [String: Any] = ["type": "ble.k_ble", "device_fp": deviceFp]
                self.socketBridge.send(json: req) { [weak self] response in
                    guard let self = self else { return }
                    if let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                       (obj["type"] as? String) == "ble.k_ble",
                       let kB64 = obj["k_ble_b64"] as? String,
                       let kData = Data(base64Encoded: kB64) {
                        let suffix = String(self.fingerprint.suffix(12))
                        self.bleScanner = BLEScanner(
                            kBle: kData,
                            macFpSuffix: suffix,
                            logLevel: self.logLevel,
                            onEvent: { [weak self] obj in self?.emitJSONLog(obj) }
                        )
                        self.emitJSONLog(["event": "ble.scan.enabled", "ts": ISO8601DateFormatter().string(from: Date())])
                    } else {
                        self.emitJSONLog(["event": "ble.scan.disabled", "reason": "no_k_ble"])
                    }
                }
            } else {
                emitJSONLog(["event": "ble.scan.disabled", "reason": "no_allowed_clients"])
            }
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        logger.info("TLS server stopped")
    }
    
    // MARK: - Private Methods
    
    private func createTLSOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions
        
        // Check for dev mode environment variable (default to requiring client auth for MVP)
        let devNoClientAuth = ProcessInfo.processInfo.environment["DEV_NO_CLIENT_AUTH"] == "1" || 
                             ProcessInfo.processInfo.environment["MVP_MODE"] == "1"
                             // Removed default true - now we use proper mutual TLS
        
        // Debug logging
        logger.info("DEV_NO_CLIENT_AUTH = \(String(describing: ProcessInfo.processInfo.environment["DEV_NO_CLIENT_AUTH"]))") // *
        logger.info("MVP_MODE = \(String(describing: ProcessInfo.processInfo.environment["MVP_MODE"]))") // *
        logger.info("Dev mode branch = \(devNoClientAuth ? "DISABLE client-auth" : "REQUIRE client-auth")")
        
        // Use TLS 1.3 with proper mutual authentication
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv13)
        logger.info("Using TLS 1.3 with mutual authentication")
        
        // TLS 1.3 session resumption: Network.framework enables tickets by default for servers.
        // No explicit API available in this SDK; rely on platform defaults.
        logger.info("TLS session resumption: using platform defaults (tickets enabled by OS)")
        
        // Convert SecIdentity to sec_identity_t
        guard let osSecIdentity = sec_identity_create(identity) else {
            logger.error("Failed to create sec_identity_t from SecIdentity")
            return options
        }
        
        // Set identity for server certificate
        sec_protocol_options_set_local_identity(secOptions, osSecIdentity)
        
        // * Log the main server's certificate fingerprint
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        if let cert = cert {
            let der = SecCertificateCopyData(cert) as Data
            let fp = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            logger.info("MAIN leaf fingerprint (sha256) = \(fp)") // *
        }
        
        // Configure client authentication based on dev mode
        if devNoClientAuth {
            logger.info("🔧 DEV MODE: Client authentication COMPLETELY disabled")
            sec_protocol_options_set_peer_authentication_required(secOptions, false)
            
            // Additional aggressive disabling for dev mode
            // This should prevent any post-handshake authentication requests
            logger.info("Aggressively disabling all client authentication mechanisms")
        } else {
            logger.info("🔒 PRODUCTION MODE: Client authentication required")
            sec_protocol_options_set_peer_authentication_required(secOptions, true)
        }
        
        // Set ALPN protocol
        "armadillo/1.0".withCString { ptr in
            sec_protocol_options_add_tls_application_protocol(secOptions, ptr)
        }
        
        // Set certificate verification callback (only used when client auth is required)
        if !devNoClientAuth {
            logger.info("Setting up client certificate verification")
            sec_protocol_options_set_verify_block(secOptions, { [weak self] (metadata, trust, complete) in
                self?.verifyCertificate(metadata: metadata, trust: trust, complete: complete)
            }, .main)
        } else {
            logger.info("Skipping client certificate verification in dev mode")
        }
        
        return options
    }
    
    private func verifyCertificate(
        metadata: sec_protocol_metadata_t,
        trust: sec_trust_t,
        complete: @escaping sec_protocol_verify_complete_t
    ) {
        // Enforce client pinning against allowed list (~/.armadillo/allowed_clients.json)
        if ProcessInfo.processInfo.environment["ARM_TLS_PINNING"] == "0" {
            logger.info("Client cert verify: pinning disabled via ARM_TLS_PINNING=0")
            complete(true)
            return
        }
        let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
        // Use modern API to obtain certificate chain and take the leaf
        let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate]
        guard let cert = chain?.first else {
            logger.error("Client cert verify: no leaf cert found")
            complete(false)
            return
        }
        let der = SecCertificateCopyData(cert) as Data
        let fp = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let fullFp = "sha256:\(fp)"
        let allowed = loadAllowedClientFingerprints()
        if allowed.isEmpty {
            // Gate TOFU: only when provisioning==true (fresh reset/first install)
            if loadProvisioningState() {
                logger.info("Client cert verify: TOFU accept fp=\(fullFp) (provisioning mode)")
                appendAllowedClientFingerprint(fullFp)
                // End provisioning after first trust
                setProvisioningState(false, emitDisabledEvent: true)
                // Notify UI to refresh paired devices menu
                NotificationCenter.default.post(name: TLSServer.allowedClientsChangedNotification, object: nil)
        complete(true)
                return
            } else {
                logger.info("Client cert verify: TOFU disabled (no allowed clients, provisioning=false)")
                complete(false)
                return
            }
        }
        let ok = allowed.contains(fullFp)
        logger.info("Client cert verify: fp=\(fullFp) allowed=\(ok)")
        complete(ok)
    }
    
    private func handleListenerStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = self.listener?.port {
                self._port = port.rawValue
                self.logger.info("TLS listener ready on port \(self._port)")
                // Notify that server is ready with actual port
                self.onReady?(self._port)
            }
        case .failed(let error):
            self.logger.error("TLS listener failed: \(error.localizedDescription)")
        case .cancelled:
            self.logger.info("TLS listener cancelled")
        default:
            break
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        logger.info("New TLS connection from client")
        let id = ObjectIdentifier(connection)
        startTimeByConn[id] = Date()
        activeConns[id] = connection
        lastIosSeen[id] = Date()
        
        // Start the connection
        connection.start(queue: .main)
        
        // Set up connection state handler
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.handleConnectionStateChange(connection, state: state)
            if case .cancelled = state {
                self.activeConns.removeValue(forKey: id)
                self.lastIosSeen.removeValue(forKey: id)
                // ✅ Clean up router mappings for this connection
                self.router.drop(connection)
                self.corrIdByConn.removeValue(forKey: id)
                // Stop heartbeat timer if no active connections remain
                self.stopHeartbeatTimerIfNeeded()
            } else if case .failed(_) = state {
                self.activeConns.removeValue(forKey: id)
                self.lastIosSeen.removeValue(forKey: id)
                // ✅ Clean up router mappings for this connection
                self.router.drop(connection)
                self.corrIdByConn.removeValue(forKey: id)
                // Stop heartbeat timer if no active connections remain
                self.stopHeartbeatTimerIfNeeded()
            }
        }
    }
    
    private func handleConnectionStateChange(_ connection: NWConnection, state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("TLS connection established - starting message handling")
            // Start heartbeat timer if this is the first active connection
            if heartbeatTimer == nil {
                startHeartbeatTimer()
            }
            if jsonLogs {
                let id = ObjectIdentifier(connection)
                let start = startTimeByConn[id] ?? Date()
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                let resumed = elapsed < 80 // heuristic threshold
                var obj: [String: Any] = [
                    "ts": ISO8601DateFormatter().string(from: Date()),
                    "role": "tls",
                    "event": "mtls.established",
                    "elapsed_ms": elapsed,
                    "resumed": resumed
                ]
                if let cid = corrIdByConn[id] { obj["corr_id"] = cid }
                emitJSONLog(obj)
            }
            startMessageHandling(for: connection)
        case .failed(let error):
            logger.error("TLS connection failed: \(error.localizedDescription)")
            sendTlsDown()
        case .cancelled:
            logger.info("TLS connection cancelled")
            sendTlsDown()
        case .waiting(let error):
            logger.info("TLS connection waiting: \(error.localizedDescription)")
        case .preparing:
            logger.info("TLS connection preparing")
        case .setup:
            logger.info("TLS connection setup")
        @unknown default:
            logger.info("TLS connection unknown state: \(String(describing: state))") // *
        }
    }
    
    // Public: kick all active connections (used by revoke policy)
    func kickAllConnections(reason: String) {
        for (_, conn) in activeConns {
            conn.cancel()
        }
        emitJSONLog([
            "ts": ISO8601DateFormatter().string(from: Date()),
            "role": "tls",
            "event": "connections.kicked",
            "reason": reason
        ])
    }
    
    private func startRouterGC() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60))
        timer.setEventHandler { [weak self] in
            self?.router.gc(olderThan: 120)
        }
        timer.resume()
        self.routerGCTimer = timer
    }
    
    private func startHeartbeatTimer() {
        guard heartbeatTimer == nil else { return }
        logger.info("Starting proximity heartbeat timer (3s interval)")
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(3), repeating: .seconds(3))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Only send heartbeat if there are active connections
            guard !self.activeConns.isEmpty else {
                self.logger.warning("Heartbeat timer fired but no active connections; stopping timer")
                self.stopHeartbeatTimerIfNeeded()
                return
            }
            // Require recent traffic FROM iOS before emitting heartbeats; otherwise drop to Far
            let now = Date()
            let freshSeen = self.lastIosSeen.values.contains { now.timeIntervalSince($0) < 10 }
            guard freshSeen else {
                self.logger.error("No iOS traffic in >10s; stopping heartbeat timer and notifying agent")
                self.sendTlsDown() // drives agent proximity → Far and locks vault
                self.stopHeartbeatTimerIfNeeded(force: true)
                return
            }
            let msg: [String: Any] = ["type": "prox.heartbeat"]
            self.socketBridge.send(json: msg) { _ in /* ignore response */ }
        }
        timer.resume()
        self.heartbeatTimer = timer
    }
    
    private func stopHeartbeatTimerIfNeeded(force: Bool = false) {
        guard force || activeConns.isEmpty, let timer = heartbeatTimer else { return }
        let reason = force ? "(forced)" : "(no active connections)"
        logger.info("Stopping proximity heartbeat timer \(reason)")
        timer.cancel()
        heartbeatTimer = nil
    }
    
    private func startMessageHandling(for connection: NWConnection) {
        // Start receiving messages from the TLS connection
        receiveMessage(from: connection)
    }
    
    private func receiveMessage(from connection: NWConnection) {
            // Read message length (4 bytes, big-endian)
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                
                if let error = error {
                self.logger.error("Error reading message length: \(error.localizedDescription)")
                return
            }
            
            guard let lengthData = data, lengthData.count == 4 else {
                self.logger.error("Invalid message length data")
                return
            }
            
            // Parse message length
            let messageLength = lengthData.withUnsafeBytes { bytes in
                return UInt32(bigEndian: bytes.load(as: UInt32.self))
            }
            
            // Validate message length
            guard messageLength > 0 && messageLength <= 65536 else {
                self.logger.error("Invalid message length: \(messageLength)")
                return
            }
            
            // Read message data
            connection.receive(minimumIncompleteLength: Int(messageLength), maximumLength: Int(messageLength)) { [weak self] messageData, _, _, error in // *
                guard let self = self else { return } // *
                if let error = error {
                    self.logger.error("Error reading message data: \(error.localizedDescription)")
                    return
                }
                
            guard let data = messageData else {
                self.logger.error("No message data received")
                self.receiveMessage(from: connection)
                return
            }
            
            // ✅ CRITICAL FIX: Inject corr_id into EVERY message before forwarding to agent
            let modifiedData: Data
                if var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let id = ObjectIdentifier(connection)
                    // Track last inbound from iOS to gate heartbeats
                    self.lastIosSeen[id] = Date()
                    
                    // Get or create corr_id for THIS MESSAGE
                    let corrId: String
                    if let existing = obj["corr_id"] as? String, !existing.isEmpty {
                        corrId = existing
                } else {
                    // Generate new corr_id (6 lowercase alphanumeric)
                    let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
                    corrId = String((0..<6).compactMap { _ in chars.randomElement() })
                }
                
                // ALWAYS inject corr_id into message going to agent
                obj["corr_id"] = corrId
                
                // ✅ CRITICAL: Bind corr_id → this connection for routing responses
                self.router.bind(corrId, to: connection)
                self.logger.info("🔗 bind corr_id=\(corrId) conn=\(String(describing: ObjectIdentifier(connection)))")

                // Cache latest vault.open payload (without corr_id) for replay after auth.ok
                if let t = obj["type"] as? String, t == "vault.open" {
                    var copy = obj
                    copy.removeValue(forKey: "corr_id")
                    self.lastVaultOpenObj = copy
                }
                
                // Re-serialize
                if let injected = try? JSONSerialization.data(withJSONObject: obj) {
                    modifiedData = injected
                } else {
                    self.logger.error("Failed to re-serialize message with corr_id")
                    modifiedData = data
                }
                
                if self.jsonLogs {
                    var logObj: [String: Any] = [
                        "ts": ISO8601DateFormatter().string(from: Date()),
                        "role": "tls",
                        "event": "recv",
                            "corr_id": corrId
                        ]
                        if let t = obj["type"] as? String { logObj["type"] = t; logObj["conn"] = String(describing: id) }
                        self.emitJSONLog(logObj)
                    }
                } else {
                    // Non-JSON message, forward as-is (shouldn't happen)
                    self.logger.warning("Received non-JSON message from iOS")
                    modifiedData = data
                }
                
                // Forward modified message to Rust agent via Unix socket
                // ✅ Send to agent - response will come back via router callback
                do {
                    try self.socketBridge.sendDirect(modifiedData)
                    
                    // Log send event (to agent)
                    if self.jsonLogs, let obj = try? JSONSerialization.jsonObject(with: modifiedData) as? [String: Any] {
                        let id = ObjectIdentifier(connection)
                        var logObj: [String: Any] = [
                            "ts": ISO8601DateFormatter().string(from: Date()),
                            "role": "tls",
                            "event": "send",
                            "type": obj["type"] as? String ?? "?",
                            "corr_id": obj["corr_id"] as? String ?? "",
                            "conn": String(describing: id)
                        ]
                        self.emitJSONLog(logObj)
                    }
                } catch {
                    self.logger.error("Failed to send to agent: \(error.localizedDescription)")
                }
                
                // Continue reading next message
                self.receiveMessage(from: connection)
            }
        }
    }
    
    private func sendResponse(_ data: Data, to connection: NWConnection) {
        // Send length header (4 bytes, big-endian)
        var length = UInt32(data.count).bigEndian
        let lengthData = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        
        connection.send(content: lengthData, completion: .contentProcessed { error in
            if let error = error {
                self.logger.error("Error sending length header: \(error.localizedDescription)")
            }
        })
        
        // Send response data
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Error sending response data: \(error.localizedDescription)")
            }
        })
    }

    /// Replay cached vault.open to agent after auth.ok (Face ID)
    private func resendVaultOpen() {
        guard var obj = lastVaultOpenObj else { return }
        obj["corr_id"] = UUID().uuidString
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        do {
            try self.socketBridge.sendDirect(data)
            if jsonLogs {
                emitJSONLog([
                    "ts": ISO8601DateFormatter().string(from: Date()),
                    "role": "tls",
                    "event": "vault.open.replay",
                    "type": "vault.open",
                    "corr_id": obj["corr_id"] as? String ?? ""
                ])
            }
        } catch {
            logger.error("Failed to resend vault.open: \(error.localizedDescription)")
        }
    }

    /// Notify agent that TLS link is down so proximity can fall to Far immediately.
    private func sendTlsDown() {
        let obj: [String: Any] = [
            "type": "tls.down",
            "corr_id": UUID().uuidString
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            do {
                try self.socketBridge.sendDirect(data)
            } catch {
                logger.error("Failed to send tls.down: \(error.localizedDescription)")
            }
        }
    }

}
// MARK: - JSON Log writer helper
extension TLSServer {
    private func parseTrustModeEnv() -> String {
        let raw = (ProcessInfo.processInfo.environment["ARM_TRUST_MODE"] ?? "background_ttl").lowercased()
        switch raw {
        case "strict", "background_ttl", "office":
            return raw
        default:
            return "background_ttl"
        }
    }

    private func parseTrustTtlEnv() -> UInt64 {
        if let raw = ProcessInfo.processInfo.environment["ARM_TRUST_TTL_SECS"],
           let parsed = UInt64(raw) {
            return min(max(parsed, 30), 3600)
        }
        return 300
    }

    private func emitJSONLog(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        ndjsonWriter?.append(line: line)
    }
}

// MARK: - Allowed clients store
extension TLSServer {
    private func allowedClientsPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.armadillo/allowed_clients.json"
    }
    func loadAllowedClientFingerprints() -> Set<String> {
        let path = allowedClientsPath()
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return Set(arr)
    }
    func appendAllowedClientFingerprint(_ fp: String) {
        let path = allowedClientsPath()
        var set = loadAllowedClientFingerprints()
        if !set.contains(fp) {
            set.insert(fp)
            do {
                let array = Array(set)
                let data = try JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted])
                let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = URL(fileURLWithPath: path)
                try data.write(to: url, options: .atomic)
                // Ensure 0600 perms
                #if os(macOS)
                var attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o600))]
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
                #endif
            } catch {
                logger.error("Failed to persist allowed client fp: \(error.localizedDescription)")
            }
        }
    }
    func removeAllowedClientFingerprint(_ fp: String) {
        let path = allowedClientsPath()
        var set = loadAllowedClientFingerprints()
        if set.contains(fp) {
            set.remove(fp)
            do {
                let array = Array(set)
                let data = try JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted])
                let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = URL(fileURLWithPath: path)
                try data.write(to: url, options: .atomic)
                #if os(macOS)
                var attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o600))]
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
                #endif
                // Notify UI to refresh paired devices menu
                NotificationCenter.default.post(name: TLSServer.allowedClientsChangedNotification, object: nil)
            } catch {
                logger.error("Failed to remove allowed client fp: \(error.localizedDescription)")
            }
        }
    }
    func clearAllowedClients() {
        let path = allowedClientsPath()
        do {
            let data = try JSONSerialization.data(withJSONObject: [], options: [.prettyPrinted])
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: path)
            try data.write(to: url, options: .atomic)
            #if os(macOS)
            var attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o600))]
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
            #endif
            // Notify UI to refresh paired devices menu
            NotificationCenter.default.post(name: TLSServer.allowedClientsChangedNotification, object: nil)
        } catch {
            logger.error("Failed to clear allowed clients: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Provisioning (TOFU) state helpers
    private func pinStatePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.armadillo/pin_state.json"
    }
    fileprivate func loadProvisioningState() -> Bool {
        let path = pinStatePath()
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prov = obj["provisioning"] as? Bool else {
            return false
        }
        return prov
    }
    fileprivate func setProvisioningState(_ v: Bool, emitDisabledEvent: Bool) {
        let path = pinStatePath()
        do {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var obj: [String: Any] = ["provisioning": v]
            let key = v ? "set_at" : "first_enrolled_at"
            obj[key] = ISO8601DateFormatter().string(from: Date())
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            #if os(macOS)
            var attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o600))]
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
            #endif
            if v == false && emitDisabledEvent {
                emitJSONLog(["event":"pin.provisioning.disabled","ts": ISO8601DateFormatter().string(from: Date()), "role":"tls"])
            }
        } catch {
            logger.error("Failed writing pin_state.json: \(error.localizedDescription)")
        }
    }
}

// Simple NDJSON writer with size and daily rotation
final class NDJSONWriter {
    private let dirURL: URL
    private let fileURL: URL
    private let maxBytes: Int = 5 * 1024 * 1024 // 5 MB
    private var handle: FileHandle?
    private var currentDayKey: String
    
    init() {
        // Use Library directory to be sandbox-safe; resolves to container path when sandboxed
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let base = lib.appendingPathComponent("Logs/ArmadilloTLS", isDirectory: true)
        self.dirURL = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("events.ndjson")
        self.currentDayKey = Self.dayKey(Date())
        open()
        // Announce file path so user can tail it
        print("{\"ts\":\"\(ISO8601DateFormatter().string(from: Date()))\",\"role\":\"tls\",\"event\":\"logfile\",\"path\":\"\(self.fileURL.path)\"}")
    }
    
    func append(line: String) {
        rotateIfNeeded()
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do { try handle?.write(contentsOf: data) } catch { /* ignore */ }
    }
    
    private func open() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }
    
    private func rotateIfNeeded() {
        // Rotate on day change or size
        let day = Self.dayKey(Date())
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        if day != currentDayKey || size > maxBytes {
            rotate()
            currentDayKey = day
        }
    }
    
    private func rotate() {
        try? handle?.close()
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let rotated = dirURL.appendingPathComponent("events-\(ts).ndjson")
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        open()
    }
    
    private static func dayKey(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: d)
    }
}

// MARK: - Errors

enum TLSServerError: Error {
    case listenerCreationFailed
    case certificateValidationFailed
}
