import Foundation
import Network
import os.log
import CryptoKit

enum AppGroup {
    static let id = "group.com.armadillo"
    
    static func socketPath() throws -> String {
        // 1) Allow explicit override via environment
        if let raw = ProcessInfo.processInfo.environment["ARMADILLO_SOCKET_PATH"], !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            return path
        }

        // 2) Prefer user's home socket (current dev mode default)
        let homeSock = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".armadillo", isDirectory: true)
            .appendingPathComponent("a.sock", isDirectory: false)
            .path
        if FileManager.default.fileExists(atPath: homeSock) {
            return homeSock
        }

        // 3) If App Group socket exists, use it (when sandboxed + agent moved)
        if let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            let groupSock = base
                .appendingPathComponent("ipc", isDirectory: true)
                .appendingPathComponent("a.sock", isDirectory: false)
                .path
            if FileManager.default.fileExists(atPath: groupSock) {
                return groupSock
            }
        }

        // 4) Fallback to home path (even if not present yet)
        return homeSock
    }
}

class UnixSocketBridge {
    private let INTERNAL_NO_CORR: Set<String> = [
        "uds.hello",
        "uds.hello.ack",
        "route.heartbeat",
        "agent.log",
        "trust.event"
    ]
    
    private let logger = Logger(subsystem: "com.armadillo", category: "uds")
    
    private let socketPath: String
    private let connId: String = {
        // Local conn id generator (6 lowercase base36 chars)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        var s = ""
        for _ in 0..<6 {
            s.append(alphabet.randomElement(using: &rng)!)
        }
        return s
    }()
    private var sid: String?
    private var fpSuffix: String?
    private var fd: Int32 = -1
    private var isConnected = false
    private let ioQueue = DispatchQueue(label: "com.armadillo.uds.io", qos: .utility)
    
    // ✅ CRITICAL: Router for strict corr_id → NWConnection mapping
    private let router: CorrRouter
    // ✅ CRITICAL: Callback to forward agent messages to specific iOS connection
    var forwardToIOS: ((Data, NWConnection) -> Void)?
    // Optional tap for agent messages (e.g., auth.ok)
    var onAgentMessage: (([String: Any]) -> Void)?
    // Pending completions for TLS-initiated requests
    private var pendingCompletions: [String: (Data) -> Void] = [:]
    
    // Deduplication cache to prevent phantom replays from UDS buffer issues
    // Key: "type|corr_id|sha256(payload)" -> Timestamp
    private var dedupeCache: [String: TimeInterval] = [:]
    
    // Strong reference to read source to prevent loop from dying
    private var readSource: DispatchSourceRead?
    private var shouldRunReader = true
    private var readBuffer = Data()
    // Write routing decisions to /tmp so we always have a file to inspect
    private let routeLogURL: URL = URL(fileURLWithPath: "/tmp/armadillo-route.ndjson")
    
    init(router: CorrRouter) throws {
        self.router = router
        // Use App Group container for sandbox compatibility
        self.socketPath = try AppGroup.socketPath()
        logger.info("[role=tls cat=uds conn=\(self.connId)] uds: will connect to \(self.socketPath)")
    }
    
    func start(sid: String? = nil, fingerprint: String? = nil) throws {
        self.sid = sid
        if let f = fingerprint { self.fpSuffix = String(f.suffix(12)) }
        try connectToRustAgent()
        let pathMsg = ["event": "route_log_path", "path": routeLogURL.path]
        print(jsonString(pathMsg))
        appendRouteLog(pathMsg)
    }
    
    func stop() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        shouldRunReader = false
        isConnected = false
        
