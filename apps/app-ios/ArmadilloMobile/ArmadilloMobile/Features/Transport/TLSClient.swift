// STATUS: ACTIVE
// PURPOSE: iOS TLS transport — sends intent.ok, auth messages, and pairing data to macOS agent
import Foundation
import Network
import Security
import CryptoKit

// Simple message protocol for basic communication
protocol SimpleArmadilloMessage {
    var type: String { get }
}

struct SimpleMessage: SimpleArmadilloMessage {
    let type: String
    let data: [String: Any]
}

struct SimplePing: SimpleArmadilloMessage {
    let type = "ping"
    let v = 1
    let timestamp: String
    
    init() {
        self.timestamp = ISO8601DateFormatter().string(from: Date())
    }
    
    func toDictionary() -> [String: Any] {
        return [
            "type": type,
            "v": v,
            "timestamp": timestamp
        ]
    }
}

class TLSClient: ObservableObject {
    @Published var state: ConnectionState = .idle
    @Published var lastError: String?
    @Published var pendingAuthRequest: (corrId: String, timestamp: Date)?  // Publishes auth.request from agent
    
    private var connection: NWConnection?
    private var serverFingerprint: String?
    private var logConnId: String = ConnID.new()
    private var logSid: String?
    private var logFpSuffix: String?
    private var receiveBuffer = Data()
    private struct TypeWaiter {
        let id: UUID
        let completion: (Result<SimpleArmadilloMessage, Error>) -> Void
    }

    private var pendingRequests: [String: (Result<SimpleArmadilloMessage, Error>) -> Void] = [:]
    private var pendingTypeWaiters: [String: [TypeWaiter]] = [:]
    private var connectStartAt: Date?
    
    // Auth state machine
    private enum AuthState {
        case unknown
        case pending(corrId: String)
        case authenticated(until: Date)
        case failed
    }
    private var authState: AuthState = .unknown
    private var authQueue: [[String: Any]] = []
    private let serialQueue = DispatchQueue(label: "com.armadillo.tlsclient.serial")
    
    enum ConnectionState {
        case idle
        case connecting
        case ready
        case failed(Error)
        case cancelled
        
        var description: String {
            switch self {
            case .idle: return "Idle"
            case .connecting: return "Connecting..."
            case .ready: return "Connected"
            case .failed(let error): return "Failed: \(error.localizedDescription)"
            case .cancelled: return "Disconnected"
            }
        }
    }
    
    private func ctxPrefix() -> String {
        let ctx = LogContext(role: "ios", cat: "tls", sid: logSid, conn: logConnId, fpSuffix: logFpSuffix)
        return ctx.prefix()
    }

    /// Connect to server with mutual TLS
    func connect(host: String, port: UInt16, serverFingerprint: String, clientIdentity: SecIdentity, sid: String? = nil) {
        self.logConnId = ConnID.new()
        self.logSid = sid
        self.logFpSuffix = String(serverFingerprint.suffix(12))
        ArmadilloLogger.transport.info("\(self.ctxPrefix()) Connecting to \(host):\(port) with mutual TLS")
        
        self.serverFingerprint = serverFingerprint
        state = .connecting
        lastError = nil
        
        let parameters = NWParameters.tcp
        let tlsOptions = createMutualTLSOptions(serverFingerprint: serverFingerprint, clientIdentity: clientIdentity)
        parameters.defaultProtocolStack.applicationProtocols.insert(tlsOptions, at: 0)
        
        connection = NWConnection(
            host: .name(host, nil),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        connectStartAt = Date()
        
        connection?.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                self?.logConnectionState(newState)
                self?.handleStateChange(newState)
            }
        }
        
        connection?.start(queue: .main)
        
