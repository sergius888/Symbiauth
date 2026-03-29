import AppKit
import CryptoKit
import Foundation
import Security

extension PreferencesViewModel {
    private var allChamberItems: [ChamberItem] {
        let secretItems = secretRows.map { row in
            let config = chamberMetadata.secretConfigurations[row.name] ?? SecretPresentationConfiguration()
            let displayTitle = config.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChamberItem(
                id: "secret:\(row.name)",
                kind: .secret,
                title: (displayTitle?.isEmpty == false ? displayTitle! : row.name),
                note: row.status,
                tags: chamberMetadata.secretTags[row.name] ?? [],
                favorite: chamberMetadata.favoriteSecretNames.contains(row.name),
                createdAt: Date.distantPast,
                updatedAt: row.createdAt ?? Date.distantPast,
                lastOpenedAt: chamberMetadata.recentSecretAccess[row.name],
                secretName: row.name,
                secretType: config.type,
                secretAvailableInShell: config.availableInShell,
                secretAvailable: row.available,
                secretStatus: row.status,
                secretUsedBy: row.usedBy,
                textContent: nil,
                textFormat: nil,
                fileName: nil,
                mimeType: nil,
                fileData: nil,
                fileSize: nil
            )
        }

        let storedItems = chamberStoredItems.map { item in
            ChamberItem(
                id: "\(item.kind.rawValue):\(item.id.uuidString)",
                kind: item.kind == .document ? .document : .note,
                title: item.title,
                note: item.note,
                tags: item.tags,
                favorite: item.favorite,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                lastOpenedAt: item.lastOpenedAt,
                secretName: nil,
                secretType: nil,
                secretAvailableInShell: false,
                secretAvailable: true,
                secretStatus: nil,
                secretUsedBy: [],
                textContent: item.body,
                textFormat: item.format,
                fileName: item.fileName,
                mimeType: item.mimeType,
                fileData: item.fileData,
                fileSize: item.fileSize
            )
        }

        return secretItems + storedItems
    }