        logger.info("[role=tls cat=uds conn=\(self.connId)] bridge stopped")
    }
    
    func getSocketPath() -> String {
        return socketPath
    }
    
    // ✅ Direct send for iOS→agent messages (responses come via router callback)
    func sendDirect(_ data: Data) throws {
        guard fd >= 0 else {
            throw NSError(domain: "UnixSocketBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        // ✅ CRITICAL: Use ioQueue to serialize with other sends
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.send(frame: data)
            } catch {
                self.logger.error("sendDirect failed: \(error.localizedDescription)")
            }
        }
    }
    
    func send(json: [String: Any], completion: @escaping (Data) -> Void) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.fd >= 0 else {
                let err = ["type": "error", "code": "NOT_CONNECTED"]
                if let d = try? JSONSerialization.data(withJSONObject: err) {
                    completion(d)
                }
                return
            }
            do {
                var obj = json
                // Ensure every TLS-originated message carries a corr_id so the response can be matched
                let corr: String
                if let existing = obj["corr_id"] as? String, !existing.isEmpty {
                    corr = existing
                } else {
                    let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
                    corr = String((0..<6).compactMap { _ in chars.randomElement() })
                    obj["corr_id"] = corr
                }
                // Track completion for this corr_id
                pendingCompletions[corr] = completion

                let data = try JSONSerialization.data(withJSONObject: obj)
                try self.send(frame: data)
            } catch {
                let msg = "json ser failed: \(error.localizedDescription)"
                self.logger.error("\(msg)")
                let err = ["type": "error", "code": "JSON_ERROR", "message": msg]
                if let d = try? JSONSerialization.data(withJSONObject: err) {
                    completion(d)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func connectToRustAgent() throws {
        var prefix = "[role=tls cat=uds conn=\(self.connId)"
        if let s = sid { prefix += " sid=\(s)" }
        if let fp = fpSuffix { prefix += " fp_suffix=\(fp)" }
        prefix += "]"
        logger.info("\(prefix) uds: attempting to connect to \(self.socketPath)")
        print("UDS: attempting connect to \(self.socketPath)")

        let maxAttempts = 30
        for attempt in 1...maxAttempts {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                logger.error("UnixSocketBridge: socket() failed: errno=\(errno) \(String(cString: strerror(errno)))")
                throw UnixSocketError.connectionFailed
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            #if os(macOS)
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
            #endif
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            self.socketPath.withCString { cs in
                withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                        _ = strlcpy(dst, cs, maxLen)
                    }
                }
            }

            let len = socklen_t(MemoryLayout<sockaddr_un>.stride)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, len)
                }
            }

            if rc == 0 {
                isConnected = true
                logger.info("\(prefix) uds: connected on attempt \(attempt)")
                print("UDS: connected on attempt \(attempt)")
                sendUDSHello()
                startUDSReadLoop()
                return
            }

            let err = errno
            let errStr = String(cString: strerror(err))
            logger.error("\(prefix) uds: connect failed attempt \(attempt)/\(maxAttempts) errno=\(err) \(errStr)")
            print("UDS connect failed attempt \(attempt)/\(maxAttempts): errno=\(err) \(errStr)")
            close(fd)
            fd = -1

            // Retry on typical transient errors
            if err == ENOENT || err == ECONNREFUSED || err == EAGAIN {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            } else {
                break
            }
        }

        print("UDS: giving up after \(maxAttempts) attempts")
        throw UnixSocketError.connectionFailed
    }
    
    private func sendUDSHello() {
        let corr = UUID().uuidString
        let hello: [String: Any] = [
            "type": "uds.hello",
            "role": "tls",
            "proto": "arm/uds/1",
            "version": 1,
            "min_compatible": 1,
            "corr_id": corr
        ]
        if let data = try? JSONSerialization.data(withJSONObject: hello) {
            do {
                try send(frame: data)
            } catch {
                logger.error("Failed to send uds.hello: \(error.localizedDescription)")
            }
        }
    }
    
    
    private func startUDSReadLoop() {
        guard readSource == nil else { return }
        shouldRunReader = true
        
        logger.info("🟢 uds_read_start fd=\(self.fd)")
        
        // ✅ CRITICAL: Use DispatchSourceRead with STRONG reference
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let bytesRead = read(self.fd, &buffer, buffer.count)
            
            if bytesRead > 0 {
                self.logger.info("📥 uds_read_bytes n=\(bytesRead)")
                // Explicitly append only the read bytes
                self.readBuffer.append(contentsOf: buffer.prefix(bytesRead))
                self.drainFrames()
            } else if bytesRead == 0 {
                self.logger.info("📪 uds_read_eof")
                self.teardownReadLoop()
            } else {
                let err = errno
                self.logger.error("❌ uds_read_err errno=\(err)")
                self.teardownReadLoop()
            }
        }
        
        source.setCancelHandler { [weak self] in
            self?.logger.info("🛑 uds_read_cancel")
        }
        
        // ✅ CRITICAL: Keep strong reference
        self.readSource = source
        source.resume()
    }
    
    private func teardownReadLoop() {
        readSource?.cancel()
        readSource = nil
        shouldRunReader = false
    }
    
    private func drainFrames() {
        while readBuffer.count >= 4 {
            let len = readBuffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let total = 4 + Int(len)
            if readBuffer.count < total { return }
            let frame = readBuffer.subdata(in: 4..<total)
            readBuffer.removeSubrange(0..<total)
            handleIncomingFrame(frame)
        }
    }
    
    private func handleIncomingFrame(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            logger.error("❌ Received malformed message from agent (no type)")
            return
        }
        
        // Surface all agent messages (including unsolicited pushes) to upper layers.
        onAgentMessage?(json)
        
        // --- Deduplication Safety Net ---
        // Prevents processing the same frame twice if buffer logic glitches
        if let corrId = json["corr_id"] as? String, !corrId.isEmpty {
             let now = Date().timeIntervalSince1970
             let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
             let dedupKey = "\(type)|\(corrId)|\(hash)"
             
             if let lastSeen = dedupeCache[dedupKey], (now - lastSeen) < 2.0 {
                 logger.error("🛑 Dropping duplicate message: \(dedupKey)")
                 appendRouteLog(["event":"drop_duplicate","key":dedupKey])
                 return
             }
             
             dedupeCache[dedupKey] = now
             // Regular pruning
             if dedupeCache.count > 50 {
                 dedupeCache = dedupeCache.filter { now - $0.value < 5.0 }
             }
        }
        // --------------------------------
        
        if let corrId = json["corr_id"] as? String, !corrId.isEmpty {
            // proceed below
        } else if type == "trust.event" {
            // trust.event is an unsolicited push from agent; forward to the active iOS TLS connection.
            guard let targetConn = router.fallbackConn() else {
                logger.error("❌ trust.event drop: no active iOS connection")
                appendRouteLog(["event":"trust_event_drop_no_conn"])
                return
            }
            guard let callback = forwardToIOS else {
                logger.error("❌ forwardToIOS callback not set (trust.event)")
                appendRouteLog(["event":"trust_event_drop_no_callback"])
                return
            }
            callback(data, targetConn)
            logger.info("✅ trust.event.forward conn=\(String(describing: ObjectIdentifier(targetConn)))")
            let trustEvent = (json["trust_event"] as? String) ?? (json["event"] as? String) ?? ""
            appendRouteLog([
                "event": "trust_event_forward",
                "conn": "\(ObjectIdentifier(targetConn))",
                "trust_event": trustEvent
            ])
            return
        } else if INTERNAL_NO_CORR.contains(type) {
            appendRouteLog(["event":"uds_in_internal_no_corr","type":type])
            return
        } else if type == "prox.ack" {
            // Drop noisy prox.ack without corr_id (status poll)
            appendRouteLog(["event":"route_drop_no_corr","type":type])
            return
        } else {
            logger.error("❌ route_miss_no_corr type=\(type)")
            appendRouteLog(["event":"route_miss_no_corr","type":type])
            return
        }
        let corrId = json["corr_id"] as! String
        
        logger.info("📨 uds_in type=\(type) corr_id=\(corrId)")
        // also emit to stdout for easy tailing
        print(jsonString(["event":"uds_in","type":type,"corr_id":corrId]))
        appendRouteLog(["event":"uds_in","type":type,"corr_id":corrId])
        // TLS-initiated request? satisfy completion first
        if let completion = pendingCompletions.removeValue(forKey: corrId) {
            completion(data)
            logger.info("✅ route_out_completion type=\(type) corr_id=\(corrId)")
            print(jsonString(["event":"route_out_completion","type":type,"corr_id":corrId]))
            appendRouteLog(["event":"route_out_completion","type":type,"corr_id":corrId])
            return
        }
        
        // ✅ CRITICAL: Route STRICTLY by corr_id - NO fallbacks!
        guard let targetConn = router.route(corrId) else {
            if type == "auth.request", let fb = router.fallbackConn() {
                // Fallback push to last active iOS connection
                guard let callback = forwardToIOS else {
                    logger.error("❌ forwardToIOS callback not set (fallback)!")
                    return
                }
                callback(data, fb)
                logger.info("✅ route_out_fallback type=\(type) corr_id=\(corrId) conn=\(String(describing: ObjectIdentifier(fb)))")
                print(jsonString(["event":"route_out_fallback","type":type,"corr_id":corrId,"conn":"\(ObjectIdentifier(fb))"]))
                appendRouteLog([
                    "event":"route_out_fallback",
                    "type":type,
                    "corr_id":corrId,
                    "conn":"\(ObjectIdentifier(fb))"
                ])
                return
            } else {
                logger.error("❌ route_miss type=\(type) corr_id=\(corrId)")
                print(jsonString(["event":"route_miss","type":type,"corr_id":corrId]))
                appendRouteLog(["event":"route_miss","type":type,"corr_id":corrId])
                return
            }
        }
        
        // Forward to the EXACT connection that sent the request
        guard let callback = forwardToIOS else {
            logger.error("❌ forwardToIOS callback not set!")
            return
        }
        callback(data, targetConn)
        logger.info("✅ route_out type=\(type) corr_id=\(corrId) conn=\(String(describing: ObjectIdentifier(targetConn)))")
        print(jsonString(["event":"route_out","type":type,"corr_id":corrId,"conn":"\(ObjectIdentifier(targetConn))"]))
        appendRouteLog([
            "event":"route_out",
            "type":type,
            "corr_id":corrId,
            "conn":"\(ObjectIdentifier(targetConn))"
        ])
    }
    
    private func appendRouteLog(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        if let handle = try? FileHandle(forWritingTo: routeLogURL) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: routeLogURL.path, contents: line.data(using: .utf8))
        }
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(obj)"
    }
    
    // Hex dump helper
    private func hexDump(_ data: Data, tag: String) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let capped = hex.count > 128 ? String(hex.prefix(128)) + "… [redacted]" : hex
        logger.debug("\(tag) \(data.count)B \(capped)")
    }

    private func send(frame: Data) throws {
        // ✅ CRITICAL: Combine length + payload into ONE atomic write
        // to prevent interleaving between concurrent sends
        var combined = Data()
        
        // Append 4-byte length prefix (big-endian)
        let length = UInt32(frame.count).bigEndian
        combined.append(withUnsafeBytes(of: length) { Data($0) })
        
        // Append payload
        combined.append(frame)
        
        // Single atomic write
        hexDump(combined.prefix(4), tag: "UDS→LEN")
        hexDump(frame, tag: "UDS→BODY")
        try writeAll(combined)
    }
    
    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { ptr in
            var offset = 0
            while offset < data.count {
                let n = write(fd, ptr.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 {
                    throw UnixSocketError.sendFailed
                }
                offset += n
            }
        }
    }
    
    private func receiveResponse() throws -> Data {
        // Read response length (4 bytes, big-endian)
        let lengthData = try readExactly(4)
        hexDump(lengthData, tag: "UDS←LEN")
        let responseLength = lengthData.withUnsafeBytes { bytes in
            return UInt32(bigEndian: bytes.load(as: UInt32.self))
        }
        
        // Validate response length
        guard responseLength > 0 && responseLength <= 65536 else {
            throw UnixSocketError.receiveFailed
        }
        
        // Read response data
        let payload = try readExactly(Int(responseLength))
        hexDump(payload, tag: "UDS←BODY")
        return payload
    }
    
    private func readExactly(_ count: Int) throws -> Data {
        var buffer = Data(count: count)
        var offset = 0
        
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress!.advanced(by: offset), count - offset)
            }
            
            if n <= 0 {
                throw UnixSocketError.receiveFailed
            }
            
            offset += n
        }
        
        return buffer
    }
}

// MARK: - Errors

enum UnixSocketError: Error {
    case connectionFailed
    case sendFailed
    case receiveFailed
}

extension Notification.Name {
    static let udsEventForwardToIOS = Notification.Name("com.armadillo.uds.event")
}

// MARK: - Self-test

extension UnixSocketBridge {
    func selfTestPing() {
        guard isConnected else {
            logger.error("SelfTest: not connected to agent")
            return
        }
        let json = #"{"type":"ping","v":1}"#
        guard let body = json.data(using: .utf8) else { return }
        do {
            try send(frame: body)
            let reply = try receiveResponse()
            if let text = String(data: reply, encoding: .utf8) {
                logger.info("SelfTest reply: \(text)")
            } else {
                logger.info("SelfTest reply: <non-UTF8> \(reply.count)B")
            }
        } catch {
            logger.error("SelfTest ping failed: \(error.localizedDescription)")
        }
    }
}
