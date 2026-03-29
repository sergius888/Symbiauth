import Foundation
import os.log

enum ArmadilloLogger {
    private static let subsystem = "com.armadillo"
    
    static let pairing = Logger(subsystem: subsystem, category: "pairing")
    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let discovery = Logger(subsystem: subsystem, category: "bonjour")
    static let security = Logger(subsystem: subsystem, category: "security")
    
    /// Log sensitive data only in development builds
    static func logSensitive(_ message: String, logger: Logger = Logger()) {
        if Env.isDev {
            logger.debug("\(message, privacy: .private)")
        }
    }
}

struct LogContext {
    let role: String   // ios | tls | agent
    let cat: String    // transport | tls | uds | bonjour | pairing | security | enroll
    let sid: String?
    let conn: String?
    let fpSuffix: String?
    
    init(role: String, cat: String, sid: String? = nil, conn: String? = nil, fpSuffix: String? = nil) {
        self.role = role
        self.cat = cat
        self.sid = sid
        self.conn = conn
        self.fpSuffix = fpSuffix
    }
    
    func prefix() -> String {
        var parts: [String] = ["role=\(role)", "cat=\(cat)"]
        if let sid = sid, !sid.isEmpty { parts.append("sid=\(sid)") }
        if let conn = conn, !conn.isEmpty { parts.append("conn=\(conn)") }
        if let fp = fpSuffix, !fp.isEmpty { parts.append("fp_suffix=\(fp)") }
        return "[" + parts.joined(separator: " ") + "] "
    }
}

enum ConnID {
    static func new() -> String {
        // 6-char base36 from random 32-bit
        let rng = UInt32.random(in: 0..<UInt32.max)
        let s = String(rng, radix: 36, uppercase: false)
        return String(s.suffix(6))
    }
}