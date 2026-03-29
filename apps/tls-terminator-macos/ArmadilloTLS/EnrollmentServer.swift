import Foundation
import Network
import Security
import Crypto
import CryptoKit // *
import X509
import SwiftASN1
import os.log

final class EnrollmentServer {
    private let logger = Logger(subsystem: "com.armadillo.tls", category: "EnrollmentServer")
    private let serverIdentity: SecIdentity   // ← injected
    private let certificateManager: CertificateManager
    private var listener: NWListener?
    private let port: UInt16
    // Retain active connections to avoid premature deallocation during send
    private var activeConns: [ObjectIdentifier: NWConnection] = [:]
    
    init(serverIdentity: SecIdentity,
         certificateManager: CertificateManager,
         port: UInt16 = 8444) {
        self.serverIdentity = serverIdentity
        self.certificateManager = certificateManager
        self.port = port
    }
    
    func start() throws {
        // * Create clean TLS options for enrollment (no mTLS, no ALPN)
        let tlsOptions = makeEnrollmentTLSOptions()
        let parameters = NWParameters(tls: tlsOptions)
        
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        
        // * added: Listener on 8444
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "EnrollmentServer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        self.listener = listener
        
        // * added: Enhanced state logging
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("🟢 Enrollment listener READY on :\(self?.port ?? 0)") // * added
            case .failed(let err):
                self?.logger.error("❌ Enrollment listener FAILED: \(err.localizedDescription)") // * added
            case .waiting(let err):
                self?.logger.warning("⏳ Enrollment listener WAITING: \(err.localizedDescription)") // * added
            default:
                break
            }
        }
        
        // * added: Enhanced connection logging
        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            self.logger.info("📥 /enroll: new connection")
            let id = ObjectIdentifier(conn)
            self.activeConns[id] = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                if case .failed(let err) = state {
                    self.logger.error("❌ /enroll conn FAILED: \(err.localizedDescription)")
                    self.activeConns.removeValue(forKey: id)
                } else if case .cancelled = state {
                    self.activeConns.removeValue(forKey: id)
                }
            }
            conn.start(queue: .main)
            self.handleConnection(conn)
        }
        
        listener.start(queue: .main)
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        logger.info("Enrollment server stopped")
    }
    
    private func makeEnrollmentTLSOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        
        guard let osId = sec_identity_create(serverIdentity) else {
            logger.error("❌ ENROLL: failed to create sec_identity_t")
            preconditionFailure("No server identity for ENROLL") // fail fast in dev
        }
        sec_protocol_options_set_local_identity(sec, osId)
        
        // log fingerprint so we SEE it
        var cert: SecCertificate?
        SecIdentityCopyCertificate(serverIdentity, &cert)
        if let cert = cert {
            let der = SecCertificateCopyData(cert) as Data
            let fp = CryptoKit.SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            logger.info("ENROLL leaf fingerprint (sha256) = \(fp)")
        }
        
        // no client-auth
        sec_protocol_options_set_peer_authentication_required(sec, false)
        
        // explicit http/1.1 for URLSession
        "http/1.1".withCString { sec_protocol_options_add_tls_application_protocol(sec, $0) }
        
        return options
    }
    
    // * added: New HTTP handler with enhanced logging
    private func handleConnection(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        // Tiny HTTP 1.1 reader (enough for our one POST)
        readHTTPOnce(from: conn) { [weak self] csrDER in
            guard let self else { return }
            do {
                // Gate TOFU by provisioning state
                let allowed = self.loadAllowedClients()
                let provisioning = self.loadProvisioningState()
                if allowed.isEmpty && provisioning == false {
                    // Reject with 403 TOFU_DISABLED
                    let body = #"{"error":"TOFU_DISABLED"}"#
                    var response = Data()
                    response.append("HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n".data(using: .utf8)!)
                    response.append(body.data(using: .utf8)!)
                    conn.send(content: response, completion: .contentProcessed({ _ in
                        self.logger.warning("🚫 /enroll rejected: TOFU disabled")
                        self.activeConns.removeValue(forKey: id)
                    }))
                    return
                }
                // Parse CSR (DER)
                let csr = try CertificateSigningRequest(derEncoded: Array(csrDER))
                self.logger.info("🖊️ /enroll: CSR received for subject \(csr.subject.description)") // * added
                
                // Issue client cert using already-loaded server identity's private key
                var certDER: Data
                do {
                    var issuerKey: SecKey?
                    let st = SecIdentityCopyPrivateKey(self.serverIdentity, &issuerKey)
                    guard st == errSecSuccess, let issuerKey = issuerKey else {
                        throw CertificateError.signFailed
                    }
                    certDER = try self.certificateManager.issueClientCertificate(csrDER: csrDER, issuerPrivateKey: issuerKey)
                } catch {
                    // Fallback path: allow CertificateManager to remediate by regenerating CA key if needed
                    self.logger.warning("/enroll: issuer key use failed, trying remediation: \(error.localizedDescription)")
                    certDER = try self.certificateManager.issueClientCertificate(csrDER: csrDER)
                }
                
                // HTTP 200 + DER body (send as one payload) without Content-Length
                var response = Data()
                response.append("HTTP/1.1 200 OK\r\nContent-Type: application/pkix-cert\r\nConnection: close\r\n\r\n".data(using: .utf8)!)
                response.append(certDER)
                conn.send(content: response, completion: .contentProcessed({ _ in
                    self.logger.info("✅ /enroll: cert issued (payload sent)") // * added
                    // After issuing, persist client fingerprint to allowed list for pinning
                    if let fp = self.fingerprintOfDER(certDER) {
                        self.appendAllowedClientFingerprint(fp)
                        self.logger.info("ENROLL: added client fp to allowed list: \(fp)")
                        NotificationCenter.default.post(name: TLSServer.allowedClientsChangedNotification, object: nil)
                        // Flip provisioning -> false if we were in provisioning and the list was empty before
                        if allowed.isEmpty && provisioning == true {
                            self.setProvisioningState(false)
                            self.emitJSON(["event":"pin.provisioning.disabled","ts": ISO8601DateFormatter().string(from: Date()), "role":"tls"])
                        }
                    }
                    // Done with this connection
                    self.activeConns.removeValue(forKey: id)
                }))
                
            } catch {
                let body = "bad request"
                var response = Data()
                // 400 without Content-Length; client reads until close
                response.append("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n".data(using: .utf8)!)
                response.append(body.data(using: .utf8)!)
                conn.send(content: response, completion: .contentProcessed({ _ in
                    self.logger.error("❌ /enroll: \(error.localizedDescription) (payload sent)")
                    // Done with this connection
                    self.activeConns.removeValue(forKey: id)
                }))
            }
        }
    }
    
    // * added: HTTP request parser
    private func readHTTPOnce(from conn: NWConnection, onBody: @escaping (Data) -> Void) {
        // Read request until we have headers, then read body based on Content-Length
        // If Content-Length is missing, read until connection closes (Connection: close)
        func readHeaders(_ accumulated: Data = Data()) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
                guard err == nil, let self = self else { conn.cancel(); return }
                var buf = accumulated
                if let d = data { buf.append(d) }
                if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                    // Headers done
                    let headerData = buf[..<range.lowerBound]
                    let bodyStart = buf[range.upperBound...]
                    let headers = String(data: headerData, encoding: .utf8) ?? ""
                    self.logger.info("ENROLL request headers = \(headers)")
                    let clen = self.contentLength(from: headers)
                    if clen > 0 {
                        if bodyStart.count >= clen {
                            onBody(Data(bodyStart.prefix(clen)))
                        } else {
                            readBodyFixed(soFar: Data(bodyStart), need: clen, onBody: onBody)
                        }
                    } else {
                        // No Content-Length: read until close
                        readBodyUntilClose(soFar: Data(bodyStart), onBody: onBody)
                    }
                } else if isComplete {
                    conn.cancel()
                } else {
                    readHeaders(buf)
                }
            }
        }
        func readBodyFixed(soFar: Data, need: Int, onBody: @escaping (Data) -> Void) {
            if soFar.count >= need { onBody(Data(soFar.prefix(need))); return }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
                var next = soFar
                if let d = data { next.append(d) }
                if isComplete { onBody(next) } else { readBodyFixed(soFar: next, need: need, onBody: onBody) }
            }
        }
        func readBodyUntilClose(soFar: Data, onBody: @escaping (Data) -> Void) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
                var next = soFar
                if let d = data { next.append(d) }
                if isComplete { onBody(next) } else { readBodyUntilClose(soFar: next, onBody: onBody) }
            }
        }
        readHeaders()
    }
    
    // * added: Content-Length parser
    private func contentLength(from headers: String) -> Int {
        for line in headers.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let n = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
                return Int(n) ?? 0
            }
        }
        return 0
    }

    // MARK: - Allowed client pinning helpers
    private func fingerprintOfDER(_ der: Data) -> String? {
        let digest = CryptoKit.SHA256.hash(data: der)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
    private func allowedClientsPath() -> String {
        let path = ("~/.armadillo/allowed_clients.json" as NSString).expandingTildeInPath
        return path
    }
    private func loadAllowedClients() -> [String] {
        let path = allowedClientsPath()
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr
    }
    private func saveAllowedClients(_ arr: [String]) {
        let path = allowedClientsPath()
        do {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            self.logger.error("Failed saving allowed clients: \(error.localizedDescription)")
        }
    }
    private func appendAllowedClientFingerprint(_ fp: String) {
        var arr = loadAllowedClients()
        if !arr.contains(fp) { arr.append(fp); saveAllowedClients(arr) }
    }

    // MARK: - Provisioning state (TOFU hardening)
    private func pinStatePath() -> String {
        return ("~/.armadillo/pin_state.json" as NSString).expandingTildeInPath
    }
    private func loadProvisioningState() -> Bool {
        let path = pinStatePath()
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prov = obj["provisioning"] as? Bool else {
            return false
        }
        return prov
    }
    private func setProvisioningState(_ v: Bool) {
        let path = pinStatePath()
        do {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var obj: [String: Any] = ["provisioning": v]
            let key = v ? "set_at" : "first_enrolled_at"
            obj[key] = ISO8601DateFormatter().string(from: Date())
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            var attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o600))]
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
            if v {
                emitJSON(["event":"pin.provisioning.enabled","ts": ISO8601DateFormatter().string(from: Date()), "role":"tls"])
            }
        } catch {
            logger.error("Failed writing pin_state.json: \(error.localizedDescription)")
        }
    }
    private func emitJSON(_ obj: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    }
}

enum EnrollmentServerError: Error {
    case listenerCreationFailed
}