    var chamberItems: [ChamberItem] {
        let base = allChamberItems
        let activeTag = chamberSelectedTagFilter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filtered = base.filter { item in
            let categoryMatch: Bool = {
                switch chamberPanelCategory ?? chamberCategory {
                case .all:
                    return true
                case .favorites:
                    return item.favorite
                default:
                    return item.category == chamberCategory
                }
            }()

            guard categoryMatch else { return false }
            if let activeTag, !activeTag.isEmpty {
                guard item.tags.contains(where: { $0.lowercased() == activeTag }) else { return false }
            }
            return true
        }

        return filtered.sorted { lhs, rhs in
            let leftDate = lhs.lastOpenedAt ?? lhs.updatedAt
            let rightDate = rhs.lastOpenedAt ?? rhs.updatedAt
            if chamberCategory == .favorites {
                return leftDate > rightDate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var chamberSearchResults: [ChamberItem] {
        let query = chamberSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let activeTag = chamberSelectedTagFilter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return allChamberItems.filter { item in
            if let activeTag, !activeTag.isEmpty,
               !item.tags.contains(where: { $0.lowercased() == activeTag }) {
                return false
            }
            if query.isEmpty {
                return activeTag?.isEmpty == false
            }
            let haystack = [
                item.title,
                item.note,
                item.tags.joined(separator: " "),
                item.secretName ?? "",
                item.fileName ?? "",
                item.textContent ?? ""
            ]
            .joined(separator: " ")
            .lowercased()
            return haystack.contains(query)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var availableFilterTags: [String] {
        let source: [ChamberItem]
        if chamberSearchVisible {
            source = allChamberItems
        } else {
            source = allChamberItems.filter { item in
                switch chamberPanelCategory ?? chamberCategory {
                case .favorites:
                    return item.favorite
                case .all:
                    return true
                default:
                    return item.category == chamberCategory
                }
            }
        }
        let tags = Set(
            source
                .flatMap(\.tags)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var trustedShellEligibleSecrets: [SecretRow] {
        secretRows
            .filter { row in
                let config = chamberMetadata.secretConfigurations[row.name] ?? SecretPresentationConfiguration()
                return config.availableInShell
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var trustedShellFilteredSecrets: [SecretRow] {
        let query = trustedShellInjectSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return trustedShellEligibleSecrets }
        return trustedShellEligibleSecrets.filter { row in
            let config = chamberSecretConfiguration(for: row.name)
            let title = chamberSecretDisplayTitle(for: row.name)
            let haystack = [
                row.name,
                title,
                config.type,
                (chamberMetadata.secretTags[row.name] ?? []).joined(separator: " ")
            ]
            .joined(separator: " ")
            .lowercased()
            return haystack.contains(query)
        }
    }

    func chamberSecretConfiguration(for secretName: String) -> SecretPresentationConfiguration {
        chamberMetadata.secretConfigurations[secretName] ?? SecretPresentationConfiguration()
    }

    func chamberSecretDisplayTitle(for secretName: String) -> String {
        let config = chamberSecretConfiguration(for: secretName)
        let trimmed = config.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : secretName
    }

    var suggestedDraftTags: [String] {
        let tags: Set<String>
        if chamberDraft.kind == .secret {
            tags = Set(
                chamberMetadata.secretTags
                    .values
                    .flatMap { $0 }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        } else {
            let targetKind = chamberDraft.kind
            tags = Set(
                chamberStoredItems
                    .filter { $0.kind == targetKind }
                    .flatMap(\.tags)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var selectedChamberItem: ChamberItem? {
        guard let selectedChamberItemId else { return nil }
        return chamberItems.first(where: { $0.id == selectedChamberItemId })
    }

    func resetChamberTransientState() {
        selectedChamberItemId = nil
        showingChamberEditor = false
        chamberDraftError = nil
        chamberSearchVisible = false
        chamberSearchText = ""
        chamberFilterVisible = false
        chamberSelectedTagFilter = nil
        chamberPanelCategory = nil
        trustedShellExpanded = false
    }

    func selectChamberCategory(_ category: ChamberCategory) {
        showingChamberEditor = false
        chamberSearchText = ""
        chamberSearchVisible = false
        chamberFilterVisible = false
        chamberSelectedTagFilter = nil
        if chamberPanelCategory == category {
            chamberPanelCategory = nil
            selectedChamberItemId = nil
            return
        }
        chamberCategory = category
        chamberPanelCategory = category
        if let selected = selectedChamberItemId,
           chamberItems.contains(where: { $0.id == selected }) {
            return
        }
        selectedChamberItemId = nil
    }

    func toggleChamberSearch() {
        showingChamberEditor = false
        chamberFilterVisible = false
        chamberSearchVisible.toggle()
        if chamberSearchVisible {
            chamberPanelCategory = nil
        } else {
            chamberSearchText = ""
            chamberSelectedTagFilter = nil
        }
        selectedChamberItemId = nil
    }

    func openTrustedShellSession() {
        guard hasActiveTrust else {
            trustedShellStatus = "Chamber locked. Open the iPhone app to continue."
            return
        }
        guard trustedShellLive == false else { return }

        let shellPath = trustedShellExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            : trustedShellExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        let workdir = trustedShellWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let shellBootstrap = trustedShellBootstrap(for: shellPath)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", shellPath] + shellBootstrap.arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        if !workdir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workdir, isDirectory: true)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "vt100"
        environment["SYMBIAUTH_TRUSTED_SHELL"] = "1"
        environment["PROMPT"] = ""
        environment["PS1"] = ""
        environment["BASH_SILENCE_DEPRECATION_WARNING"] = "1"
        environment["SHELL_SESSIONS_DISABLE"] = "1"
        environment["HISTFILE"] = "/dev/null"
        shellBootstrap.environment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.appendTrustedShellOutput(chunk)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.trustedShellProcess = nil
                self?.trustedShellOutputPipe?.fileHandleForReading.readabilityHandler = nil
                self?.trustedShellOutputPipe = nil
                self?.trustedShellInputPipe = nil
                self?.trustedShellLive = false
                if self?.hasActiveTrust == true {
                    self?.trustedShellStatus = "Trusted shell ended."
                } else {
                    self?.trustedShellStatus = "Trusted shell sealed."
                }
            }
        }

        do {
            try process.run()
            trustedShellProcess = process
            trustedShellOutputPipe = outputPipe
            trustedShellInputPipe = inputPipe
            trustedShellPendingEscapeFragment = ""
            trustedShellSuppressedTranscriptLines = []
            trustedShellOutputBuffer = ""
            trustedShellCommandHistory = []
            trustedShellHistoryIndex = nil
            trustedShellHistoryDraft = ""
            trustedShellCurrentDirectory = workdir.isEmpty ? NSHomeDirectory() : workdir
            trustedShellExpanded = false
            trustedShellTranscript = """
╭─ trusted shell online
│ type chamber inject to load secrets into this shell
│ type chamber env to list injected names

"""
            trustedShellInput = ""
            trustedShellLive = true
            trustedShellStatus = "Trusted shell active."
            trustedShellInjectVisible = false
            trustedShellInjectSearch = ""
            trustedShellInjectSelection = []
            appendHistory(category: .session, title: "Trusted Shell Started", detail: "A chamber-owned trusted shell session was opened.")
        } catch {
            trustedShellStatus = "Shell launch failed: \(error.localizedDescription)"
            trustedShellProcess = nil
            trustedShellOutputPipe?.fileHandleForReading.readabilityHandler = nil
            trustedShellOutputPipe = nil
            trustedShellInputPipe = nil
            trustedShellLive = false
        }
    }

    func closeTrustedShellSession() {
        terminateTrustedShell(reason: "manual_close")
    }

    func sendTrustedShellInput() {
        guard trustedShellLive else { return }
        let command = trustedShellInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        if trustedShellCommandHistory.last != command {
            trustedShellCommandHistory.append(command)
        }
        trustedShellHistoryIndex = nil
        trustedShellHistoryDraft = ""
        appendTrustedShellOutput("\(trustedShellPromptPrefix())\(command)\n")
        if handleTrustedShellInternalCommand(command) {
            trustedShellInput = ""
            return
        }
        updateTrustedShellDirectory(for: command)
        trustedShellSuppressedTranscriptLines.append(command)
        if let data = (command + "\n").data(using: .utf8) {
            trustedShellInputPipe?.fileHandleForWriting.write(data)
        }
        trustedShellInput = ""
    }

    func terminateTrustedShell(reason: String) {
        trustedShellOutputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = trustedShellProcess, process.isRunning {
            process.terminate()
        }
        trustedShellProcess = nil
        trustedShellOutputPipe = nil
        trustedShellInputPipe = nil
        trustedShellPendingEscapeFragment = ""
        trustedShellSuppressedTranscriptLines = []
        trustedShellOutputBuffer = ""
        trustedShellCommandHistory = []
        trustedShellHistoryIndex = nil
        trustedShellHistoryDraft = ""
        trustedShellCurrentDirectory = NSHomeDirectory()
        trustedShellLive = false
        trustedShellExpanded = false
        trustedShellInjectedSecrets = []
        trustedShellInjectVisible = false
        trustedShellInjectSearch = ""
        trustedShellInjectSelection = []
        switch reason {
        case "trust_ended":
            trustedShellStatus = "Trusted shell sealed."
        case "manual_close":
            trustedShellStatus = "Trusted shell closed."
        default:
            trustedShellStatus = "Trusted shell ended."
        }
    }

    private func appendTrustedShellOutput(_ raw: String) {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let combined = trustedShellPendingEscapeFragment + normalized
        let sanitized = sanitizeTrustedShellOutput(combined)
        trustedShellPendingEscapeFragment = sanitized.remainder
        trustedShellOutputBuffer.append(sanitized.clean)
        let flushed = flushTrustedShellOutputBuffer()
        trustedShellTranscript.append(flushed)
        if trustedShellTranscript.count > 50000 {
            trustedShellTranscript = String(trustedShellTranscript.suffix(50000))
        }
    }

    private func flushTrustedShellOutputBuffer() -> String {
        guard !trustedShellOutputBuffer.isEmpty else { return "" }

        let endsWithNewline = trustedShellOutputBuffer.hasSuffix("\n")
        var lines = trustedShellOutputBuffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let remainder = endsWithNewline ? "" : (lines.popLast() ?? "")

        var filtered: [String] = []
        var previousWasBlank = false
        for line in lines {
            let normalizedLine = line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            let trimmed = normalizedLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let idx = trustedShellSuppressedTranscriptLines.indices.first(where: { idx in
                suppressionDisposition(for: trimmed, suppressed: trustedShellSuppressedTranscriptLines[idx]) != .none
            }) {
                let disposition = suppressionDisposition(for: trimmed, suppressed: trustedShellSuppressedTranscriptLines[idx])
                if disposition == .consume {
                    trustedShellSuppressedTranscriptLines.remove(at: idx)
                }
                continue
            }
            if trimmed.isEmpty {
                if previousWasBlank {
                    continue
                }
                previousWasBlank = true
                filtered.append("")
                continue
            }
            previousWasBlank = false
            filtered.append(normalizedLine)
        }

        trustedShellOutputBuffer = remainder
        return filtered.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }

    private enum ShellSuppressionDisposition {
        case none
        case dropOnly
        case consume
    }

    private func suppressionDisposition(for line: String, suppressed: String) -> ShellSuppressionDisposition {
        if line == suppressed || line.hasSuffix(suppressed) || line.contains(suppressed) {
            return .consume
        }
        guard let first = suppressed.first else { return .none }
        let doubled = String(first) + suppressed
        if line == doubled || line.hasSuffix(doubled) || line.contains(doubled) {
            return .consume
        }

        // Some PTY echo paths leak only the first character or a short prefix of the
        // just-sent command as its own line before the full echo arrives.
        if !line.isEmpty, line.count <= min(4, suppressed.count), suppressed.hasPrefix(line) {
            return .dropOnly
        }
        if !line.isEmpty, line.count <= min(5, doubled.count), doubled.hasPrefix(line) {
            return .dropOnly
        }

        return .none
    }

    private func sanitizeTrustedShellOutput(_ input: String) -> (clean: String, remainder: String) {
        var output = ""
        var index = input.startIndex

        func removePreviousCharacter() {
            guard !output.isEmpty else { return }
            output.removeLast()
        }

        while index < input.endIndex {
            let char = input[index]

            if char == "\u{1B}" {
                let escapeStart = index
                let nextIndex = input.index(after: index)
                guard nextIndex < input.endIndex else {
                    return (output, String(input[escapeStart...]))
                }
                let next = input[nextIndex]

                if next == "[" {
                    index = input.index(after: nextIndex)
                    var terminated = false
                    while index < input.endIndex {
                        let scalar = input[index].unicodeScalars.first?.value ?? 0
                        if scalar >= 0x40 && scalar <= 0x7E {
                            index = input.index(after: index)
                            terminated = true
                            break
                        }
                        index = input.index(after: index)
                    }
                    if !terminated {
                        return (output, String(input[escapeStart...]))
                    }
                    continue
                }

                if next == "]" {
                    index = input.index(after: nextIndex)
                    var terminated = false
                    while index < input.endIndex {
                        let current = input[index]
                        if current == "\u{7}" {
                            index = input.index(after: index)
                            terminated = true
                            break
                        }
                        if current == "\u{1B}" {
                            let lookahead = input.index(after: index)
                            if lookahead < input.endIndex, input[lookahead] == "\\" {
                                index = input.index(after: lookahead)
                                terminated = true
                                break
                            }
                        }
                        index = input.index(after: index)
                    }
                    if !terminated {
                        return (output, String(input[escapeStart...]))
                    }
                    continue
                }

                index = input.index(after: nextIndex)
                continue
            }

            if char == "\u{08}" || char == "\u{7F}" {
                removePreviousCharacter()
                index = input.index(after: index)
                continue
            }

            if char == "\u{07}" || char == "\0" {
                index = input.index(after: index)
                continue
            }

            if let scalar = char.unicodeScalars.first?.value, scalar < 0x20, char != "\n", char != "\t" {
                index = input.index(after: index)
                continue
            }

            output.append(char)
            index = input.index(after: index)
        }

        return (output, "")
    }

    func navigateTrustedShellHistory(direction: Int) {
        guard trustedShellLive, !trustedShellCommandHistory.isEmpty else { return }

        if direction < 0 {
            if trustedShellHistoryIndex == nil {
                trustedShellHistoryDraft = trustedShellInput
                trustedShellHistoryIndex = trustedShellCommandHistory.count - 1
            } else if let index = trustedShellHistoryIndex, index > 0 {
                trustedShellHistoryIndex = index - 1
            }
        } else if direction > 0 {
            guard let index = trustedShellHistoryIndex else { return }
            if index < trustedShellCommandHistory.count - 1 {
                trustedShellHistoryIndex = index + 1
            } else {
                trustedShellHistoryIndex = nil
                trustedShellInput = trustedShellHistoryDraft
                return
            }
        }

        if let index = trustedShellHistoryIndex, trustedShellCommandHistory.indices.contains(index) {
            trustedShellInput = trustedShellCommandHistory[index]
        }
    }

    private func trustedShellPromptPrefix() -> String {
        "cmbo:\(trustedShellPromptDirectoryLabel()) > "
    }

    private func trustedShellPromptDirectoryLabel() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let current = trustedShellCurrentDirectory
        if current == home {
            return "~"
        }
        if current.hasPrefix(home + "/") {
            return "~/" + current.dropFirst(home.count + 1)
        }
        return URL(fileURLWithPath: current).lastPathComponent.isEmpty ? current : URL(fileURLWithPath: current).lastPathComponent
    }

    private func updateTrustedShellDirectory(for command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "cd" || trimmed.hasPrefix("cd ") else { return }

        let destination = trimmed == "cd" ? "~" : String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPath: String
        if destination.isEmpty || destination == "~" {
            targetPath = FileManager.default.homeDirectoryForCurrentUser.path
        } else if destination.hasPrefix("~/") {
            let suffix = String(destination.dropFirst(2))
            targetPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(suffix, isDirectory: true).path
        } else if destination == ".." {
            targetPath = URL(fileURLWithPath: trustedShellCurrentDirectory)
                .deletingLastPathComponent().path
        } else if destination.hasPrefix("/") {
            targetPath = destination
        } else {
            targetPath = URL(fileURLWithPath: trustedShellCurrentDirectory)
                .appendingPathComponent(destination, isDirectory: true).path
        }

        trustedShellCurrentDirectory = URL(fileURLWithPath: targetPath).standardizedFileURL.path
    }

    func openTrustedShellInject(prefill query: String? = nil) {
        guard trustedShellLive else { return }
        trustedShellInjectVisible = true
        if let query {
            trustedShellInjectSearch = query
        }
        let available = Set(trustedShellFilteredSecrets.map(\.name))
        trustedShellInjectSelection = trustedShellInjectSelection.intersection(available)
        if trustedShellInjectSelection.isEmpty, let first = trustedShellFilteredSecrets.first?.name {
            trustedShellInjectSelection = [first]
        }
        trustedShellStatus = "Select one or more secrets to inject into the current shell."
    }

    func cancelTrustedShellInject() {
        trustedShellInjectVisible = false
        trustedShellInjectSearch = ""
        trustedShellInjectSelection = []
        if trustedShellLive {
            trustedShellStatus = "Trusted shell active."
        }
    }

    func toggleTrustedShellInjectSelection(secretName: String) {
        if trustedShellInjectSelection.contains(secretName) {
            trustedShellInjectSelection.remove(secretName)
        } else {
            trustedShellInjectSelection.insert(secretName)
        }
    }

    func injectSelectedTrustedShellSecrets() {
        let selectedNames = trustedShellEligibleSecrets
            .map(\.name)
            .filter { trustedShellInjectSelection.contains($0) }
        guard !selectedNames.isEmpty else {
            trustedShellStatus = "Select at least one secret to inject."
            return
        }
        injectTrustedShellSecrets(named: selectedNames)
    }

    private func injectTrustedShellSecrets(named secretNames: [String]) {
        guard hasActiveTrust, trustedShellLive else {
            trustedShellStatus = "Trusted shell unavailable."
            return
        }
        let ordered = secretNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ordered.isEmpty else { return }

        trustedShellStatus = "Injecting \(ordered.count) secret\(ordered.count == 1 ? "" : "s") into the shell…"

        injectTrustedShellSecretsRecursively(secretNames: ordered, index: 0, injectedNames: [])
    }

    private func injectTrustedShellSecretsRecursively(secretNames: [String], index: Int, injectedNames: [String]) {
        guard index < secretNames.count else {
            trustedShellInjectedSecrets = Array(Set(trustedShellInjectedSecrets + injectedNames)).sorted()
            trustedShellInjectVisible = false
            trustedShellInjectSearch = ""
            trustedShellInjectSelection = []
            let detail = injectedNames.joined(separator: ", ")
            appendTrustedShellOutput(":: injected \(detail)\n")
            trustedShellStatus = "Injected \(injectedNames.count) secret\(injectedNames.count == 1 ? "" : "s") into the shell."
            appendHistory(category: .session, title: "Trusted Shell Injected", detail: "Injected \(detail) into the active trusted shell.")
            return
        }

        let secretName = secretNames[index]
        let req: [String: Any] = [
            "type": "secret.get",
            "corr_id": corrId(),
            "name": secretName
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                guard self.trustedShellLive else { return }
                guard (response["ok"] as? Bool) == true,
                      let value = response["value"] as? String else {
                    let err = response["error"] as? String ?? "secret_get_failed"
                    self.trustedShellStatus = self.formatSecretError(err, operation: "inject")
                    return
                }

                let envKey = self.trustedShellEnvironmentKey(for: secretName)
                let exportCommand = "export \(envKey)=\(self.shellSingleQuoted(value))\n"
                self.trustedShellSuppressedTranscriptLines.append(exportCommand.trimmingCharacters(in: .whitespacesAndNewlines))
                if let data = exportCommand.data(using: .utf8) {
                    self.trustedShellInputPipe?.fileHandleForWriting.write(data)
                }
                self.injectTrustedShellSecretsRecursively(
                    secretNames: secretNames,
                    index: index + 1,
                    injectedNames: injectedNames + [envKey]
                )
            }
        }
    }

    private func handleTrustedShellInternalCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("chamber") else { return false }
        if trimmed == "chamber help" {
            appendTrustedShellOutput("""
:: chamber commands
   chamber inject         open secret injector
   chamber env            list injected env names
   chamber clear          clear injected env names from chamber state

""")
            return true
        }
        if trimmed == "chamber env" {
            let names = trustedShellInjectedSecrets.isEmpty ? "(none)" : trustedShellInjectedSecrets.joined(separator: ", ")
            appendTrustedShellOutput(":: injected env names: \(names)\n")
            return true
        }
        if trimmed == "chamber clear" {
            trustedShellInjectedSecrets = []
            appendTrustedShellOutput(":: cleared injected env list from chamber state\n")
            trustedShellStatus = "Cleared chamber-side injected secret list."
            return true
        }
        if trimmed == "chamber inject" {
            openTrustedShellInject()
            return true
        }
        if trimmed.hasPrefix("chamber inject ") {
            let query = String(trimmed.dropFirst("chamber inject ".count))
            openTrustedShellInject(prefill: query)
            return true
        }
        appendTrustedShellOutput(":: unknown chamber command: \(trimmed)\n")
        return true
    }

    private func trustedShellEnvironmentKey(for secretName: String) -> String {
        let config = chamberMetadata.secretConfigurations[secretName] ?? SecretPresentationConfiguration()
        return secretName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (config.title ?? secretName) : secretName
    }

    private func shellSingleQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func trustedShellBootstrap(for shellPath: String) -> (arguments: [String], environment: [String: String]) {
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent.lowercased()
        let runtimeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".armadillo", isDirectory: true)
            .appendingPathComponent("trusted_shell", isDirectory: true)
        try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)

        if shellName.contains("zsh") {
            let zshDir = runtimeDir.appendingPathComponent("zsh", isDirectory: true)
            try? FileManager.default.createDirectory(at: zshDir, withIntermediateDirectories: true)
            let zshrc = """
setopt PROMPT_SUBST
PROMPT=''
RPROMPT=''
PROMPT_EOL_MARK=''
export PS1=''
export HISTFILE=/dev/null
export SHELL_SESSIONS_DISABLE=1
unsetopt BEEP
"""
            try? zshrc.write(to: zshDir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            return (["-i"], ["ZDOTDIR": zshDir.path])
        }

        if shellName.contains("bash") {
            let bashrc = runtimeDir.appendingPathComponent("bashrc")
            let contents = """
export PS1=''
export HISTFILE=/dev/null
export SHELL_SESSIONS_DISABLE=1
set +o histexpand
"""
            try? contents.write(to: bashrc, atomically: true, encoding: .utf8)
            return (["--noprofile", "--rcfile", bashrc.path, "-i"], [:])
        }

        return (["-i"], [:])
    }

    func ensureChamberSelection() {
        if selectedChamberItemId != nil, selectedChamberItem == nil {
            selectedChamberItemId = nil
        }
    }

    func selectChamberItem(_ item: ChamberItem) {
        selectedChamberItemId = item.id
        chamberSearchVisible = false
        chamberFilterVisible = false
        chamberCategory = item.category
        chamberPanelCategory = item.category
        markChamberItemOpened(item)
    }

    func openNewChamberDraft(kind: ChamberStoredKind) {
        chamberDraft = ChamberDraft(kind: kind)
        chamberDraftError = nil
        chamberSearchVisible = false
        chamberFilterVisible = false
        chamberPanelCategory = kind == .secret ? .secrets : kind == .note ? .notes : .documents
        chamberCategory = chamberPanelCategory ?? chamberCategory
        if kind == .secret {
            chamberDraft.secretType = "custom"
            chamberDraft.secretName = ""
        }
        showingChamberEditor = true
    }

    func openEditChamberDraft() {
        guard let item = selectedChamberItem else { return }
        chamberDraftError = nil
        chamberFilterVisible = false
        switch item.kind {
        case .secret:
            let config = chamberMetadata.secretConfigurations[item.secretName ?? item.title] ?? SecretPresentationConfiguration()
            let trimmedTitle = config.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let secretName = item.secretName ?? item.title
            chamberDraft = ChamberDraft(
                kind: .secret,
                title: (trimmedTitle?.isEmpty == false ? trimmedTitle! : secretName),
                note: item.note,
                tagsText: item.tags.joined(separator: ", "),
                secretName: secretName,
                secretValue: revealedSecretValues[secretName] ?? "",
                secretType: config.type,
                secretAvailableInShell: config.availableInShell,
                body: "",
                noteFormat: "plain_text",
                fileName: "",
                mimeType: "",
                fileData: nil,
                editingStoredItemId: nil
            )
            if chamberDraft.secretValue.isEmpty {
                populateDraftSecretValue(secretName: secretName)
            }
        case .note, .document:
            guard let stored = chamberStoredItem(for: item.id) else { return }
            chamberDraft = ChamberDraft(
                kind: stored.kind,
                title: stored.title,
                note: stored.note,
                tagsText: stored.tags.joined(separator: ", "),
                secretName: "",
                secretValue: "",
                secretType: "custom",
                secretAvailableInShell: false,
                body: stored.body ?? "",
                noteFormat: stored.format ?? "plain_text",
                fileName: stored.fileName ?? "",
                mimeType: stored.mimeType ?? "",
                fileData: stored.fileData,
                editingStoredItemId: stored.id
            )
        }
        showingChamberEditor = true
    }

    private func populateDraftSecretValue(secretName: String) {
        guard hasActiveTrust else { return }
        let req: [String: Any] = [
            "type": "secret.get",
            "corr_id": corrId(),
            "name": secretName
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                guard self.showingChamberEditor,
                      self.chamberDraft.kind == .secret,
                      self.chamberDraft.secretName == secretName else { return }
                if (response["ok"] as? Bool) == true,
                   let value = response["value"] as? String {
                    self.chamberDraft.secretValue = value
                }
            }
        }
    }

    func toggleChamberFilter() {
        showingChamberEditor = false
        selectedChamberItemId = nil
        chamberFilterVisible.toggle()
    }

    func selectTagFilter(_ tag: String) {
        chamberSelectedTagFilter = tag
    }

    func clearTagFilter() {
        chamberSelectedTagFilter = nil
    }

    func closeChamberFilter() {
        chamberFilterVisible = false
    }

    func applySuggestedDraftTag(_ tag: String) {
        let existing = chamberDraft.tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard existing.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) == false else { return }
        if existing.isEmpty {
            chamberDraft.tagsText = tag
        } else {
            chamberDraft.tagsText = existing.joined(separator: ", ") + ", " + tag
        }
    }

    func saveChamberDraft() {
        guard hasActiveTrust else {
            chamberDraftError = "Chamber locked. Open the iPhone app to continue."
            return
        }
        chamberDraftError = nil
        let parsedTags = chamberDraft.tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        switch chamberDraft.kind {
        case .secret:
            let name = chamberDraft.secretName.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = chamberDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                chamberDraftError = "Secret name is required."
                return
            }
            if chamberDraft.secretValue.isEmpty {
                chamberDraftError = "Secret value is required."
                return
            }
            draftSecretName = name
            draftSecretValue = chamberDraft.secretValue
            saveDraftSecret { [weak self] success, message in
                guard let self else { return }
                if success {
                    let savedName = self.draftSecretName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !savedName.isEmpty {
                        if parsedTags.isEmpty {
                            self.chamberMetadata.secretTags.removeValue(forKey: savedName)
                        } else {
                            self.chamberMetadata.secretTags[savedName] = parsedTags
                        }
                        let normalizedTitle = displayTitle == savedName ? nil : (displayTitle.isEmpty ? nil : displayTitle)
                        self.chamberMetadata.secretConfigurations[savedName] = SecretPresentationConfiguration(
                            title: normalizedTitle,
                            type: self.chamberDraft.secretType,
                            availableInShell: self.chamberDraft.secretAvailableInShell
                        )
                        self.persistChamberMetadata()
                    }
                    self.setChamberStatus(message)
                    self.chamberDraft = ChamberDraft()
                    self.showingChamberEditor = false
                    self.refreshSecrets()
                    self.selectedChamberItemId = savedName.isEmpty ? nil : "secret:\(savedName)"
                } else {
                    self.chamberDraftError = message
                }
            }
        case .note:
            let title = chamberDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || chamberDraft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chamberDraftError = "Title and note content are required."
                return
            }
            upsertStoredChamberItem(kind: .note)
        case .document:
            let title = chamberDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || chamberDraft.fileData == nil {
                chamberDraftError = "Title and a document file are required."
                return
            }
            upsertStoredChamberItem(kind: .document)
        }
    }

    func deleteSelectedChamberItem() {
        guard let item = selectedChamberItem else { return }
        switch item.kind {
        case .secret:
            selectedSecretName = item.secretName
            deleteSelectedSecret()
            setChamberStatus(secretActionStatus)
        case .note, .document:
            guard let stored = chamberStoredItem(for: item.id) else { return }
            chamberStoredItems.removeAll { $0.id == stored.id }
            persistChamberItems()
            setChamberStatus("\"\(stored.title)\" deleted from the chamber.")
            appendHistory(category: .session, title: "Chamber Item Deleted", detail: "\"\(stored.title)\" was removed from the chamber.")
            selectedChamberItemId = nil
        }
    }

    func toggleSelectedChamberFavorite() {
        guard let item = selectedChamberItem else { return }
        switch item.kind {
        case .secret:
            guard let secretName = item.secretName else { return }
            if chamberMetadata.favoriteSecretNames.contains(secretName) {
                chamberMetadata.favoriteSecretNames.remove(secretName)
                setChamberStatus("\"\(item.title)\" removed from favorites.")
            } else {
                chamberMetadata.favoriteSecretNames.insert(secretName)
                setChamberStatus("\"\(item.title)\" added to favorites.")
            }
            persistChamberMetadata()
        case .note, .document:
            guard let stored = chamberStoredItem(for: item.id),
                  let index = chamberStoredItems.firstIndex(where: { $0.id == stored.id }) else { return }
            chamberStoredItems[index].favorite.toggle()
            persistChamberItems()
            setChamberStatus(chamberStoredItems[index].favorite
                ? "\"\(item.title)\" added to favorites."
                : "\"\(item.title)\" removed from favorites.")
        }
        appendHistory(category: .session, title: "Favorite Updated", detail: chamberActionStatus ?? "Favorite state changed.")
    }

    func saveInlineNoteBody(_ body: String) {
        saveInlineNote(body: body, format: selectedChamberItem?.textFormat ?? "plain_text")
    }

    func saveInlineNote(body: String, format: String) {
        guard hasActiveTrust else {
            setChamberStatus("Chamber locked. Open the iPhone app to continue.")
            return
        }
        guard let item = selectedChamberItem,
              item.kind == .note,
              let stored = chamberStoredItem(for: item.id),
              let index = chamberStoredItems.firstIndex(where: { $0.id == stored.id }) else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setChamberStatus("Note content cannot be empty.")
            return
        }
        chamberStoredItems[index].body = body
        chamberStoredItems[index].format = format
        chamberStoredItems[index].updatedAt = Date()
        persistChamberItems()
        setChamberStatus("\"\(item.title)\" updated.")
        appendHistory(category: .session, title: "Note Updated", detail: "\"\(item.title)\" was updated in the chamber.")
    }

    func revealSelectedSecret() {
        guard let item = selectedChamberItem else { return }
        toggleReveal(for: item)
    }

    func toggleReveal(for item: ChamberItem, selectItem: Bool = true) {
        guard item.kind == .secret, let secretName = item.secretName else { return }
        if selectItem && selectedChamberItemId != item.id {
            selectChamberItem(item)
        }
        if revealedSecretValues[secretName] != nil {
            revealedSecretValues.removeValue(forKey: secretName)
            setChamberStatus("\"\(secretName)\" hidden.")
            return
        }
        guard hasActiveTrust else {
            setChamberStatus("Chamber locked. Open the iPhone app to continue.")
            return
        }
        let req: [String: Any] = [
            "type": "secret.get",
            "corr_id": corrId(),
            "name": secretName
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                if (response["ok"] as? Bool) == true, let value = response["value"] as? String {
                    self.revealedSecretValues[secretName] = value
                    self.setChamberStatus("\"\(secretName)\" is visible while trust stays active.")
                    self.appendHistory(category: .session, title: "Secret Revealed", detail: "\"\(secretName)\" was revealed in the chamber.")
                } else {
                    let err = response["error"] as? String ?? "secret_get_failed"
                    self.setChamberStatus(self.formatSecretError(err, operation: "reveal"), autoClearAfter: nil)
                    self.lastError = err
                }
            }
        }
    }

