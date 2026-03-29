import Foundation

extension PreferencesViewModel {
    func refreshTrust() {
        let req: [String: Any] = [
            "type": "trust.status",
            "corr_id": corrId()
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                if (response["ok"] as? Bool) == false {
                    self.lastError = response["error"] as? String ?? "trust.status_failed"
                    return
                }

                let snapshot = self.trustSnapshotProvider()
                let state = response["state"] as? String ?? "unknown"
                let mode = response["mode"] as? String ?? "background_ttl"
                let trustId = (response["trust_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "none"
                let deadlineMs = response["deadline_ms"] as? UInt64
                let event = snapshot?.event ?? "none"
                let reason = snapshot?.reason ?? ""

                self.diagnostics = TrustDiagnostics(
                    state: state,
                    mode: mode,
                    trustId: trustId,
                    deadlineMs: deadlineMs,
                    event: event,
                    reason: reason
                )
                self.recordTrustEventIfNeeded(event: event, reason: reason, trustId: trustId)
                self.lastRefreshAt = Date()
            }
        }
    }

    func refreshLaunchers() {
        let req: [String: Any] = [
            "type": "launcher.list",
            "corr_id": corrId()
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                guard (response["ok"] as? Bool) == true,
                      let rows = response["launchers"] as? [[String: Any]] else {
                    self.lastError = response["error"] as? String ?? self.lastError
                    return
                }
                let previousRows = self.launcherRows
                let newRows: [LauncherRow] = rows.compactMap { row in
                    guard let id = row["id"] as? String else { return nil }
                    return LauncherRow(
                        id: id,
                        name: row["name"] as? String ?? id,
                        description: row["description"] as? String ?? "",
                        execPath: row["exec_path"] as? String ?? "",
                        args: row["args"] as? [String] ?? [],
                        cwd: row["cwd"] as? String ?? "",
                        secretRefs: row["secret_refs"] as? [String] ?? [],
                        enabled: (row["enabled"] as? Bool) == true,
                        running: (row["running"] as? Bool) == true,
                        trustPolicy: row["trust_policy"] as? String ?? "continuous",
                        singleInstance: (row["single_instance"] as? Bool) != false,
                        lastError: row["last_error"] as? String
                    )
                }
                self.launcherRows = newRows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.recordLauncherStateTransitions(previous: previousRows, current: self.launcherRows)
                self.launcherCount = self.launcherRows.count
                self.runningLaunchers = self.launcherRows.filter { $0.running }.count
                if let selected = self.selectedLauncherId,
                   self.launcherRows.contains(where: { $0.id == selected }) {
                    // keep existing selection
                } else {
                    self.selectedLauncherId = self.launcherRows.first?.id
                }
                self.lastRefreshAt = Date()
            }
        }
    }

