import AppKit
import Combine
import CryptoKit
import Foundation
import Security

final class PreferencesViewModel: ObservableObject {
    struct LauncherRow: Identifiable {
        let id: String
        let name: String
        let description: String
        let execPath: String
        let args: [String]
        let cwd: String
        let secretRefs: [String]
        let enabled: Bool
        let running: Bool
        let trustPolicy: String
        let singleInstance: Bool
        let lastError: String?
    }

    struct LauncherTemplateRow: Identifiable {
        let id: String
        let name: String
        let description: String
        let execPath: String
        let args: [String]
        let cwd: String
        let secretRefs: [String]
        let trustPolicy: String

        var summary: String {
            if args.isEmpty {
                return execPath
            }
            return ([execPath] + args).joined(separator: " ")
        }

        var requirementLabel: String? {
            switch id {
            case "local-port-forward":
                return "Requires unattended SSH auth"
            case "kubectl-port-forward":
                return "Requires working kube context"
            default:
                return nil
            }
        }
    }

    struct SecretRow: Identifiable {
        let name: String
        let available: Bool
        let usedBy: [String]
        let status: String
        let createdAt: Date?

        var id: String { name }
    }

    struct TrustDiagnostics {
        let state: String
        let mode: String
        let trustId: String
        let deadlineMs: UInt64?
        let event: String
        let reason: String
    }

    struct SessionHistoryEntry: Identifiable, Codable {
        enum Category: String, Codable {
            case trust
            case session
        }

        var id: UUID = UUID()
        let timestamp: Date
        let category: Category
        let title: String
        let detail: String
    }

    @Published var diagnostics = TrustDiagnostics(
        state: "unknown",
        mode: "background_ttl",
        trustId: "none",
        deadlineMs: nil,
        event: "none",
        reason: ""
    )
    @Published var launcherCount: Int = 0
    @Published var runningLaunchers: Int = 0
    @Published var availableSecrets: Int = 0
    @Published var missingSecrets: Int = 0
    @Published var lastRefreshAt: Date?
    @Published var lastError: String?
    @Published var launcherRows: [LauncherRow] = []
    @Published var launcherTemplateRows: [LauncherTemplateRow] = []
    @Published var selectedLauncherId: String?
    @Published var selectedTemplateId: String?
    @Published var draftLauncherId: String = ""
    @Published var draftLauncherName: String = ""
    @Published var draftLauncherDescription: String = ""
    @Published var draftLauncherExecPath: String = "/bin/zsh"
    @Published var draftLauncherArgsCsv: String = ""
    @Published var draftLauncherCwd: String = ""
    @Published var draftLauncherSecretRefsCsv: String = ""
    @Published var draftLauncherEnabled: Bool = true
    @Published var draftLauncherSingleInstance: Bool = true
    @Published var draftLauncherTrustPolicy: String = "continuous"
    @Published var launcherActionStatus: String?
    @Published var settingsMode: String = "background_ttl"
    @Published var settingsBackgroundTTL: String = "300"
    @Published var settingsOfficeIdle: String = "900"
    @Published var settingsPresenceTimeout: String = "12"
    @Published var settingsStatus: String?
    @Published var secretRows: [SecretRow] = []
    @Published var selectedSecretName: String?
    @Published var draftSecretName: String = ""
    @Published var draftSecretValue: String = ""
    @Published var secretActionStatus: String?
    @Published var sessionHistory: [SessionHistoryEntry] = []
    @Published var chamberCategory: ChamberCategory = .secrets
    @Published var chamberPanelCategory: ChamberCategory?
    @Published var chamberSearchVisible: Bool = false
    @Published var chamberSearchText: String = ""
    @Published var chamberFilterVisible: Bool = false
    @Published var chamberSelectedTagFilter: String?
    @Published var selectedChamberItemId: String?
    @Published var chamberStoredItems: [ChamberStoredItem] = []
    @Published var revealedSecretValues: [String: String] = [:]
    @Published var chamberActionStatus: String?
    @Published var showingChamberEditor: Bool = false
    @Published var chamberDraft = ChamberDraft()
    @Published var chamberDraftError: String?
    @Published var protectedClipboardActive: Bool = false
    @Published var trustedShellExecutable: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    @Published var trustedShellWorkingDirectory: String = NSHomeDirectory()
    @Published var trustedShellGuardMode: String = "strict"
    @Published var trustedShellBackgroundTTL: String = "120"
    @Published var trustedShellLive: Bool = false
    @Published var trustedShellStatus: String?
    @Published var trustedShellInjectedSecrets: [String] = []
    @Published var trustedShellTranscript: String = ""
    @Published var trustedShellInput: String = ""
    @Published var trustedShellExpanded: Bool = false
    @Published var trustedShellInjectVisible: Bool = false
    @Published var trustedShellInjectSearch: String = ""
    @Published var trustedShellInjectSelection: Set<String> = []

