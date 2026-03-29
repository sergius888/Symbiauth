import Foundation
import CryptoKit

enum SAS {
    /// Derive Short Authentication String from TLS connection
    /// Uses TLS Exporter with label "EXPORTER_Armadillo_SAS_v1"
    static func derive(from connection: Any, sessionId: String) -> String {
        // TODO: Implement TLS exporter when Network.framework exposes it
        // For now, generate a deterministic code based on session ID for testing
        
        if Env.isDev {
            // Development mode: generate deterministic SAS from session ID
            return generateTestSAS(sessionId: sessionId)
        } else {
            // Production: would use actual TLS exporter
            // return deriveTLSExporter(connection, sessionId)
            return generateTestSAS(sessionId: sessionId)
        }
    }
    
    /// Generate test SAS for development (deterministic based on session ID)
    private static func generateTestSAS(sessionId: String) -> String {
        let data = sessionId.data(using: .utf8) ?? Data()
        let hash = SHA256.hash(data: data)
        
        // Take first 4 bytes and convert to 6-digit number
        let bytes = Array(hash.prefix(4))
        let value = bytes.reduce(0) { result, byte in
            (result << 8) | UInt32(byte)
        }
        
        // Convert to 6-digit string (000000-999999)
        let sasCode = String(format: "%06d", value % 1000000)
        
        ArmadilloLogger.security.info("Generated SAS code for session")
        ArmadilloLogger.logSensitive("SAS: \(sasCode) for session: \(sessionId)")
        
        return sasCode
    }
    
    /// Format SAS code for display (XXX-XXX)
    static func format(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let index = code.index(code.startIndex, offsetBy: 3)
        return String(code[..<index]) + "-" + String(code[index...])
    }
}