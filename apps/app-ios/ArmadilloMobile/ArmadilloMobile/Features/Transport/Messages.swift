import Foundation

// MARK: - Base Message Protocol

protocol ArmadilloMessage: Codable {
    var type: String { get }
    var v: Int { get }
}

// MARK: - Ping/Pong Messages

struct PingMessage: ArmadilloMessage {
    let type = "ping"
    let v = 1
    let timestamp: TimeInterval
    
    init() {
        self.timestamp = Date().timeIntervalSince1970
    }
}

struct PongMessage: ArmadilloMessage {
    let type = "pong"
    let v: Int
    let timestamp: TimeInterval
    let originalTimestamp: TimeInterval?
}

// MARK: - Pairing Messages

struct PairingRequestMessage: ArmadilloMessage {
    let type = "pairing_request"
    let v = 1
    let sessionId: String
    let clientFingerprint: String
    let deviceName: String
}

struct PairingResponseMessage: ArmadilloMessage {
    let type = "pairing_response"
    let v: Int
    let sessionId: String
    let success: Bool
    let error: String?
    let sasCode: String?
}

struct PairingConfirmMessage: ArmadilloMessage {
    let type = "pairing_confirm"
    let v = 1
    let sessionId: String
    let confirmed: Bool
}

// MARK: - Error Message

struct ErrorMessage: ArmadilloMessage {
    let type = "error"
    let v: Int
    let code: String
    let message: String
}

// MARK: - Message Factory

enum MessageFactory {
    static func decode(from data: Data) throws -> ArmadilloMessage {
        // First, decode as generic JSON to check the type
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let messageType = json?["type"] as? String else {
            throw MessageError.missingType
        }
        
        // Decode based on type
        switch messageType {
        case "ping":
            return try JSONDecoder().decode(PingMessage.self, from: data)
        case "pong":
            return try JSONDecoder().decode(PongMessage.self, from: data)
        case "pairing_request":
            return try JSONDecoder().decode(PairingRequestMessage.self, from: data)
        case "pairing_response":
            return try JSONDecoder().decode(PairingResponseMessage.self, from: data)
        case "pairing_confirm":
            return try JSONDecoder().decode(PairingConfirmMessage.self, from: data)
        case "error":
            return try JSONDecoder().decode(ErrorMessage.self, from: data)
        default:
            throw MessageError.unknownType(messageType)
        }
    }
}

enum MessageError: LocalizedError {
    case missingType
    case unknownType(String)
    
    var errorDescription: String? {
        switch self {
        case .missingType:
            return "Message missing type field"
        case .unknownType(let type):
            return "Unknown message type: \(type)"
        }
    }
}