    func copySelectedChamberItem() {
        guard hasActiveTrust else {
            setChamberStatus("Chamber locked. Open the iPhone app to continue.")
            return
        }
        guard let item = selectedChamberItem else { return }
        copyChamberItem(item)
    }

    func copyChamberItem(_ item: ChamberItem) {
        copyChamberItem(item, selectItem: true)
    }

    func copyChamberItem(_ item: ChamberItem, selectItem: Bool) {
        if selectItem && selectedChamberItemId != item.id {
            selectChamberItem(item)
        }
        switch item.kind {
        case .secret:
            guard let secretName = item.secretName else { return }
            if let revealed = revealedSecretValues[secretName] {
                copyProtectedText(revealed, title: item.title)
                return
            }
            let req: [String: Any] = [
                "type": "secret.get",
                "corr_id": corrId(),
                "name": secretName
            ]
            sendToAgent(req) { [weak self] response in
                guard let self else { return }
                Task { @MainActor in
                    if (response["ok"] as? Bool) == true, let value = response["value"] as? String {
                        self.copyProtectedText(value, title: item.title)
                    } else {
                        let err = response["error"] as? String ?? "secret_get_failed"
                        self.setChamberStatus(self.formatSecretError(err, operation: "copy"), autoClearAfter: nil)
                        self.lastError = err
                    }
                }
            }
        case .note:
            copyProtectedText(item.textContent ?? "", title: item.title)
        case .document:
            exportSelectedDocument()
        }
    }

