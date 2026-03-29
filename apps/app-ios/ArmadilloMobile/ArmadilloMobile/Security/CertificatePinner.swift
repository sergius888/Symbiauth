import Foundation
import Security
import CryptoKit

/// Certificate pinner that validates server certificates against pinned fingerprints
/// Supports dual-pin mode during certificate rotation (current + next)
final class CertificatePinner {
    private let currentFingerprint: String
    private let nextFingerprint: String?
    
    /// Initialize with current fingerprint and optional next fingerprint for rotation
    /// - Parameters:
    ///   - current: Current certificate fingerprint (format: "sha256:hex")
    ///   - next: Next certificate fingerprint during rotation (optional)
    init(current: String, next: String? = nil) {
        self.currentFingerprint = current
        self.nextFingerprint = next
    }
    
    /// Validates that server certificate matches current OR next fingerprint
    /// - Parameter serverCert: Server certificate from TLS handshake
    /// - Returns: true if certificate matches current or next, false otherwise
    func validate(_ serverCert: SecCertificate) -> Bool {
        let serverFingerprint = sha256Fingerprint(serverCert)
        
        // Accept if matches current
        if serverFingerprint == currentFingerprint {
            return true
        }
        
        // Accept if matches next (during rotation)
        if let next = nextFingerprint, serverFingerprint == next {
            return true
        }
        
        // Reject unknown certificate
        return false
    }
    
    /// Computes SHA-256 fingerprint of certificate in format "sha256:hex"
    /// - Parameter cert: Certificate to fingerprint
    /// - Returns: Fingerprint string (e.g., "sha256:abc123...")
    private func sha256Fingerprint(_ cert: SecCertificate) -> String {
        // Get DER-encoded certificate data
        guard let certData = SecCertificateCopyData(cert) as Data? else {
            return ""
        }
        
        // Compute SHA-256 hash
        let hash = SHA256.hash(data: certData)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        
        return "sha256:\(hashHex)"
    }
}
