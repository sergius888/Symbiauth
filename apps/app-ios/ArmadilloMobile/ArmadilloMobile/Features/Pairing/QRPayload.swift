import Foundation

/// QR code payload for pairing
/// Version 1 includes basic pairing data + optional next fingerprint for cert rotation
struct QRPayload: Codable {
    let v: Int                    // Protocol version (1)
    let agent_fp: String         // Current agent certificate fingerprint (sha256:hex)
    let agent_fp_next: String?   // Next fingerprint during rotation (optional, PR2)
    let svc: String              // Service name ("armadillo")
    let name: String             // Device name
    let sid: String              // Session ID
    let exp: TimeInterval        // Expiration timestamp
    let fallback: String?        // Optional fallback URL
    
    enum CodingKeys: String, CodingKey {
        case v
        case agent_fp
        case agent_fp_next
        case svc
        case name
        case sid
        case exp
        case fallback
    }
    
    /// Parse QR code content into payload
    static func parse(from qrContent: String) throws -> QRPayload {
        guard let data = qrContent.data(using: .utf8) else {
            throw QRPayloadError.invalidEncoding
        }
        
        do {
            let payload = try JSONDecoder().decode(QRPayload.self, from: data)
            
            // Validate version
            guard payload.v == 1 else {
                throw QRPayloadError.unsupportedVersion(payload.v)
            }
            
            // Check expiration
            guard payload.exp > Date().timeIntervalSince1970 else {
                throw QRPayloadError.expired
            }
            
            // Validate fingerprint format
            guard payload.agent_fp.hasPrefix("sha256:") && payload.agent_fp.count == 71 else {
                throw QRPayloadError.invalidFingerprint
            }
            
            return payload
        } catch let decodingError as DecodingError {
            throw QRPayloadError.invalidFormat(decodingError.localizedDescription)
        }
    }
    
    /// Extract fallback host and port if available
    var fallbackEndpoint: (host: String, port: UInt16)? {
        guard let fallback = fallback else { return nil }
        
        let components = fallback.split(separator: ":")
        guard components.count == 2,
              let host = components.first,
              let portString = components.last,
              let port = UInt16(portString) else {
            return nil
        }
        
        return (host: String(host), port: port)
    }
}

enum QRPayloadError: LocalizedError {
    case invalidEncoding
    case invalidFormat(String)
    case unsupportedVersion(Int)
    case expired
    case invalidFingerprint
    
    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "QR code contains invalid text encoding"
        case .invalidFormat(let details):
            return "QR code format is invalid: \(details)"
        case .unsupportedVersion(let version):
            return "Unsupported QR code version: \(version)"
        case .expired:
            return "QR code has expired"
        case .invalidFingerprint:
            return "Invalid agent fingerprint format"
        }
    }
}