    func clearProtectedClipboardIfNeeded() {
        clipboardBadgeClearWorkItem?.cancel()
        guard let protectedClipboardValue else { return }
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == protectedClipboardValue {
            pasteboard.clearContents()
        }
        self.protectedClipboardValue = nil
        self.protectedClipboardActive = false
    }

    func cleanupTemporaryExportsIfNeeded() {
        guard !temporaryExportURLs.isEmpty else { return }
        let exports = temporaryExportURLs
        temporaryExportURLs.removeAll()
        for url in exports {
            try? FileManager.default.removeItem(at: url)
        }
        setChamberStatus("Temporary chamber files were removed when trust ended.")
        appendHistory(category: .session, title: "Temporary Exports Cleared", detail: "Trust ended, so chamber export files were removed.")
    }

    func clearRevealedSecrets() {
        if !revealedSecretValues.isEmpty {
            revealedSecretValues.removeAll()
        }
    }

    func importDocumentForDraft() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url) else {
                Task { @MainActor in
                    self.setChamberStatus("Could not read the selected file.", autoClearAfter: nil)
                }
                return
            }
            Task { @MainActor in
                self.chamberDraft.fileData = data
                self.chamberDraft.fileName = url.lastPathComponent
                self.chamberDraft.mimeType = url.pathExtension.isEmpty ? "application/octet-stream" : url.pathExtension
                if self.chamberDraft.title.isEmpty {
                    self.chamberDraft.title = url.deletingPathExtension().lastPathComponent
                }
            }
        }
    }

    func exportSelectedDocument() {
        guard hasActiveTrust else {
            setChamberStatus("Chamber locked. Open the iPhone app to continue.")
            return
        }
        guard let item = selectedChamberItem,
              item.kind == .document,
              let data = item.fileData else { return }

        let exportsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".armadillo", isDirectory: true)
            .appendingPathComponent("chamber_exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let safeName = item.fileName ?? "\(item.title).bin"
        let exportURL = exportsDir.appendingPathComponent("\(UUID().uuidString)-\(safeName)")

        do {
            try data.write(to: exportURL, options: .atomic)
            temporaryExportURLs.append(exportURL)
            setChamberStatus("\"\(item.title)\" exported to a temporary chamber file. It is removed when trust ends.")
            appendHistory(category: .session, title: "Document Exported", detail: "\"\(item.title)\" was exported temporarily from the chamber.")
            NSWorkspace.shared.activateFileViewerSelecting([exportURL])
        } catch {
            setChamberStatus("Export failed: \(error.localizedDescription)", autoClearAfter: nil)
        }
    }

    func exportSelectedNote(bodyOverride: String? = nil, formatOverride: String? = nil) {
        guard hasActiveTrust else {
            setChamberStatus("Chamber locked. Open the iPhone app to continue.")
            return
        }
        guard let item = selectedChamberItem, item.kind == .note else { return }
        let body = bodyOverride ?? item.textContent ?? ""
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setChamberStatus("Note is empty.")
            return
        }

        let format = formatOverride ?? item.textFormat ?? "plain_text"
        let ext = format == "markdown" ? "md" : "txt"
        let fileName = sanitizedExportName(for: item.title, fallbackExtension: ext)
        exportTemporaryData(Data(trimmed.utf8), fileName: fileName, title: item.title, historyTitle: "Note Exported")
    }

    private func exportTemporaryData(_ data: Data, fileName: String, title: String, historyTitle: String) {
        let exportsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".armadillo", isDirectory: true)
            .appendingPathComponent("chamber_exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let exportURL = exportsDir.appendingPathComponent("\(UUID().uuidString)-\(fileName)")

        do {
            try data.write(to: exportURL, options: .atomic)
            temporaryExportURLs.append(exportURL)
            setChamberStatus("\"\(title)\" exported to a temporary chamber file. It is removed when trust ends.")
            appendHistory(category: .session, title: historyTitle, detail: "\"\(title)\" was exported temporarily from the chamber.")
            NSWorkspace.shared.activateFileViewerSelecting([exportURL])
        } catch {
            setChamberStatus("Export failed: \(error.localizedDescription)", autoClearAfter: nil)
        }
    }

    private func sanitizedExportName(for title: String, fallbackExtension ext: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "chamber-item"
        let base = trimmed.isEmpty ? fallback : trimmed
        let safe = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if (safe as NSString).pathExtension.isEmpty {
            return "\(safe).\(ext)"
        }
        return safe
    }

    private func copyProtectedText(_ text: String, title: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        protectedClipboardValue = text
        protectedClipboardActive = true
        setChamberStatus("\"\(title)\" copied. Clipboard clears when trust ends.")
        clipboardBadgeClearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.protectedClipboardActive = false
        }
        clipboardBadgeClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
        appendHistory(category: .session, title: "Protected Content Copied", detail: "\"\(title)\" was copied from the chamber.")
    }

    private func upsertStoredChamberItem(kind: ChamberStoredKind) {
        let now = Date()
        let tags = chamberDraft.tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let editingId = chamberDraft.editingStoredItemId,
           let index = chamberStoredItems.firstIndex(where: { $0.id == editingId }) {
            chamberStoredItems[index].title = chamberDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            chamberStoredItems[index].note = chamberDraft.note.trimmingCharacters(in: .whitespacesAndNewlines)
            chamberStoredItems[index].tags = tags
            chamberStoredItems[index].updatedAt = now
            chamberStoredItems[index].body = kind == .note ? chamberDraft.body : nil
            chamberStoredItems[index].format = kind == .note ? chamberDraft.noteFormat : nil
            chamberStoredItems[index].fileName = kind == .document ? chamberDraft.fileName : nil
            chamberStoredItems[index].mimeType = kind == .document ? chamberDraft.mimeType : nil
            chamberStoredItems[index].fileData = kind == .document ? chamberDraft.fileData : nil
            chamberStoredItems[index].fileSize = kind == .document ? chamberDraft.fileData?.count : nil
            setChamberStatus("\"\(chamberStoredItems[index].title)\" updated.")
            appendHistory(category: .session, title: "Chamber Item Updated", detail: "\"\(chamberStoredItems[index].title)\" was updated.")
        } else {
            let stored = ChamberStoredItem(
                kind: kind,
                title: chamberDraft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                note: chamberDraft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: tags,
                favorite: false,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                body: kind == .note ? chamberDraft.body : nil,
                format: kind == .note ? chamberDraft.noteFormat : nil,
                fileName: kind == .document ? chamberDraft.fileName : nil,
                mimeType: kind == .document ? chamberDraft.mimeType : nil,
                fileData: kind == .document ? chamberDraft.fileData : nil,
                fileSize: kind == .document ? chamberDraft.fileData?.count : nil
            )
            chamberStoredItems.append(stored)
            setChamberStatus("\"\(stored.title)\" added to the chamber.")
            appendHistory(category: .session, title: "Chamber Item Added", detail: "\"\(stored.title)\" was added to the chamber.")
        }

        persistChamberItems()
        chamberDraft = ChamberDraft()
        chamberDraftError = nil
        showingChamberEditor = false
        if let latest = chamberStoredItems.last {
            selectedChamberItemId = "\(latest.kind.rawValue):\(latest.id.uuidString)"
        }
    }

    private func markChamberItemOpened(_ item: ChamberItem) {
        if let stored = chamberStoredItem(for: item.id),
           let index = chamberStoredItems.firstIndex(where: { $0.id == stored.id }) {
            chamberStoredItems[index].lastOpenedAt = Date()
            persistChamberItems()
        } else if item.kind == .secret, let secretName = item.secretName {
            chamberMetadata.recentSecretAccess[secretName] = Date()
            persistChamberMetadata()
        }
    }

    private func chamberStoredItem(for chamberItemID: String) -> ChamberStoredItem? {
        let parts = chamberItemID.split(separator: ":")
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else { return nil }
        return chamberStoredItems.first(where: { $0.id == uuid })
    }

    func loadPersistedChamberItems() {
        guard let data = try? Data(contentsOf: chamberItemsURL) else { return }

        if let decoded = try? JSONDecoder().decode([ChamberStoredItem].self, from: data) {
            chamberStoredItems = decoded
            persistChamberItems()
            return
        }

        guard let key = chamberStorageKey(),
              let sealed = try? AES.GCM.SealedBox(combined: data),
              let plaintext = try? AES.GCM.open(sealed, using: key),
              let decoded = try? JSONDecoder().decode([ChamberStoredItem].self, from: plaintext) else {
            return
        }
        chamberStoredItems = decoded
    }

    func loadPersistedChamberMetadata() {
        guard let data = try? Data(contentsOf: chamberMetadataURL) else { return }

        if let decoded = try? JSONDecoder().decode(ChamberPresentationMetadata.self, from: data) {
            chamberMetadata = decoded
            persistChamberMetadata()
            return
        }

        guard let key = chamberStorageKey(),
              let sealed = try? AES.GCM.SealedBox(combined: data),
              let plaintext = try? AES.GCM.open(sealed, using: key),
              let decoded = try? JSONDecoder().decode(ChamberPresentationMetadata.self, from: plaintext) else {
            return
        }
        chamberMetadata = decoded
    }

    func persistChamberItems() {
        let directory = chamberItemsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let plaintext = try? JSONEncoder().encode(chamberStoredItems),
              let key = chamberStorageKey(),
              let sealed = try? AES.GCM.seal(plaintext, using: key).combined else {
            return
        }
        try? sealed.write(to: chamberItemsURL, options: .atomic)
    }

    func persistChamberMetadata() {
        let directory = chamberMetadataURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let plaintext = try? JSONEncoder().encode(chamberMetadata),
              let key = chamberStorageKey(),
              let sealed = try? AES.GCM.seal(plaintext, using: key).combined else {
            return
        }
        try? sealed.write(to: chamberMetadataURL, options: .atomic)
    }

    private func chamberStorageKey() -> SymmetricKey? {
        if let existing = keychainData(service: chamberStorageService, account: chamberStorageAccount) {
            return SymmetricKey(data: existing)
        }

        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        guard storeKeychainData(raw, service: chamberStorageService, account: chamberStorageAccount) else {
            return nil
        }
        return key
    }

    private func keychainData(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private func storeKeychainData(_ data: Data, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus != errSecItemNotFound {
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }
}