        // Set connection timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Env.connectTimeout) { [weak self] in
            if case .connecting = self?.state {
                self?.disconnect()
                self?.state = .failed(TLSClientError.connectionTimeout)
            }
        }
    }
    
    /// Connect to server with simplified TLS (server verification only for MVP)
    func connectSimplified(host: String, port: UInt16, serverFingerprint: String) {
        ArmadilloLogger.transport.info("Connecting to \(host):\(port) with simplified TLS")
        
        self.serverFingerprint = serverFingerprint
        state = .connecting
        lastError = nil
        
        // For MVP, we'll use a simplified TLS connection without mutual auth
        // This will be enhanced with proper mutual TLS later
        let parameters = NWParameters.tcp
        let tlsOptions = createSimplifiedTLSOptions(serverFingerprint: serverFingerprint)
        parameters.defaultProtocolStack.applicationProtocols.insert(tlsOptions, at: 0)
        
        connection = NWConnection(
            host: .name(host, nil),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        
        connection?.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                self?.logConnectionState(newState)
                self?.handleStateChange(newState)
            }
        }
        
        connection?.start(queue: .main)
        
        // Set connection timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Env.connectTimeout) { [weak self] in
            if case .connecting = self?.state {
                self?.disconnect()
                self?.state = .failed(TLSClientError.connectionTimeout)
            }
        }
    }
    
    /// Disconnect from server
    func disconnect() {
        ArmadilloLogger.transport.info("Disconnecting from server")
        
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        cancelPendingWaiters(error: TLSClientError.cancelled)
        
        // Clear auth state and queue on disconnect
        authState = .unknown
        authQueue.removeAll()
        
        if case .ready = state {
            state = .cancelled
        }
    }
    
    /// Check if message type requires authentication
    private func requiresAuth(_ messageType: String) -> Bool {
        return ["vault.open", "vault.read", "vault.write"].contains(messageType)
    }
    
    /// Send message to server (public API - routes through auth gate)
    func send(_ message: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            serialQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: TLSClientError.notConnected)
                    return
                }
                
                guard case .ready = self.state else {
                    continuation.resume(throwing: TLSClientError.notConnected)
                    return
                }
                
                var msg = message
                // Generate unique corr_id per request (not per connection)
                if msg["corr_id"] == nil { msg["corr_id"] = ConnID.new() }
                
                guard let msgType = msg["type"] as? String else {
                    continuation.resume(throwing: TLSClientError.invalidMessage)
                    return
                }
                
                // Auth gating
                if self.requiresAuth(msgType) {
                    switch self.authState {
                    case .authenticated(let until):
                        if Date() < until {
                            // Auth valid, send immediately
                            Task {
                                do {
                                    try await self.sendDirectUnsafe(msg)
                                    continuation.resume()
                                } catch {
                                    continuation.resume(throwing: error)
                                }
                            }
                        } else {
                            // Auth expired, queue and reset
                            self.authQueue.append(msg)
                            self.authState = .unknown
                            ArmadilloLogger.transport.info("Auth expired, queuing \(msgType)")
                            continuation.resume()
                        }
                    case .pending:
                        // Auth in progress, queue
                        self.authQueue.append(msg)
                        ArmadilloLogger.transport.info("Auth pending, queuing \(msgType)")
                        continuation.resume()
                    case .unknown, .failed:
                        // Queue the message
                        self.authQueue.append(msg)
                        
                        // If already pending, don't spam auth.begin
                        if case .pending = self.authState {
                            ArmadilloLogger.transport.info("Auth pending; queued \(msgType)")
                            continuation.resume()
                            return
                        }
                        
                        let corr = (msg["corr_id"] as? String) ?? ConnID.new()
                        self.authState = .pending(corrId: corr)
                        
                        ArmadilloLogger.transport.info("Auth needed; queued \(msgType); sending auth.begin")
                        
                        Task {
                            let authBegin: [String: Any] = ["type": "auth.begin", "corr_id": corr]
                            try? await self.sendDirectUnsafe(authBegin)
                            continuation.resume()
                        }
                    }
                } else {
                    // Non-auth messages go straight through
                    Task {
                        do {
                            try await self.sendDirectUnsafe(msg)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
    
    /// Internal: send directly without auth gating or serialization
    private func sendDirectUnsafe(_ msg: [String: Any]) async throws {
        let frame = try FramedCodec.encode(json: msg)
        
        return try await withCheckedThrowingContinuation { continuation in
            guard let conn = self.connection else {
                continuation.resume(throwing: TLSClientError.notConnected)
                return
            }
            conn.send(content: frame, completion: .contentProcessed { error in
                if let error = error {
                    ArmadilloLogger.transport.error("Send failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                } else {
                    if let type = msg["type"] as? String {
                        ArmadilloLogger.transport.debug("Sent message: \(type)")
                    }
                    if Env.jsonLogs {
                        let obj: [String: Any] = [
                            "ts": ISO8601DateFormatter().string(from: Date()),
                            "corr_id": self.logConnId,
                            "role": "ios",
                            "event": "send",
                            "type": msg["type"] ?? "",
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: data, encoding: .utf8) {
                            print(line)
                        }
                    }
                    continuation.resume()
                }
            })
        }
    }
    
    /// Send message and wait for response
    func sendRequest(_ message: [String: Any], timeout: TimeInterval = Env.requestTimeout) async throws -> SimpleArmadilloMessage {
        try await send(message)
        
        // For ping messages, wait for pong
        if let type = message["type"] as? String, type == "ping" {
            return try await waitForResponse(type: "pong", timeout: timeout)
        }
        
        // For other messages, implement specific response handling as needed
        throw TLSClientError.unsupportedRequest
    }

    /// Wait for a specific message type (best-effort; completes the first pending waiter)
    func waitForMessage(type: String, timeout: TimeInterval) async throws -> SimpleArmadilloMessage {
        return try await withCheckedThrowingContinuation { continuation in
            let waiterId = UUID()
            // register waiter for type
            var arr = pendingTypeWaiters[type] ?? []
            arr.append(TypeWaiter(id: waiterId, completion: continuation.resume))
            pendingTypeWaiters[type] = arr
            // timeout removal
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self else { return }
                guard var waiters = self.pendingTypeWaiters[type],
                      let index = waiters.firstIndex(where: { $0.id == waiterId }) else {
                    return
                }
                let waiter = waiters.remove(at: index)
                self.pendingTypeWaiters[type] = waiters
                waiter.completion(.failure(TLSClientError.requestTimeout))
            }
        }
    }
    
    /// Test connection with ping
    func testConnection() async throws {
        ArmadilloLogger.transport.info("Testing connection with ping...")
        
        let ping = SimplePing()
        let response = try await sendRequest(ping.toDictionary(), timeout: 3.0)
        
        if response.type == "pong" {
            ArmadilloLogger.transport.info("✅ Ping test successful")
        } else {
            ArmadilloLogger.transport.error("❌ Unexpected response to ping: \(response.type)")
            throw TLSClientError.unexpectedResponse
        }
    }
    
    private func waitForResponse(type: String, timeout: TimeInterval) async throws -> SimpleArmadilloMessage {
        return try await withCheckedThrowingContinuation { continuation in
            let requestId = UUID().uuidString
            pendingRequests[requestId] = continuation.resume
            
            // Set timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if let completion = self?.pendingRequests.removeValue(forKey: requestId) {
                    completion(.failure(TLSClientError.requestTimeout))
                }
            }
        }
    }
    
    private func createMutualTLSOptions(serverFingerprint: String, clientIdentity: SecIdentity) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions
        
        // Use TLS 1.3 with client certificate
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv13)
        ArmadilloLogger.transport.info("\(self.ctxPrefix()) Using TLS 1.3 with mutual authentication")
        
        // Set ALPN protocol
        "armadillo/1.0".withCString { ptr in
            sec_protocol_options_add_tls_application_protocol(secOptions, ptr)
        }
        
        // 🔑 Set client identity for mutual TLS
        
        if let osIdentity = sec_identity_create(clientIdentity) {
            sec_protocol_options_set_local_identity(secOptions, osIdentity)
            ArmadilloLogger.transport.info("\(self.ctxPrefix()) ✅ Client identity configured for mutual TLS")
        } else {
            ArmadilloLogger.transport.error("\(self.ctxPrefix()) ❌ Failed to configure client identity")
        }
        
        // 🔐 Certificate pinning for self-signed cert
        sec_protocol_options_set_verify_block(secOptions, { secMetadata, secTrust, completion in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            guard let cert = SecTrustGetCertificateAtIndex(trust, 0) else {
            ArmadilloLogger.transport.error("\(self.ctxPrefix()) Failed to get server certificate")
                completion(false)
                return
            }
            
            let der = SecCertificateCopyData(cert) as Data
            let digest = SHA256.hash(data: der)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            let computedFingerprint = "sha256:\(hex)"
            
            ArmadilloLogger.transport.info("\(self.ctxPrefix()) Server cert fingerprint: \(computedFingerprint)")
            ArmadilloLogger.transport.info("\(self.ctxPrefix()) Expected fingerprint: \(serverFingerprint)")
            
            let isValid = computedFingerprint == serverFingerprint
            ArmadilloLogger.transport.info("\(self.ctxPrefix()) Certificate pinning result: \(isValid ? "✅ VALID" : "❌ INVALID")")
            
            completion(isValid)
        }, DispatchQueue.global(qos: .userInitiated))
        
        return options
    }
    
    private func createSimplifiedTLSOptions(serverFingerprint: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions
        
        // Use TLS 1.3 with client certificate
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv13)
        ArmadilloLogger.transport.info("Using TLS 1.3 with client certificate")
        
        // Set ALPN protocol
        "armadillo/1.0".withCString { ptr in
            sec_protocol_options_add_tls_application_protocol(secOptions, ptr)
        }
        
        // 🔑 Set client identity for mutual TLS
        // Note: For now, we'll handle this synchronously in the connection setup
        // The identity should be pre-enrolled during pairing
        do {
            // Try to load existing identity (should exist after enrollment)
            if let existingIdentity = try? SimpleClientIdentity.loadExistingIdentity() {
                guard let osIdentity = sec_identity_create(existingIdentity) else {
                    ArmadilloLogger.transport.error("Failed to create sec_identity_t from client identity")
                    throw TLSClientError.clientIdentityFailed
                }
                sec_protocol_options_set_local_identity(secOptions, osIdentity)
                ArmadilloLogger.transport.info("Client identity configured for mutual TLS")
            } else {
                ArmadilloLogger.transport.warning("No client identity found - will need enrollment")
                // Continue without client identity - enrollment should happen during pairing
            }
        } catch {
            ArmadilloLogger.transport.warning("Failed to set client identity: \(error.localizedDescription)")
            // Continue without client identity for now
        }
        
        // 🔐 Certificate pinning for self-signed cert
        sec_protocol_options_set_verify_block(secOptions, { secMetadata, secTrust, completion in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            guard let cert = SecTrustGetCertificateAtIndex(trust, 0) else {
                ArmadilloLogger.transport.error("Failed to get server certificate")
                completion(false)
                return
            }
            
            let der = SecCertificateCopyData(cert) as Data
            let digest = SHA256.hash(data: der)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            let computedFingerprint = "sha256:\(hex)"
            
            ArmadilloLogger.transport.info("Server cert fingerprint: \(computedFingerprint)")
            ArmadilloLogger.transport.info("Expected fingerprint: \(serverFingerprint)")
            
            let isValid = computedFingerprint == serverFingerprint
            ArmadilloLogger.transport.info("Certificate pinning result: \(isValid ? "✅ VALID" : "❌ INVALID")")
            
            completion(isValid)
        }, DispatchQueue.global(qos: .userInitiated))
        
        return options
    }
    
    private func logConnectionState(_ state: NWConnection.State) {
        switch state {
        case .setup:
            ArmadilloLogger.transport.info("TLS state = setup")
        case .waiting(let error):
            ArmadilloLogger.transport.info("TLS state = waiting: \(error.localizedDescription)")
        case .preparing:
            ArmadilloLogger.transport.info("TLS state = preparing")
        case .ready:
            ArmadilloLogger.transport.info("TLS state = ✅ ready (TLS up, ALPN ok)")
        case .failed(let error):
            ArmadilloLogger.transport.error("TLS state = ❌ failed: \(error.localizedDescription)")
        case .cancelled:
            ArmadilloLogger.transport.info("TLS state = cancelled")
        @unknown default:
            ArmadilloLogger.transport.info("TLS state = unknown")
        }
    }
    
    private func handleStateChange(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            ArmadilloLogger.transport.info("TLS connection established")
            state = .ready
            if Env.jsonLogs {
                let elapsed = Int((Date().timeIntervalSince(connectStartAt ?? Date())) * 1000)
                let resumed = elapsed < 80
                let obj: [String: Any] = [
                    "ts": ISO8601DateFormatter().string(from: Date()),
                    "role": "ios",
                    "event": "mtls.established",
                    "corr_id": logConnId,
                    "elapsed_ms": elapsed,
                    "resumed": resumed
                ]
                if let data = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: data, encoding: .utf8) { print(line) }
            }
            startReceiving()
            
        case .failed(let error):
            ArmadilloLogger.transport.error("TLS connection failed: \(error.localizedDescription)")
            state = .failed(error)
            lastError = error.localizedDescription
            cancelPendingWaiters(error: error)
            
        case .waiting(let error):
            // Treat certain waiting errors as immediate failures so higher-level logic can retry
            ArmadilloLogger.transport.info("TLS state = waiting: \(error.localizedDescription)")
            if shouldTreatWaitingAsFailure(error) {
                disconnect()
                state = .failed(error)
                lastError = error.localizedDescription
                cancelPendingWaiters(error: error)
            }
            
        case .cancelled:
            ArmadilloLogger.transport.info("TLS connection cancelled")
            state = .cancelled
            cancelPendingWaiters(error: TLSClientError.cancelled)
            
        default:
            break
        }
    }
    
    private func shouldTreatWaitingAsFailure(_ error: NWError) -> Bool {
        switch error {
        case .posix(let code):
            // Common immediate failures where retrying another endpoint makes sense
            return code == .ECONNREFUSED || code == .ETIMEDOUT || code == .EHOSTUNREACH || code == .ENETDOWN || code == .ENETUNREACH
        case .dns:
            return true
        default:
            return false
        }
    }
    
    private func startReceiving() {
        receiveFrame()
    }
    
    private func receiveFrame() {
        guard let connection = connection else { return }
        
        // First, receive the 4-byte length header
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                ArmadilloLogger.transport.error("Receive header failed: \(error.localizedDescription)")
                self.disconnect(); return
            }
            guard let lengthData = data else {
                if isComplete {
                    ArmadilloLogger.transport.info("Peer closed (no header)")
                    self.disconnect()
                } else {
                    ArmadilloLogger.transport.error("No header data received")
                }
                return
            }
            if lengthData.count < 4 {
                if isComplete {
                    ArmadilloLogger.transport.info("Peer closed during header (\(lengthData.count)/4)")
                    self.disconnect()
                } else {
                    ArmadilloLogger.transport.error("Invalid frame header")
                }
                return
            }
            
            do {
                let frameLength = try FramedCodec.decodeLength(from: lengthData)
                let n = Int(frameLength)
                // Hard cap: if length > 1MB the stream is corrupt or under attack. Disconnect.
                guard n > 0 && n <= 1_000_000 else {
                    ArmadilloLogger.transport.error("Frame length out of bounds: \(n) bytes. Disconnecting.")
                    self.disconnect()
                    return
                }
                ArmadilloLogger.transport.debug("Incoming frame length = \(n)")
                self.receiveFrameBody(length: n)
            } catch {
                ArmadilloLogger.transport.error("Failed to decode frame length: \(error.localizedDescription)")
                self.disconnect()
            }
        }
    }
    
    private func receiveFrameBody(length: Int) {
        guard let connection = connection else { return }
        
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                ArmadilloLogger.transport.error("Receive body failed: \(error.localizedDescription)")
                self.disconnect(); return
            }
            guard let frameBody = data else {
                if isComplete {
                    ArmadilloLogger.transport.info("Peer closed during body (wanted \(length))")
                    self.disconnect()
                } else {
                    ArmadilloLogger.transport.error("No message data received")
                }
                return
            }
            
            if frameBody.count != length {
                if isComplete {
                    ArmadilloLogger.transport.info("Peer closed mid-frame (got \(frameBody.count)/\(length))")
                    self.disconnect()
                } else {
                    ArmadilloLogger.transport.error("Invalid frame body")
                }
                return
            }
            
            self.handleReceivedFrame(frameBody)
            
            // Continue receiving next framed message after responding
            if !isComplete {
                self.receiveFrame()
            } else {
                ArmadilloLogger.transport.info("Peer closed after full frame")
                self.disconnect()
            }
        }
    }
    
    private func handleReceivedFrame(_ data: Data) {
        do {
            // Parse as JSON dictionary
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messageType = json["type"] as? String else {
                ArmadilloLogger.transport.error("Invalid message format")
                return
            }
            
            ArmadilloLogger.transport.debug("Received message: \(messageType)")
            
            // Complete waiters for known response types
            if messageType == "pong" || messageType == "pairing.ack" {
                let message = SimpleMessage(type: messageType, data: json)
                // Fix: don't mutate dict while iterating — extract key first
                if let firstKey = pendingRequests.keys.first,
                   let completion = pendingRequests.removeValue(forKey: firstKey) {
                    completion(.success(message))
                }
            }
            // Complete any waiter registered for this type
            if var waiters = pendingTypeWaiters[messageType], !waiters.isEmpty {
                let message = SimpleMessage(type: messageType, data: json)
                let waiter = waiters.removeFirst()
                pendingTypeWaiters[messageType] = waiters
                waiter.completion(.success(message))
            }
            if Env.jsonLogs {
                let fp = (self.serverFingerprint ?? "")
                let fpOut = Env.redactLogs ? String(fp.suffix(12)) : fp
                let obj: [String: Any] = [
                    "ts": ISO8601DateFormatter().string(from: Date()),
                    "corr_id": self.logConnId,
                    "role": "ios",
                    "event": "recv",
                    "type": messageType,
                    "fp_suffix": String(fpOut.suffix(12))
                ]
                if let data = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: data, encoding: .utf8) {
                    print(line)
                }
            }
            
            // Handle auth.request push from agent
            if messageType == "auth.request" {
                if let corrId = json["corr_id"] as? String {
                    DispatchQueue.main.async {
                        self.pendingAuthRequest = (corrId, Date())
                    }
                    ArmadilloLogger.security.info("Received auth.request from agent, corr_id=\(corrId)")
                } else {
                    ArmadilloLogger.security.warning("Received auth.request without corr_id")
                }
            }
            
            // Handle auth.ok to complete authentication and drain queue
            if messageType == "auth.ok" {
                if let corrId = json["corr_id"] as? String {
                    ArmadilloLogger.security.info("Received auth.ok from agent, corr_id=\(corrId)")
                    
                    self.serialQueue.async { [weak self] in
                        guard let self = self else { return }
                        
                        // Update auth state (valid for 5 minutes)
                        let validUntil = Date().addingTimeInterval(300)
                        self.authState = .authenticated(until: validUntil)
                        
                        // Drain the auth queue
                        let queuedMessages = self.authQueue
                        self.authQueue.removeAll()
                        
                        let queuedTypes = queuedMessages.compactMap { $0["type"] as? String }.joined(separator: ", ")
                        ArmadilloLogger.security.info("Auth granted, draining \(queuedMessages.count) queued messages: [\(queuedTypes)]")
                        
                        Task { [weak self] in
                            guard let self = self else { return }
                            for queuedMsg in queuedMessages {
                                do {
                                    try await self.sendDirectUnsafe(queuedMsg)
                                } catch {
                                    ArmadilloLogger.transport.error("Failed to send queued message: \(error)")
                                }
                            }
                        }
                    }
                    
                    NotificationCenter.default.post(name: .authCompleted, object: nil, userInfo: ["corr_id": corrId])
                }
            }

            // Forward trust state updates to UI layer so iOS session state stays in sync with Mac-side revoke.
            if messageType == "trust.event" {
                let trustEvent = (json["trust_event"] as? String) ?? (json["event"] as? String) ?? ""
                let trustId = (json["trust_id"] as? String) ?? ""
                let mode = (json["mode"] as? String) ?? ""
                NotificationCenter.default.post(
                    name: .trustEventReceived,
                    object: nil,
                    userInfo: [
                        "trust_event": trustEvent,
                        "trust_id": trustId,
                        "mode": mode
                    ]
                )
            }
            
            // Handle other message types as needed
            
        } catch {
            ArmadilloLogger.transport.error("Failed to decode received message: \(error.localizedDescription)")
        }
    }

    /// Fail all pending waiters (by type or request) to avoid leaked continuations
    private func cancelPendingWaiters(error: Error) {
        let completions = pendingRequests.map { $0.value }
        pendingRequests.removeAll()
        completions.forEach { $0(.failure(error)) }

        for (type, waiters) in pendingTypeWaiters {
            waiters.forEach { $0.completion(.failure(error)) }
            pendingTypeWaiters[type] = []
        }
        pendingAuthRequest = nil
    }
}

enum TLSClientError: LocalizedError {
    case notConnected
    case connectionTimeout
    case requestTimeout
    case unsupportedRequest
    case unexpectedResponse
    case clientIdentityFailed
    case cancelled
    case invalidMessage
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to server"
        case .connectionTimeout:
            return "Connection timed out"
        case .requestTimeout:
            return "Request timed out"
        case .unsupportedRequest:
            return "Unsupported request type"
        case .unexpectedResponse:
            return "Unexpected response from server"
        case .clientIdentityFailed:
            return "Failed to configure client identity"
        case .cancelled:
            return "Connection cancelled"
        case .invalidMessage:
            return "Invalid message format"
        }
    }
}

extension Notification.Name {
    static let authCompleted = Notification.Name("com.armadillo.authCompleted")
    static let trustEventReceived = Notification.Name("com.armadillo.trustEventReceived")
}
