import Foundation
import Security
import CryptoKit

class PairedAgentStore {
    private let keychain = Keychain()
    private let defaults = UserDefaults.standard
    private let lastAgentKey = "paired-agent-last"
    
    /// Generate or retrieve client identity for pairing
    /// For MVP, we'll create a simplified version that works without Secure Enclave
    func getOrCreateClientIdentity() throws -> SecIdentity {
        // For MVP, we'll generate a simple P-256 key pair and create a basic identity
        // This will be enhanced with proper swift-certificates integration later
        
        ArmadilloLogger.security.info("Creating simplified client identity for MVP")
        
        // Generate a P-256 private key
        // let privateKey = P256.Signing.PrivateKey()
        
        // For MVP, we'll create a mock SecIdentity
        // In production, this would use swift-certificates to create proper X.509 certificates
        throw KeyGenerationError.certificateCreationFailed // Temporary - will implement proper version
    }
    
    /// Get fingerprint of client certificate
    func getClientFingerprint() throws -> String {
        // For MVP, return a mock fingerprint
        // In production, this would extract the actual certificate fingerprint
        let mockFingerprint = "sha256:" + String(repeating: "ab", count: 32)
        ArmadilloLogger.security.info("Using mock client fingerprint for MVP")
        return mockFingerprint
    }
    
    /// Store paired agent information
    func storePairedAgent(fingerprint: String, name: String, sessionId: String) throws {
        let agentInfo = PairedAgentInfo(
            fingerprint: fingerprint,
            name: name,
            sessionId: sessionId,
            pairedAt: Date(),
            lastSeen: Date()
        )
        
        let data = try JSONEncoder().encode(agentInfo)
        try keychain.storeData(data, label: "paired-agent-\(fingerprint)")
        
        ArmadilloLogger.security.info("Stored paired agent info")
    }
    
    /// Retrieve paired agent information
    func getPairedAgent(fingerprint: String) throws -> PairedAgentInfo? {
        guard let data = try? keychain.getData(label: "paired-agent-\(fingerprint)") else {
            return nil
        }
        
        return try JSONDecoder().decode(PairedAgentInfo.self, from: data)
    }
    
    // MARK: - Last Agent Endpoint (UserDefaults)
    
    struct LastAgentEndpoint: Codable {
        let host: String
        let port: UInt16
        let fingerprint: String
        let name: String
    }
    
    func saveLastAgentEndpoint(host: String, port: UInt16, fingerprint: String, name: String) {
        let info = LastAgentEndpoint(host: host, port: port, fingerprint: fingerprint, name: name)
        if let data = try? JSONEncoder().encode(info) {
            defaults.set(data, forKey: lastAgentKey)
            ArmadilloLogger.security.info("Saved last agent endpoint: \(host):\(port)")
        }
    }
    
    func loadLastAgentEndpoint() -> LastAgentEndpoint? {
        guard let data = defaults.data(forKey: lastAgentKey) else { return nil }
        return try? JSONDecoder().decode(LastAgentEndpoint.self, from: data)
    }
    
    func clearLastAgentEndpoint() {
        defaults.removeObject(forKey: lastAgentKey)
    }
}

struct PairedAgentInfo: Codable {
    let fingerprint: String
    let name: String
    let sessionId: String
    let pairedAt: Date
    var lastSeen: Date
}

enum KeyGenerationError: LocalizedError {
    case keyGenerationFailed
    case secureEnclaveError(Error)
    case publicKeyExtractionFailed
    case certificateCreationFailed
    case certificateExtractionFailed
    
    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Failed to generate cryptographic key"
        case .secureEnclaveError(let error):
            return "Secure Enclave error: \(error.localizedDescription)"
        case .publicKeyExtractionFailed:
            return "Failed to extract public key"
        case .certificateCreationFailed:
            return "Certificate creation not implemented in MVP - will be added with swift-certificates"
        case .certificateExtractionFailed:
            return "Failed to extract certificate from identity"
        }
    }
}

// MARK: - Keychain Helper

private class Keychain {
    func storeData(_ data: Data, label: String) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: label,
            kSecValueData as String: data
        ]
        
        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: label
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Item already exists, which is fine for MVP
            return
        }
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }
    
    func getData(label: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: label,
            kSecReturnData as String: true
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            throw KeychainError.notFound
        }
        
        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }
        
        return data
    }
}

enum KeychainError: LocalizedError {
    case storeFailed(OSStatus)
    case notFound
    case invalidData
    
    var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            return "Keychain store failed with status: \(status)"
        case .notFound:
            return "Item not found in keychain"
        case .invalidData:
            return "Invalid data retrieved from keychain"
        }
    }
}