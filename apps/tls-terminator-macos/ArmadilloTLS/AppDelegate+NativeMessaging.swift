import Cocoa
import Foundation

// MARK: - Native Messaging Host install support

private enum NativeMessagingInstallerError: LocalizedError {
    case missingExtensionID
    case hostBinaryMissing(String)
    
    var errorDescription: String? {
        switch self {
        case .missingExtensionID:
            return "Set ARM_WEBEXT_DEV_ID or ~/.armadillo/dev_extension_id.txt before installing the browser bridge."
        case .hostBinaryMissing(let path):
            return "Native host binary not found at \(path). Build armadillo-nmhost and bundle it into the app."
        }
    }
}

private struct NativeHostManifest: Codable {
    let name: String
    let description: String
    let path: String
    let type: String
    let allowed_origins: [String]
}

extension AppDelegate {
    
    func ensureNativeMessagingManifestInstalled() {
        do {
            try installNativeMessagingHostManifest()
        } catch NativeMessagingInstallerError.missingExtensionID {
            logger.info("Skipping NM host install: missing extension ID")
        } catch {
            logger.error("Failed to install NM host manifest: \(error.localizedDescription)")
        }
    }
    
    @objc func installBrowserBridge() {
        do {
            try installNativeMessagingHostManifest()
            logger.info("Browser bridge manifest installed or repaired")
        } catch {
            logger.error("Browser bridge install failed: \(error.localizedDescription)")
        }
    }
    
    @objc func removeBrowserBridge() {
        do {
            try removeNativeMessagingHostManifest()
            logger.info("Browser bridge manifest removed")
        } catch {
            logger.error("Failed to remove browser bridge manifest: \(error.localizedDescription)")
        }
    }
    
    private func installNativeMessagingHostManifest() throws {
        guard let extensionId = resolveNativeMessagingExtensionID() else {
            throw NativeMessagingInstallerError.missingExtensionID
        }
        let hostPath = nativeMessagingHostPath()
        guard FileManager.default.isExecutableFile(atPath: hostPath) else {
            throw NativeMessagingInstallerError.hostBinaryMissing(hostPath)
        }
        let manifestDir = nativeMessagingManifestDirectory()
        try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        let manifest = NativeHostManifest(
            name: "com.armadillo.nmhost",
            description: "Armadillo Native Host (dev)",
            path: hostPath,
            type: "stdio",
            allowed_origins: ["chrome-extension://\(extensionId)/"]
        )
        let data = try JSONEncoder().encode(manifest)
        let manifestURL = manifestDir.appendingPathComponent("com.armadillo.nmhost.json")
        try data.write(to: manifestURL, options: .atomic)
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o600))]
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: manifestURL.path)
    }
    
    private func removeNativeMessagingHostManifest() throws {
        let manifestURL = nativeMessagingManifestDirectory().appendingPathComponent("com.armadillo.nmhost.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            try FileManager.default.removeItem(at: manifestURL)
        }
    }
    
    private func resolveNativeMessagingExtensionID() -> String? {
        if let envID = ProcessInfo.processInfo.environment["ARM_WEBEXT_DEV_ID"], !envID.isEmpty {
            return envID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let devFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".armadillo")
            .appendingPathComponent("dev_extension_id.txt")
        if let contents = try? String(contentsOf: devFile).trimmingCharacters(in: .whitespacesAndNewlines),
           !contents.isEmpty {
            return contents
        }
        return nil
    }
    
    private func nativeMessagingManifestDirectory() -> URL {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    
    private func nativeMessagingHostPath() -> String {
        let bundlePath = Bundle.main.bundlePath
        return "\(bundlePath)/Contents/MacOS/armadillo-nmhost"
    }
}
