import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var devMode: Bool { didSet { d.set(devMode, forKey: "ARM_DEV_MODE") } }
    @Published var jsonLogs: Bool { didSet { d.set(jsonLogs, forKey: "ARM_JSON_LOG") } }
    @Published var redactLogs: Bool { didSet { d.set(redactLogs, forKey: "ARM_LOG_REDACT") } }
    @Published var autoConnectEnabled: Bool { didSet { d.set(autoConnectEnabled, forKey: "auto_connect_enabled") } }
    @Published var blePresence: Bool { didSet { d.set(blePresence, forKey: "ARM_FEATURE_BLE") } }

    private init() {
        devMode = d.bool(forKey: "ARM_DEV_MODE")
        jsonLogs = d.bool(forKey: "ARM_JSON_LOG")
        redactLogs = d.bool(forKey: "ARM_LOG_REDACT")
        autoConnectEnabled = d.object(forKey: "auto_connect_enabled") as? Bool ?? true
        blePresence = d.bool(forKey: "ARM_FEATURE_BLE")
    }
}


