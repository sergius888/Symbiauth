import Foundation

struct FramedCodec {
    /// Encode JSON message with length prefix
    static func encode(json: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json, options: [])
        
        guard body.count <= Env.maxFrameSize else {
            throw FramedCodecError.frameTooLarge(body.count)
        }
        
        // 4-byte big-endian length prefix
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        
        return frame
    }
    
    /// Encode Codable message with length prefix
    static func encode<T: Codable>(_ message: T) throws -> Data {
        let body = try JSONEncoder().encode(message)
        
        guard body.count <= Env.maxFrameSize else {
            throw FramedCodecError.frameTooLarge(body.count)
        }
        
        // 4-byte big-endian length prefix
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        
        return frame
    }
    
    /// Decode length from frame header
    static func decodeLength(from data: Data) throws -> UInt32 {
        guard data.count >= 4 else {
            throw FramedCodecError.insufficientData
        }
        
        let length = data.prefix(4).withUnsafeBytes { bytes in
            return UInt32(bigEndian: bytes.load(as: UInt32.self))
        }
        
        guard length > 0 && length <= Env.maxFrameSize else {
            throw FramedCodecError.invalidFrameLength(length)
        }
        
        return length
    }
    
    /// Decode JSON message from frame body
    static func decodeJSON(from data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw FramedCodecError.invalidJSON
        }
        
        return json
    }
    
    /// Decode Codable message from frame body
    static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        return try JSONDecoder().decode(type, from: data)
    }
}

enum FramedCodecError: LocalizedError {
    case frameTooLarge(Int)
    case insufficientData
    case invalidFrameLength(UInt32)
    case invalidJSON
    
    var errorDescription: String? {
        switch self {
        case .frameTooLarge(let size):
            return "Frame size \(size) exceeds maximum \(Env.maxFrameSize)"
        case .insufficientData:
            return "Insufficient data for frame header"
        case .invalidFrameLength(let length):
            return "Invalid frame length: \(length)"
        case .invalidJSON:
            return "Invalid JSON in frame body"
        }
    }
}