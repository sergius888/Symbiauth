#!/usr/bin/env swift
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

do {
    let path = try AppGroup.socketPath()
    print("Socket path: \(path)")
    print("Path length: \(path.count) characters")
    
    // Check if directory exists
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    print("Directory: \(dir.path)")
    print("Directory exists: \(FileManager.default.fileExists(atPath: dir.path))")
} catch {
    print("Error: \(error)")
}