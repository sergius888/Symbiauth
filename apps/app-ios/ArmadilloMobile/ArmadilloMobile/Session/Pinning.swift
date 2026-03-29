import Foundation
import Security
import CryptoKit

enum Pinning {
    /// Verify server certificate against expected fingerprint
    static func verify(trust: sec_trust_t, expectedFingerprint: String) -> Bool {
        guard let cert = SecTrustGetCertificateAtIndex(trust as! SecTrust, 0) else {
            ArmadilloLogger.security.error("Failed to get certificate from trust")
            return false
        }
        
        let der = SecCertificateCopyData(cert) as Data
        let hash = SHA256.hash(data: der)
        let fingerprint = "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
        
        let isValid = fingerprint.caseInsensitiveCompare(expectedFingerprint) == .orderedSame
        
        if isValid {
            ArmadilloLogger.security.info("Certificate fingerprint verified successfully")
        } else {
            ArmadilloLogger.security.error("Certificate fingerprint mismatch")
            ArmadilloLogger.logSensitive("Expected: \(expectedFingerprint)", logger: ArmadilloLogger.security)
            ArmadilloLogger.logSensitive("Actual: \(fingerprint)", logger: ArmadilloLogger.security)
        }
        
        return isValid
    }
    
    /// Get fingerprint of a certificate
    static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        let hash = SHA256.hash(data: der)
        return "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
    }
}