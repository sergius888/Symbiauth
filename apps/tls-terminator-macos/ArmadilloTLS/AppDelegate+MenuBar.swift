import Cocoa

// MARK: - Menu Bar Support

extension AppDelegate {
    
    func setupMenuBar() {
        print("🔧 Creating status bar item...")
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = statusItem?.button {
                button.image = stableStatusBarImage()
                button.toolTip = "SymbiAuth"
                print("✅ Status bar button created with stable icon")
            } else {
                print("❌ Failed to get status item button")
                return
            }
        }
        trustMenuRefreshTimer?.invalidate()
        trustMenuRefreshTimer = Timer.scheduledTimer(withTimeInterval: launcherListRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshStatusMenu()
        }
        RunLoop.main.add(trustMenuRefreshTimer!, forMode: .common)
        refreshStatusMenu()
        print("✅ Menu bar setup complete")
    }
    
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let titleItem = NSMenuItem(title: "SymbiAuth", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let (statusLine, subtitleLine) = trustHeaderLines()
        let statusItem = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        let subtitleItem = NSMenuItem(title: subtitleLine, action: nil, keyEquivalent: "")
        subtitleItem.isEnabled = false
        menu.addItem(subtitleItem)
        menu.addItem(NSMenuItem.separator())

        let trustModeRoot = NSMenuItem(title: "Trust Mode", action: nil, keyEquivalent: "")
        menu.setSubmenu(buildTrustModeSubmenu(), for: trustModeRoot)
        menu.addItem(trustModeRoot)
        menu.addItem(NSMenuItem.separator())

        let chamberItem = NSMenuItem(title: trustedActionsEnabled() ? "Open Secret Chamber" : "Secret Chamber (Locked)", action: #selector(openSecretChamber), keyEquivalent: "")
        chamberItem.isEnabled = trustedActionsEnabled()
        menu.addItem(chamberItem)

        menu.addItem(NSMenuItem.separator())
        if trustedActionsEnabled() {
            let endSession = NSMenuItem(title: "End Session", action: #selector(endSession), keyEquivalent: "")
            menu.addItem(endSession)
        } else {
            let hint = NSMenuItem(title: "Locked — open the iPhone app to unlock the chamber", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(NSMenuItem.separator())
        let qrItem = NSMenuItem(title: "Show Pairing QR Code", action: #selector(showPairingQR), keyEquivalent: "")
        menu.addItem(qrItem)
        menu.addItem(buildSettingsMenuItem())
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        return menu
    }
    
    @objc func onAllowedClientsChanged() {
        DispatchQueue.main.async {
            self.refreshStatusMenu()
            self.preferencesWindowController?.refresh()
        }
    }

    @objc func onTrustStateChanged() {
        DispatchQueue.main.async {
            self.refreshStatusMenu()
            self.sharedPreferencesViewModel?.refreshTrustStateOnly()
            self.handleChamberLifecycleForCurrentTrustState()
            self.preferencesWindowController?.refreshTrustStateOnly()
        }
    }

    private func refreshStatusMenu() {
        updateStatusBarIcon()
        statusItem?.menu = buildStatusMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        openMenuRefreshTimer?.invalidate()
        openMenuRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak menu] _ in
            guard let self, let menu else { return }
            self.updateOpenMenuHeader(menu)
        }
        if let openMenuRefreshTimer {
            RunLoop.main.add(openMenuRefreshTimer, forMode: .common)
        }
        updateOpenMenuHeader(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenuRefreshTimer?.invalidate()
        openMenuRefreshTimer = nil
    }

    private func updateOpenMenuHeader(_ menu: NSMenu) {
        guard menu.items.count >= 3 else { return }
        let (statusLine, subtitleLine) = trustHeaderLines()
        menu.items[1].title = statusLine
        menu.items[2].title = subtitleLine
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        button.image = stableStatusBarImage()
        button.toolTip = "SymbiAuth"
    }

    private func stableStatusBarImage() -> NSImage? {
        let image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "SymbiAuth")
        image?.isTemplate = true
        return image
    }

    private enum TrustVisualState {
        case trusted
        case countdown
        case locked
        case idle
    }

    private func trustVisualState() -> TrustVisualState {
        guard let snapshot = tlsServer?.latestTrustState else {
            return .idle
        }
        let hasActiveTrust = snapshot.trustId?.isEmpty == false
        if snapshot.event == "revoked" {
            return .locked
        }
        if !hasActiveTrust {
            return .locked
        }
        if countdownRemaining(from: snapshot) != nil {
            return .countdown
        }
        if snapshot.event == "granted" || snapshot.event == "signal_present" || snapshot.event == "signal_lost" {
            return .trusted
        }
        return .idle
    }

    private func trustStateDescription() -> String {
        guard let snapshot = tlsServer?.latestTrustState else {
            return "No session"
        }

        if snapshot.event == "revoked" {
            return "Locked"
        }

        if let remaining = countdownRemaining(from: snapshot) {
            return "Trusted — \(remaining) remaining"
        }

        let mode = (snapshot.mode ?? currentTrustModeEnv()).lowercased()
        return "Trusted — \(trustModeLabel(for: mode))"
    }

    private func trustedActionsEnabled() -> Bool {
        switch trustVisualState() {
        case .trusted, .countdown:
            return true
        case .locked, .idle:
            return false
        }
    }

    private func trustHeaderLines() -> (String, String) {
        switch trustVisualState() {
        case .trusted:
            return ("✅ Trusted", "Phone connected · \(trustModeLabel(for: effectiveTrustModeForMenu())) mode")
        case .countdown:
            let remaining = tlsServer?.latestTrustState.flatMap { countdownRemaining(from: $0) }
            return ("⏱ Signal lost", "Revoking in \(remaining ?? "0:00")")
        case .locked:
            return ("🔒 Locked", "Start a session from your iPhone")
        case .idle:
            return ("🔒 Locked", "Start a session from your iPhone")
        }
    }

    private func countdownRemaining(from snapshot: BLETrustCentral.TrustStateSnapshot) -> String? {
        guard (snapshot.mode ?? currentTrustModeEnv()).lowercased() == "background_ttl",
              let deadlineMs = snapshot.deadlineMs else {
            return nil
        }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        if deadlineMs <= nowMs {
            return "0:00"
        }
        let secs = Int((deadlineMs - nowMs) / 1000)
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    private func trustModeLabel(for rawMode: String) -> String {
        switch rawMode.lowercased() {
        case "strict":
            return "Strict"
        case "office":
            return "Office"
        default:
            return "Background TTL"
        }
    }

    private func currentTrustModeEnv() -> String {
        let raw = (ProcessInfo.processInfo.environment["ARM_TRUST_MODE"] ?? "background_ttl").lowercased()
        switch raw {
        case "strict", "background_ttl", "office":
            return raw
        default:
            return "background_ttl"
        }
    }

    private func pairedPhoneSuffix() -> String? {
        guard let fp = tlsServer?.loadAllowedClientFingerprints().first else { return nil }
        let suffix = fp.suffix(8)
        return String(suffix)
    }

    private func buildSettingsMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if let fingerprint = deviceFingerprint {
            let fingerprintItem = NSMenuItem(title: "Fingerprint: \(fingerprint.suffix(16))", action: nil, keyEquivalent: "")
            fingerprintItem.isEnabled = false
            submenu.addItem(fingerprintItem)
        }
        let port = tlsServer?.port ?? 0
        let portText = port > 0 ? "Port: \(port)" : "Port: Starting..."
        let portItem = NSMenuItem(title: portText, action: nil, keyEquivalent: "")
        portItem.isEnabled = false
        submenu.addItem(portItem)
        let trustStateItem = NSMenuItem(title: "State: \(trustStateDescription())", action: nil, keyEquivalent: "")
        trustStateItem.isEnabled = false
        submenu.addItem(trustStateItem)
        let openPreferences = NSMenuItem(title: "Open Preferences…", action: #selector(openPreferencesWindow), keyEquivalent: "p")
        submenu.addItem(openPreferences)
        if let phoneSuffix = pairedPhoneSuffix() {
            let phoneItem = NSMenuItem(title: "iPhone: ...\(phoneSuffix)", action: nil, keyEquivalent: "")
            phoneItem.isEnabled = false
            submenu.addItem(phoneItem)
        }
        submenu.addItem(NSMenuItem.separator())

        if ProcessInfo.processInfo.environment["ARM_FEATURE_PIN_UI"] == "1" {
            let paired = tlsServer?.loadAllowedClientFingerprints() ?? []
            let pairedMenu = NSMenu()
            for fp in paired.sorted() {
                let shortFp = String(fp.suffix(12))
                let item = NSMenuItem(title: "\(shortFp) · Revoke", action: #selector(revokeClient(_:)), keyEquivalent: "")
                item.representedObject = fp
                pairedMenu.addItem(item)
            }
            if paired.isEmpty {
                let empty = NSMenuItem(title: "(none)", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                pairedMenu.addItem(empty)
            }
            let pairedRoot = NSMenuItem(title: "Paired Devices", action: nil, keyEquivalent: "")
            submenu.setSubmenu(pairedMenu, for: pairedRoot)
            submenu.addItem(pairedRoot)

            let resetItem = NSMenuItem(title: "Reset Server Identity…", action: #selector(resetServerIdentity), keyEquivalent: "")
            submenu.addItem(resetItem)
            submenu.addItem(NSMenuItem.separator())
        }

        let bridgeInstallItem = NSMenuItem(title: "Install/Repair Browser Bridge", action: #selector(installBrowserBridge), keyEquivalent: "")
        submenu.addItem(bridgeInstallItem)
        let bridgeRemoveItem = NSMenuItem(title: "Remove Browser Bridge Manifest", action: #selector(removeBrowserBridge), keyEquivalent: "")
        submenu.addItem(bridgeRemoveItem)
        submenu.addItem(NSMenuItem.separator())
        let parkedItem = NSMenuItem(title: "Parked features remain preserved in the codebase", action: nil, keyEquivalent: "")
        parkedItem.isEnabled = false
        submenu.addItem(parkedItem)

        root.submenu = submenu
        return root
    }

    private func buildTrustModeSubmenu() -> NSMenu {
        let menu = NSMenu()
        let currentMode = effectiveTrustModeForMenu()
        let rows: [(String, String)] = [
            ("strict", "Strict"),
            ("background_ttl", "Background TTL"),
            ("office", "Office")
        ]
        for (mode, label) in rows {
            let item = NSMenuItem(title: label, action: #selector(selectTrustMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = (mode == currentMode) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func effectiveTrustModeForMenu() -> String {
        if let selectedTrustModeOverride, !selectedTrustModeOverride.isEmpty {
            return selectedTrustModeOverride
        }
        if let mode = tlsServer?.latestTrustState?.mode, !mode.isEmpty {
            return mode.lowercased()
        }
        return currentTrustModeEnv()
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func endSession() {
        let req: [String: Any] = [
            "type": "trust.revoke",
            "reason": "manual_end",
            "corr_id": randomCorrId()
        ]
        tlsServer?.sendToAgent(json: req) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshStatusMenu()
            }
        }
    }

    @objc private func selectTrustMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        let getReq: [String: Any] = [
            "type": "trust.config.get",
            "corr_id": randomCorrId()
        ]
        tlsServer?.sendToAgent(json: getReq) { [weak self] getResponse in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard (getResponse["ok"] as? Bool) == true else {
                    let err = getResponse["error"] as? String ?? "trust_config_get_failed"
                    self.presentInfoAlert(title: "Trust Mode Update Failed", message: err)
                    return
                }
                let ttl = (getResponse["background_ttl_secs"] as? UInt64) ?? 300
                let office = (getResponse["office_idle_secs"] as? UInt64) ?? 900
                let setReq: [String: Any] = [
                    "type": "trust.config.set",
                    "corr_id": self.randomCorrId(),
                    "mode": mode,
                    "background_ttl_secs": ttl,
                    "office_idle_secs": office
                ]
                self.tlsServer?.sendToAgent(json: setReq) { [weak self] setResponse in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        if (setResponse["ok"] as? Bool) == true {
                            let appliedMode = (setResponse["mode"] as? String ?? mode).lowercased()
                            let appliedTtl: UInt64 = {
                                if let v = setResponse["background_ttl_secs"] as? UInt64 { return v }
                                if let v = setResponse["background_ttl_secs"] as? Int { return UInt64(max(v, 0)) }
                                if let v = setResponse["background_ttl_secs"] as? NSNumber { return v.uint64Value }
                                return ttl
                            }()
                            self.selectedTrustModeOverride = appliedMode
                            self.tlsServer?.applyTrustRuntimeConfig(mode: appliedMode, backgroundTtlSecs: appliedTtl)
                            self.refreshStatusMenu()
                            self.preferencesWindowController?.refresh()
                        } else {
                            let err = setResponse["error"] as? String ?? "trust_config_set_failed"
                            self.presentInfoAlert(title: "Trust Mode Update Failed", message: err)
                        }
                    }
                }
            }
        }
    }

    private func randomCorrId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).compactMap { _ in chars.randomElement() })
    }

    @MainActor @objc func openPreferencesWindow() {
        if preferencesWindowController == nil {
            preferencesWindowController = makePreferencesWindowController()
        }
        preferencesWindowController?.showAndActivate()
    }

    @MainActor @objc func openSecretChamber() {
        guard trustedActionsEnabled() else { return }
        if chamberWindowController == nil {
            chamberWindowController = makeChamberWindowController()
        }
        chamberDismissedByUser = false
        sharedPreferencesViewModel?.resetChamberTransientState()
        chamberWindowController?.showChamber()
        sharedPreferencesViewModel?.refreshTrustStateOnly()
    }

    @MainActor
    private func makePreferencesWindowController() -> PreferencesWindowController {
        PreferencesWindowController(viewModel: sharedViewModel())
    }

    @MainActor
    private func makeChamberWindowController() -> SecretChamberWindowController {
        SecretChamberWindowController(
            viewModel: sharedViewModel(),
            onManualClose: { [weak self] in
                guard let self else { return }
                self.chamberDismissedByUser = true
                self.manuallyDismissedChamberTrustId = self.currentTrustId()
            },
            onEndSession: { [weak self] in
                self?.endSession()
            }
        )
    }

    @MainActor
    func sharedViewModel() -> PreferencesViewModel {
        if let sharedPreferencesViewModel {
            return sharedPreferencesViewModel
        }

        let vm = PreferencesViewModel(
            sendToAgent: { [weak self] json, completion in
                guard let self else { completion([:]); return }
                self.tlsServer?.sendToAgent(json: json) { response in
                    if (json["type"] as? String) == "trust.config.set",
                       (response["ok"] as? Bool) == true {
                        let mode = (response["mode"] as? String
                                   ?? json["mode"] as? String
                                   ?? "background_ttl").lowercased()
                        let ttl: UInt64 = {
                            if let v = response["background_ttl_secs"] as? UInt64 { return v }
                            if let v = response["background_ttl_secs"] as? Int { return UInt64(max(v, 0)) }
                            if let v = response["background_ttl_secs"] as? NSNumber { return v.uint64Value }
                            if let v = json["background_ttl_secs"] as? UInt64 { return v }
                            if let v = json["background_ttl_secs"] as? Int { return UInt64(max(v, 0)) }
                            if let v = json["background_ttl_secs"] as? NSNumber { return v.uint64Value }
                            return 300
                        }()
                        self.selectedTrustModeOverride = mode
                        self.tlsServer?.applyTrustRuntimeConfig(mode: mode, backgroundTtlSecs: ttl)
                    }
                    completion(response)
                }
            },
            trustSnapshotProvider: { [weak self] in
                self?.tlsServer?.latestTrustState
            }
        )
        sharedPreferencesViewModel = vm
        return vm
    }
    
    @objc func showPairingQR() {
        print("🔍 showPairingQR called")
        
        guard let fingerprint = deviceFingerprint,
              let instanceName = bonjourService?.instanceName else {
            print("❌ QR: Cannot show QR - missing fingerprint or instance name")
            NSLog("QR: Cannot show QR - missing fingerprint or instance name")
            return
        }
        
        let port = tlsServer?.port ?? 0
        guard port > 0 else {
            print("❌ QR: Cannot show QR - TLS server not ready")
            NSLog("QR: Cannot show QR - TLS server not ready")
            return
        }
        
        print("✅ QR: Creating window with fingerprint: \(fingerprint), instance: \(instanceName), port: \(port)")
        
        // Create or show existing QR window
        if qrDisplayWindow == nil {
            print("🆕 Creating new QR display window")
            qrDisplayWindow = QRDisplayWindow(sessionManager: pairingSessionManager)
        } else {
            print("♻️ Reusing existing QR display window")
        }
        
        print("📱 Showing QR code...")
        qrDisplayWindow?.showQRCode(
            instanceName: instanceName,
            serviceType: "_armadillo._tcp",
            fingerprint: fingerprint,
            port: Int(port)
        )
        
        print("🪟 Making window key and front...")
        qrDisplayWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("✅ QR window should now be visible")
    }

    @objc func revokeClient(_ sender: NSMenuItem) {
        guard let fp = sender.representedObject as? String else { return }
        // Remove from TLS allowed list
        tlsServer?.removeAllowedClientFingerprint(fp)
        // Telemetry
        let shortFp = String(fp.suffix(12))
        tlsServer?.publicLog([
            "event": "pin.revoke.applied",
            "fp": shortFp,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "role": "tls"
        ])
        // Optional: kick active connections immediately and lock vault
        if ProcessInfo.processInfo.environment["ARM_TLS_KICK_ON_REVOKE"] == "1" {
            tlsServer?.kickAllConnections(reason: "revoke")
            // Lock vault via agent (best-effort)
            tlsServer?.publicLog([
                "event": "pin.revoke.kicked",
                "ts": ISO8601DateFormatter().string(from: Date()),
                "role": "tls",
                "kicked": true
            ])
            tlsServer?.publicLog([
                "event": "vault.lock",
                "role": "tls",
                "reason": "revoke",
                "ts": ISO8601DateFormatter().string(from: Date())
            ])
        }
    }
    
    @objc func resetServerIdentity() {
        // Telemetry: requested
        tlsServer?.publicLog([
            "event": "pin.reset.requested",
            "ts": ISO8601DateFormatter().string(from: Date()),
            "role": "tls"
        ])
        // Rotate identity
        do {
            guard let (newId, newFp) = try certificateManager?.rotateIdentity() else { return }
            // Stop services
            bonjourService?.stop()
            tlsServer?.stop()
            enrollmentServer?.stop()
            // Update state
            deviceIdentity = newId
            deviceFingerprint = newFp
            // Clear allowed clients
            tlsServer?.clearAllowedClients()
            // Enable provisioning mode (TOFU allowed only right after reset)
            do {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let path = home + "/.armadillo/pin_state.json"
                let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let obj: [String: Any] = [
                    "provisioning": true,
                    "set_at": ISO8601DateFormatter().string(from: Date())
                ]
                let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                let attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o600))]
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
            } catch {
                logger.error("Failed to set provisioning state: \(error.localizedDescription)")
            }
            tlsServer?.publicLog([
                "event": "pin.provisioning.enabled",
                "ts": ISO8601DateFormatter().string(from: Date()),
                "role": "tls"
            ])
            // Recreate TLS server with new identity
            tlsServer = try TLSServer(identity: newId, fingerprint: newFp)
            tlsServer.onReady = { [weak self] port in
                try? self?.bonjourService.publish(port: port)
                self?.logger.info("TLS server listening on port \(port)")
            }
            try tlsServer.start()
            // Telemetry: applied
            tlsServer?.publicLog([
                "event": "pin.reset.applied",
                "new_fp": newFp.suffix(16),
                "ts": ISO8601DateFormatter().string(from: Date()),
                "role": "tls"
            ])
        } catch {
            logger.error("Reset identity failed: \(error.localizedDescription)")
        }
    }

    private func currentTrustId() -> String? {
        guard let trustId = tlsServer?.latestTrustState?.trustId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trustId.isEmpty else {
            return nil
        }
        return trustId
    }

    @MainActor
    func handleChamberLifecycleForCurrentTrustState() {
        guard let viewModel = sharedPreferencesViewModel else { return }

        guard let trustId = currentTrustId(), trustedActionsEnabled() else {
            lastAutoOpenedChamberTrustId = nil
            manuallyDismissedChamberTrustId = nil
            chamberDismissedByUser = false
            viewModel.resetChamberTransientState()
            viewModel.clearRevealedSecrets()
            viewModel.clearProtectedClipboardIfNeeded()
            viewModel.cleanupTemporaryExportsIfNeeded()
            viewModel.terminateTrustedShell(reason: "trust_ended")
            chamberWindowController?.closeChamber()
            return
        }

        if chamberWindowController == nil {
            chamberWindowController = makeChamberWindowController()
        }

        if chamberWindowController?.isChamberVisible == true {
            return
        }

        guard chamberDismissedByUser == false else { return }
        guard manuallyDismissedChamberTrustId == nil || manuallyDismissedChamberTrustId != trustId else { return }
        guard lastAutoOpenedChamberTrustId == nil else { return }

        lastAutoOpenedChamberTrustId = trustId
        viewModel.resetChamberTransientState()
        chamberWindowController?.showChamber()
    }
}
