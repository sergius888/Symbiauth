import Foundation

enum AppGroup {
    static let id = "group.com.armadillo"
    
    static func socketPath() throws -> String {
        // Try App Group container first (when sandbox is enabled)
        if let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            let ipcDir = base.appendingPathComponent("ipc", isDirectory: true)
            try FileManager.default.createDirectory(at: ipcDir, withIntermediateDirectories: true)
            let sock = ipcDir.appendingPathComponent("a.sock", isDirectory: false)
            // Ensure old socket is gone before bind()
            unlink(sock.path)
            return sock.path
        }
        
        // Fallback to user's home directory when App Group is not available
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let armadilloDir = homeDir.appendingPathComponent(".armadillo", isDirectory: true)
        try FileManager.default.createDirectory(at: armadilloDir, withIntermediateDirectories: true)
        let sock = armadilloDir.appendingPathComponent("a.sock", isDirectory: false)
        // Ensure old socket is gone before bind()
        unlink(sock.path)
        return sock.path
    }
}