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
    // Retain active connections during response sending
    private var activeConns: [ObjectIdentifier: NWConnection] = [:]
    
    init(serverIdentity: SecIdentity,
         certificateManager: CertificateManager,
         port: UInt16 = 8444) {
        self.serverIdentity = serverIdentity
        self.certificateManager = certificateManager
        self.port = port
    }
    
    func start() throws {
        let tlsOptions = makeEnrollmentTLSOptions()
        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "EnrollmentServer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        self.listener = listener
        
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("🟢 Enrollment listener READY on :\(self?.port ?? 0)")
            case .failed(let err):
                self?.logger.error("❌ Enrollment listener FAILED: \(err.localizedDescription)")
            case .waiting(let err):
                self?.logger.warning("⏳ Enrollment listener WAITING: \(err.localizedDescription)")
            default:
                break
            }
        }
        
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
    
    private func makeEnrollmentTLSOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        guard let osId = sec_identity_create(serverIdentity) else {
            logger.error("❌ ENROLL: failed to create sec_identity_t")
            preconditionFailure("No server identity for ENROLL")
        }
        sec_protocol_options_set_local_identity(sec, osId)
        var cert: SecCertificate?
        SecIdentityCopyCertificate(serverIdentity, &cert)
        if let cert = cert {
            let der = SecCertificateCopyData(cert) as Data
            let fp = CryptoKit.SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            logger.info("ENROLL leaf fingerprint (sha256) = \(fp)")
        }
        sec_protocol_options_set_peer_authentication_required(sec, false)
        "http/1.1".withCString { sec_protocol_options_add_tls_application_protocol(sec, $0) }
        return options
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        logger.info("Enrollment server stopped")
    }
    
    private func handleConnection(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        readHTTPOnce(from: conn) { [weak self] csrDER in
            guard let self else { return }
            // Debug: dump CSR length and first 64 bytes
            let hex = csrDER.prefix(64).map { String(format: "%02x", $0) }.joined()
            print("/enroll: CSR length=\(csrDER.count) bytes, head64=\(hex)")
            do {
                let csr = try CertificateSigningRequest(derEncoded: Array(csrDER))
                self.logger.info("🖊️ /enroll: CSR received for subject \(csr.subject.description)")
                var certDER: Data
                do {
                    var issuerKey: SecKey?
                    let st = SecIdentityCopyPrivateKey(self.serverIdentity, &issuerKey)
                    guard st == errSecSuccess, let issuerKey = issuerKey else {
                        throw CertificateError.signFailed
                    }
                    certDER = try self.certificateManager.issueClientCertificate(csrDER: csrDER, issuerPrivateKey: issuerKey)
                } catch {
                    self.logger.warning("/enroll: issuer key use failed, trying remediation: \(error.localizedDescription)")
                    certDER = try self.certificateManager.issueClientCertificate(csrDER: csrDER)
                }
                var response = Data()
                response.append("HTTP/1.1 200 OK\r\nContent-Type: application/pkix-cert\r\nConnection: close\r\n\r\n".data(using: .utf8)!)
                response.append(certDER)
                conn.send(content: response, completion: .contentProcessed({ _ in
                    self.logger.info("✅ /enroll: 200 sent (payload)")
                    self.activeConns.removeValue(forKey: id)
                }))
            } catch {
                let body = "bad request"
                var response = Data()
                response.append("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n".data(using: .utf8)!)
                response.append(body.data(using: .utf8)!)
                conn.send(content: response, completion: .contentProcessed({ _ in
                    self.logger.error("❌ /enroll: 400 sent: \(error.localizedDescription)")
                    print("❌ /enroll: 400; error=\(error), csrLen=\(csrDER.count)")
                    self.activeConns.removeValue(forKey: id)
                }))
            }
        }
    }
    
    private func readHTTPOnce(from conn: NWConnection, onBody: @escaping (Data) -> Void) {
        func readHeaders(_ accumulated: Data = Data()) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
                guard err == nil, let self = self else { conn.cancel(); return }
                var buf = accumulated
                if let d = data { buf.append(d) }
                if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buf[..<range.lowerBound]
                    let bodyStart = buf[range.upperBound...]
                    let headers = String(data: headerData, encoding: .utf8) ?? ""
                    self.logger.info("ENROLL request headers = \(headers)")
                    let clen = self.contentLength(from: headers)
                    if clen > 0 {
                        if bodyStart.count >= clen {
                            onBody(Data(bodyStart.prefix(clen)))
                        } else {
                            readBody(soFar: Data(bodyStart), need: clen, onBody: onBody)
                        }
                    } else {
                        readBodyUntilClose(soFar: Data(bodyStart), onBody: onBody)
                    }
                } else if isComplete {
                    conn.cancel()
                } else {
                    readHeaders(buf)
                }
            }
        }
        func readBody(soFar: Data, need: Int, onBody: @escaping (Data) -> Void) {
            if soFar.count >= need { onBody(Data(soFar.prefix(need))); return }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
                var next = soFar
                if let d = data { next.append(d) }
                if isComplete { onBody(next) } else { readBody(soFar: next, need: need, onBody: onBody) }
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
    
    private func contentLength(from headers: String) -> Int {
        for line in headers.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let n = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
                return Int(n) ?? 0
            }
        }
        return 0
    }
}

enum EnrollmentServerError: Error {
    case listenerCreationFailed
}