    let sendToAgent: ([String: Any], @escaping ([String: Any]) -> Void) -> Void
    let trustSnapshotProvider: () -> BLETrustCentral.TrustStateSnapshot?
    var lastObservedTrustEventSignature: String?
    var lastRevocationContext: (timestamp: Date, reason: String)?
    let sessionHistoryURL: URL
    let chamberItemsURL: URL
    let chamberMetadataURL: URL
    var protectedClipboardValue: String?
    var temporaryExportURLs: [URL] = []
    let chamberStorageService = "com.symbiauth.chamber.storage"
    let chamberStorageAccount = "default"
    var chamberMetadata = ChamberPresentationMetadata()
    var chamberStatusClearWorkItem: DispatchWorkItem?
    var clipboardBadgeClearWorkItem: DispatchWorkItem?
    var trustedShellProcess: Process?
    var trustedShellOutputPipe: Pipe?
    var trustedShellInputPipe: Pipe?
    var trustedShellPendingEscapeFragment: String = ""
    var trustedShellSuppressedTranscriptLines: [String] = []
    var trustedShellOutputBuffer: String = ""
    var trustedShellCommandHistory: [String] = []
    var trustedShellHistoryIndex: Int?
    var trustedShellHistoryDraft: String = ""
    var trustedShellCurrentDirectory: String = NSHomeDirectory()

    init(
        sendToAgent: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void,
        trustSnapshotProvider: @escaping () -> BLETrustCentral.TrustStateSnapshot?
    ) {
        self.sendToAgent = sendToAgent
        self.trustSnapshotProvider = trustSnapshotProvider
        let historyDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".armadillo", isDirectory: true)
        self.sessionHistoryURL = historyDir.appendingPathComponent("managed_session_history.json")
        self.chamberItemsURL = historyDir.appendingPathComponent("chamber_items.json")
        self.chamberMetadataURL = historyDir.appendingPathComponent("chamber_metadata.json")
        let rawPresence = ProcessInfo.processInfo.environment["ARM_TRUST_PRESENCE_TIMEOUT_SECS"]
            .flatMap(UInt64.init) ?? 12
        let clampedPresence = min(max(rawPresence, 5), 60)
        self.settingsPresenceTimeout = String(clampedPresence)
        loadPersistedSessionHistory()
        loadPersistedChamberItems()
        loadPersistedChamberMetadata()
    }

    var hasActiveTrust: Bool {
        let trustId = diagnostics.trustId.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trustId.isEmpty && trustId != "none"
    }

    var chamberTrustStateLabel: String {
        if hasActiveTrust { return "Trusted" }
        return "Locked"
    }

    var settingsModeLabel: String {
        switch settingsMode.lowercased() {
        case "strict":
            return "Strict"
        case "office":
            return "Office"
        case "background_ttl":
            return "Background TTL"
        default:
            return settingsMode.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    func refresh() {
        refreshTrust()
        refreshLaunchers()
        refreshLauncherTemplates()
        refreshSecrets()
        refreshTrustConfig()
    }

    func refreshTrustStateOnly() {
        refreshTrust()
    }

    func refreshChamberData() {
        refreshSecrets()
    }

    func setChamberStatus(_ message: String?, autoClearAfter seconds: TimeInterval? = 4) {
        chamberStatusClearWorkItem?.cancel()
        chamberActionStatus = message
        guard let seconds, message != nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.chamberActionStatus == message {
                self.chamberActionStatus = nil
            }
        }
        chamberStatusClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

}