    func refreshLauncherTemplates() {
        let req: [String: Any] = [
            "type": "launcher.template.list",
            "corr_id": corrId()
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                guard (response["ok"] as? Bool) == true,
                      let rows = response["templates"] as? [[String: Any]] else {
                    self.lastError = response["error"] as? String ?? self.lastError
                    return
                }
                self.launcherTemplateRows = rows.compactMap { row in
                    guard let templateId = row["template_id"] as? String,
                          let name = row["name"] as? String,
                          let launcher = row["launcher"] as? [String: Any] else { return nil }
                    return LauncherTemplateRow(
                        id: templateId,
                        name: name,
                        description: launcher["description"] as? String ?? "",
                        execPath: launcher["exec_path"] as? String ?? "",
                        args: launcher["args"] as? [String] ?? [],
                        cwd: launcher["cwd"] as? String ?? "",
                        secretRefs: launcher["secret_refs"] as? [String] ?? [],
                        trustPolicy: launcher["trust_policy"] as? String ?? "continuous"
                    )
                }
                self.selectedTemplateId = self.selectedTemplateId ?? self.launcherTemplateRows.first?.id
            }
        }
    }

    func selectedLauncher() -> LauncherRow? {
        guard let selectedLauncherId else { return nil }
        return launcherRows.first(where: { $0.id == selectedLauncherId })
    }

    func trustPolicyLabel(_ raw: String) -> String {
        switch raw {
        case "start_only":
            return "Start only"
        default:
            return "Stops on trust loss"
        }
    }

    func trustPolicyHelp(_ raw: String) -> String {
        switch raw {
        case "start_only":
            return "This session keeps running after start, even if trust ends."
        default:
            return "This session is terminated automatically when trust ends."
        }
    }

    func loadSelectedLauncherIntoDraft() {
        guard let row = selectedLauncher() else { return }
        draftLauncherId = row.id
        draftLauncherName = row.name
        draftLauncherDescription = row.description
        draftLauncherExecPath = row.execPath
        draftLauncherArgsCsv = row.args.joined(separator: ", ")
        draftLauncherCwd = row.cwd
        draftLauncherSecretRefsCsv = row.secretRefs.joined(separator: ", ")
        draftLauncherEnabled = row.enabled
        draftLauncherSingleInstance = row.singleInstance
        draftLauncherTrustPolicy = row.trustPolicy
    }

    func newLauncherDraft() {
        selectedLauncherId = nil
        draftLauncherId = ""
        draftLauncherName = ""
        draftLauncherDescription = ""
        draftLauncherExecPath = "/bin/zsh"
        draftLauncherArgsCsv = ""
        draftLauncherCwd = ""
        draftLauncherSecretRefsCsv = ""
        draftLauncherEnabled = true
        draftLauncherSingleInstance = true
        draftLauncherTrustPolicy = "continuous"
        launcherActionStatus = "New managed session draft."
    }

    func applySelectedTemplate() {
        guard let selectedTemplateId,
              let template = launcherTemplateRows.first(where: { $0.id == selectedTemplateId }) else {
            launcherActionStatus = "Select a template first."
            return
        }

        selectedLauncherId = nil
        draftLauncherId = template.id
        draftLauncherName = template.name
        draftLauncherDescription = template.description
        draftLauncherExecPath = template.execPath
        draftLauncherArgsCsv = template.args.joined(separator: ", ")
        draftLauncherCwd = template.cwd
        draftLauncherSecretRefsCsv = template.secretRefs.joined(separator: ", ")
        draftLauncherEnabled = true
        draftLauncherSingleInstance = true
        draftLauncherTrustPolicy = template.trustPolicy
        launcherActionStatus = "Template loaded into draft. Review host, auth, ports, and paths before saving."
    }

    func saveLauncherDraft() {
        let id = draftLauncherId.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draftLauncherName.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty || name.isEmpty {
            launcherActionStatus = "Managed session ID and name are required."
            return
        }
        let command = draftLauncherExecPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty {
            launcherActionStatus = "Save failed: Command is required."
            return
        }
        if !command.hasPrefix("/") {
            launcherActionStatus = "Save failed: Command should be an absolute path (e.g. /bin/zsh)."
            return
        }
        let cwd = draftLauncherCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cwd.isEmpty {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
                launcherActionStatus = "Save failed: Working Directory must point to an existing folder."
                return
            }
        }
        let launcherPayload: [String: Any] = [
            "id": id,
            "name": name,
            "description": draftLauncherDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            "exec_path": command,
            "args": parseCsv(draftLauncherArgsCsv),
            "cwd": cwd,
            "secret_refs": parseCsv(draftLauncherSecretRefsCsv),
            "trust_policy": draftLauncherTrustPolicy,
            "single_instance": draftLauncherSingleInstance,
            "enabled": draftLauncherEnabled
        ]
        let req: [String: Any] = [
            "type": "launcher.upsert",
            "corr_id": corrId(),
            "launcher": launcherPayload
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                if (response["ok"] as? Bool) == true {
                    let created = (response["created"] as? Bool) == true
                    self.launcherActionStatus = created ? "Managed session created." : "Managed session updated."
                    self.selectedLauncherId = id
                    self.refreshLaunchers()
                } else {
                    let err = response["error"] as? String ?? "launcher_upsert_failed"
                    self.launcherActionStatus = self.formatLauncherError(err, operation: "save")
                    self.lastError = err
                }
            }
        }
    }

    func deleteSelectedLauncher() {
        guard let launcherId = selectedLauncherId else {
            launcherActionStatus = "Select a managed session first."
            return
        }
        let req: [String: Any] = [
            "type": "launcher.delete",
            "corr_id": corrId(),
            "launcher_id": launcherId
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                if (response["ok"] as? Bool) == true {
                    self.launcherActionStatus = "Managed session deleted."
                    self.newLauncherDraft()
                    self.refreshLaunchers()
                } else {
                    let err = response["error"] as? String ?? "launcher_delete_failed"
                    self.launcherActionStatus = self.formatLauncherError(err, operation: "delete")
                    self.lastError = err
                }
            }
        }
    }

    func runSelectedLauncher() {
        guard let launcherId = selectedLauncherId else {
            launcherActionStatus = "Select a managed session first."
            return
        }
        let sessionName = selectedLauncher()?.name ?? launcherId
        let req: [String: Any] = [
            "type": "launcher.run",
            "corr_id": corrId(),
            "launcher_id": launcherId
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                if (response["ok"] as? Bool) == true {
                    self.launcherActionStatus = "\"\(sessionName)\" started. It will remain active only while trust stays active."
                    self.appendHistory(
                        category: .session,
                        title: "Managed Session Started",
                        detail: "\"\(sessionName)\" was launched under the current hardware link."
                    )
                    self.refreshLaunchers()
                } else {
                    let err = response["error"] as? String ?? "launcher_run_failed"
                    self.launcherActionStatus = self.formatLauncherError(err, operation: "run")
                    self.lastError = err
                }
            }
        }
    }

    func refreshSecrets() {
        let req: [String: Any] = [
            "type": "secret.list",
            "corr_id": corrId()
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                guard (response["ok"] as? Bool) == true,
                      let rows = response["secrets"] as? [[String: Any]] else {
                    self.lastError = response["error"] as? String ?? self.lastError
                    return
                }
                self.secretRows = rows.compactMap { row in
                    guard let name = row["name"] as? String else { return nil }
                    return SecretRow(
                        name: name,
                        available: (row["available"] as? Bool) == true,
                        usedBy: row["used_by"] as? [String] ?? [],
                        status: row["status"] as? String ?? "",
                        createdAt: (row["created_at_ms"] as? UInt64).map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                    )
                }
                self.secretRows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.availableSecrets = self.secretRows.filter { $0.available }.count
                self.missingSecrets = self.secretRows.count - self.availableSecrets
                if let selected = self.selectedSecretName,
                   self.secretRows.contains(where: { $0.name == selected }) {
                    // keep existing selection
                } else {
                    self.selectedSecretName = self.secretRows.first?.name
                }
                if let selected = self.selectedChamberItemId,
                   self.secretRows.contains(where: { "secret:\($0.name)" == selected }) == false,
                   !self.chamberStoredItems.contains(where: { "\($0.kind.rawValue):\($0.id.uuidString)" == selected }) {
                    self.selectedChamberItemId = nil
                }
                self.ensureChamberSelection()
                self.lastRefreshAt = Date()
            }
        }
    }

    func refreshTrustConfig() {
        let req: [String: Any] = [
            "type": "trust.config.get",
            "corr_id": corrId()
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                guard (response["ok"] as? Bool) == true else {
                    let err = response["error"] as? String ?? "trust_config_get_failed"
                    self.settingsStatus = self.formatTrustConfigError(err, operation: "load")
                    return
                }
                self.settingsMode = response["mode"] as? String ?? self.settingsMode
                if let ttl = response["background_ttl_secs"] as? UInt64 {
                    self.settingsBackgroundTTL = String(ttl)
                }
                if let office = response["office_idle_secs"] as? UInt64 {
                    self.settingsOfficeIdle = String(office)
                }
            }
        }
    }

    func saveTrustConfig() {
        let ttlRaw = settingsBackgroundTTL.trimmingCharacters(in: .whitespacesAndNewlines)
        let officeRaw = settingsOfficeIdle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ttl = UInt64(ttlRaw), let office = UInt64(officeRaw) else {
            settingsStatus = "Save failed: Background TTL and Office Idle must be numbers."
            return
        }
        guard (30...3600).contains(ttl) else {
            settingsStatus = "Save failed: Background TTL must be between 30 and 3600 seconds."
            return
        }
        guard office >= 30 else {
            settingsStatus = "Save failed: Office Idle must be at least 30 seconds."
            return
        }
        let req: [String: Any] = [
            "type": "trust.config.set",
            "corr_id": corrId(),
            "mode": settingsMode,
            "background_ttl_secs": ttl,
            "office_idle_secs": office
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                if (response["ok"] as? Bool) == true {
                    self.settingsMode = (response["mode"] as? String) ?? self.settingsMode
                    if let ttl = response["background_ttl_secs"] as? UInt64 {
                        self.settingsBackgroundTTL = String(ttl)
                    }
                    if let office = response["office_idle_secs"] as? UInt64 {
                        self.settingsOfficeIdle = String(office)
                    }
                    self.settingsStatus = "Trust settings saved and applied live."
                    self.refresh()
                } else {
                    let err = response["error"] as? String ?? "trust_config_set_failed"
                    self.settingsStatus = self.formatTrustConfigError(err, operation: "save")
                    self.lastError = err
                }
            }
        }
    }

    func selectedSecret() -> SecretRow? {
        guard let selectedSecretName else { return nil }
        return secretRows.first(where: { $0.name == selectedSecretName })
    }

    func testSelectedSecret() {
        guard let name = selectedSecretName else {
            secretActionStatus = "Select a secret first."
            return
        }
        let req: [String: Any] = [
            "type": "secret.test",
            "corr_id": corrId(),
            "name": name
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                if (response["ok"] as? Bool) == true {
                    let available = (response["available"] as? Bool) == true
                    self.secretActionStatus = available ? "Test passed: secret is available." : "Test result: secret missing."
                } else {
                    let err = response["error"] as? String ?? "secret_test_failed"
                    self.secretActionStatus = self.formatSecretError(err, operation: "test")
                    self.lastError = err
                }
                self.refreshSecrets()
            }
        }
    }

    func saveDraftSecret(completion: ((Bool, String) -> Void)? = nil) {
        let name = draftSecretName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            secretActionStatus = "Secret name is required."
            completion?(false, secretActionStatus ?? "Secret name is required.")
            return
        }
        if draftSecretValue.isEmpty {
            secretActionStatus = "Secret value is required."
            completion?(false, secretActionStatus ?? "Secret value is required.")
            return
        }

        let req: [String: Any] = [
            "type": "secret.set",
            "corr_id": corrId(),
            "name": name,
            "value": draftSecretValue
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                if (response["ok"] as? Bool) == true {
                    let created = (response["created"] as? Bool) == true
                    self.secretActionStatus = created ? "Secret added." : "Secret updated."
                    self.draftSecretValue = ""
                    self.selectedSecretName = name
                    self.refreshSecrets()
                    completion?(true, self.secretActionStatus ?? "Secret saved.")
                } else {
                    let err = response["error"] as? String ?? "secret_set_failed"
                    self.secretActionStatus = self.formatSecretError(err, operation: "save")
                    self.lastError = err
                    completion?(false, self.secretActionStatus ?? "Secret save failed.")
                }
            }
        }
    }

    func deleteSelectedSecret() {
        guard let name = selectedSecretName else {
            secretActionStatus = "Select a secret first."
            return
        }
        let req: [String: Any] = [
            "type": "secret.delete",
            "corr_id": corrId(),
            "name": name
        ]
        sendToAgent(req) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                if (response["ok"] as? Bool) == true {
                    let affected = response["affected_launchers"] as? [String] ?? []
                    if affected.isEmpty {
                        self.secretActionStatus = "Secret deleted."
                    } else {
                        self.secretActionStatus = "Secret deleted. Affected sessions: \(affected.joined(separator: ", "))"
                    }
                    self.chamberMetadata.favoriteSecretNames.remove(name)
                    self.chamberMetadata.recentSecretAccess.removeValue(forKey: name)
                    self.chamberMetadata.secretTags.removeValue(forKey: name)
                    self.chamberMetadata.secretConfigurations.removeValue(forKey: name)
                    self.persistChamberMetadata()
                    self.selectedSecretName = nil
                    self.refreshSecrets()
                } else {
                    let err = response["error"] as? String ?? "secret_delete_failed"
                    self.secretActionStatus = self.formatSecretError(err, operation: "delete")
                    self.lastError = err
                }
            }
        }
    }

    func corrId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).compactMap { _ in chars.randomElement() })
    }

    private func parseCsv(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func secretStatusLabel(_ raw: String) -> String {
        switch raw {
        case "missing":
            return "Missing"
        case "access_denied", "keychain_access_denied":
            return "Access denied"
        case "backend_disabled", "keychain_backend_disabled":
            return "Backend disabled"
        case "ok":
            return "Available"
        case "":
            return ""
        default:
            return raw.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func formatLauncherError(_ error: String, operation: String) -> String {
        let detail: String
        switch error {
        case "trust_not_active":
            detail = "Establish the hardware link before starting managed sessions."
        case "already_running":
            detail = "Managed session is already running (single instance is enabled)."
        case "invalid_launcher":
            detail = "One or more managed-session fields are invalid. Review the inputs."
        case "id_duplicate":
            detail = "Managed session ID already exists. Use a unique ID."
        case "launcher_not_found":
            detail = "Selected managed session no longer exists. Refresh and try again."
        case "config_write_failed", "config_reload_failed":
            detail = "Could not persist managed-session configuration."
        default:
            detail = error
        }
        return "\(operation.capitalized) failed: \(detail)"
    }

    func formatSecretError(_ error: String, operation: String) -> String {
        let detail: String
        switch error {
        case "trust_not_active":
            detail = "Start a trust session to modify secrets."
        case "secret_not_found":
            detail = "Secret not found in Keychain."
        case "keychain_access_denied":
            detail = "Keychain access denied. Check macOS permission prompts."
        case "keychain_backend_disabled":
            detail = "Keychain backend is disabled in this build."
        case "invalid_secret_name":
            detail = "Secret name must be 1–128 chars: A-Z, a-z, 0-9, _, -, ."
        case "value_too_large":
            detail = "Secret value exceeds the 8KB limit."
        case "keychain_write_failed":
            detail = "Could not write secret to Keychain."
        default:
            detail = error
        }
        return "\(operation.capitalized) failed: \(detail)"
    }

    private func formatTrustConfigError(_ error: String, operation: String) -> String {
        let detail: String
        switch error {
        case "trust_config_get_failed":
            detail = "Could not load trust settings."
        case "trust_config_set_failed":
            detail = "Could not save trust settings."
        default:
            if error.contains("write_failed") || error.contains("save_failed") {
                detail = "Could not write trust settings file."
            } else {
                detail = error
            }
        }
        return "\(operation.capitalized) failed: \(detail)"
    }

    var parsedArgsPreview: String {
        let parsed = parseCsv(draftLauncherArgsCsv)
        if parsed.isEmpty {
            return "Parsed args: none"
        }
        return "Parsed args (\(parsed.count)): \(parsed.joined(separator: " | "))"
    }

    var modeAppliesBackgroundTTL: Bool {
        settingsMode.lowercased() == "background_ttl"
    }

    var modeAppliesOfficeIdle: Bool {
        settingsMode.lowercased() == "office"
    }

    func appendHistory(category: SessionHistoryEntry.Category, title: String, detail: String) {
        if let last = sessionHistory.first,
           last.title == title,
           last.detail == detail,
           Date().timeIntervalSince(last.timestamp) < 1.0 {
            return
        }
        sessionHistory.insert(
            SessionHistoryEntry(timestamp: Date(), category: category, title: title, detail: detail),
            at: 0
        )
        if sessionHistory.count > 40 {
            sessionHistory.removeLast(sessionHistory.count - 40)
        }
        persistSessionHistory()
    }

    func loadPersistedSessionHistory() {
        guard let data = try? Data(contentsOf: sessionHistoryURL) else { return }
        guard let decoded = try? JSONDecoder().decode([SessionHistoryEntry].self, from: data) else { return }
        sessionHistory = decoded.sorted { $0.timestamp > $1.timestamp }
    }

    private func persistSessionHistory() {
        let dir = sessionHistoryURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(sessionHistory)
            try data.write(to: sessionHistoryURL, options: .atomic)
        } catch {
            lastError = "session_history_persist_failed: \(error.localizedDescription)"
        }
    }

    private func recordTrustEventIfNeeded(event: String, reason: String, trustId: String) {
        guard !event.isEmpty, event != "none" else { return }
        let signature = "\(event)|\(reason)|\(trustId)"
        guard signature != lastObservedTrustEventSignature else { return }
        lastObservedTrustEventSignature = signature

        switch event {
        case "granted":
            appendHistory(
                category: .trust,
                title: "Hardware Link Granted",
                detail: "Trusted presence was granted for the current Mac."
            )
        case "signal_present":
            appendHistory(
                category: .trust,
                title: "Phone Detected",
                detail: "The Mac detected nearby trusted phone presence."
            )
        case "signal_lost":
            lastRevocationContext = (Date(), reason.isEmpty ? "signal_lost" : reason)
            appendHistory(
                category: .trust,
                title: "Signal Lost",
                detail: "Trusted phone presence dropped. Managed sessions may be terminated by policy."
            )
        case "revoked":
            let revokeReason = reason.isEmpty ? "trust_ended" : reason
            lastRevocationContext = (Date(), revokeReason)
            appendHistory(
                category: .trust,
                title: "Hardware Link Ended",
                detail: "Trust ended with reason: \(revokeReason.replacingOccurrences(of: "_", with: " "))."
            )
        default:
            break
        }
    }

    private func recordLauncherStateTransitions(previous: [LauncherRow], current: [LauncherRow]) {
        let previousMap = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for row in current {
            guard let old = previousMap[row.id] else { continue }
            if old.running && !row.running {
                if let revoke = lastRevocationContext,
                   Date().timeIntervalSince(revoke.timestamp) < 15 {
                    appendHistory(
                        category: .session,
                        title: "Managed Session Terminated",
                        detail: "\"\(row.name)\" ended because trust was lost (\(revoke.reason.replacingOccurrences(of: "_", with: " ")))."
                    )
                } else {
                    appendHistory(
                        category: .session,
                        title: "Managed Session Stopped",
                        detail: "\"\(row.name)\" is no longer running."
                    )
                }
            }
        }
    }
}
