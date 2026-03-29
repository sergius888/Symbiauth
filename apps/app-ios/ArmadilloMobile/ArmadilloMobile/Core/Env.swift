import Foundation

enum Env {
    /// Development mode flag - allows self-signed certs and relaxed validation
    static let isDev = (Bundle.main.object(forInfoDictionaryKey: "ARM_DEV") as? String) == "1"
    
    /// ALPN protocol identifier
    static let alpn = "armadillo/1.0"
    
    /// Maximum frame size for protocol messages
    static let maxFrameSize = 65536 // 64 KiB
    
    /// Connection timeout
    static let connectTimeout: TimeInterval = 10.0
    
    /// Request timeout
    static let requestTimeout: TimeInterval = 3.0
    
    /// Bonjour service type
    static let bonjourServiceType = "_armadillo._tcp."
    
    /// JSON logging toggle: Settings.bundle (UserDefaults) or Info.plist fallback
    static var jsonLogs: Bool {
        let defaults = UserDefaults.standard.bool(forKey: "ARM_JSON_LOG")
        if defaults { return true }
        return (Bundle.main.object(forInfoDictionaryKey: "ARM_JSON_LOG") as? String) == "1"
    }
    
    /// Redact sensitive fields in logs: Settings.bundle (UserDefaults) or Info.plist fallback
    static var redactLogs: Bool {
        if UserDefaults.standard.object(forKey: "ARM_LOG_REDACT") != nil {
            return UserDefaults.standard.bool(forKey: "ARM_LOG_REDACT")
        }
        return (Bundle.main.object(forInfoDictionaryKey: "ARM_LOG_REDACT") as? String) == "1"
    }
}