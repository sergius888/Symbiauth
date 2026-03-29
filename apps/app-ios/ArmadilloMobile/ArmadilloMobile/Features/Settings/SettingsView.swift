import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @AppStorage("dev_tools_unlocked") private var devToolsUnlocked: Bool = false
    @State private var versionTapCount: Int = 0
    @State private var showForgetEndpointConfirm: Bool = false
    @State private var showDevDiagnostics: Bool = false
    @State private var showDevVault: Bool = false
    @State private var showDevProximity: Bool = false
    @State private var showDevRecovery: Bool = false
    let onForgetEndpoint: () -> Void
    let onCopyRecoveryPhrase: () -> Void
    let onSetDevMode: (Bool) -> Void
    let devMode: Bool
    let onPingTest: () -> Void
    let onVaultTest: () -> Void
    let onDevWriteSample: () -> Void
    let onDevReadSample: () -> Void
    let onDevReadFoo: () -> Void
    let onDevReadBar: () -> Void
    let onDevCredGet: () -> Void
    let onDevCredSeed: () -> Void
    let onDevProxIntent: () -> Void
    let onDevProxPause: () -> Void
    let onDevProxResume: () -> Void
    let onDevProxStatus: () -> Void
    let onGeneratePhrase: () -> Void
    let onStartRekey: () -> Void
    let onCommitRekey: () -> Void
    let onAbortRekey: () -> Void
    let pendingRekeyToken: String?
    let rekeySecondsLeft: Int

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TerminalSectionHeader(
                        kicker: "[ LOCAL SETTINGS ]",
                        title: "Settings",
                        detail: "Tune connection behavior and local app controls."
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Connection")
                        settingsToggle("Auto-connect", isOn: $settings.autoConnectEnabled)
                        settingsToggle("BLE presence", isOn: $settings.blePresence)
                        settingsToggle("JSON logs", isOn: $settings.jsonLogs)
                        settingsToggle("Redact sensitive data", isOn: $settings.redactLogs)
                    }
                    .appPanel()

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Account")
                        Button("Forget all paired Macs") {
                            showForgetEndpointConfirm = true
                        }
                        .foregroundStyle(AppTheme.danger)
                        .font(AppTypography.body(17))
                    }
                    .appPanel()

                    if devToolsUnlocked {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader("Developer")
                            settingsToggle("Developer Mode", isOn: Binding(
                                get: { devMode },
                                set: { onSetDevMode($0) }
                            ))

                            if devMode {
                                DisclosureGroup("Diagnostics", isExpanded: $showDevDiagnostics) {
                                    devActionButton("Ping test", action: onPingTest)
                                    devActionButton("Vault test", action: onVaultTest)
                                }

                                DisclosureGroup("Vault Experiments", isExpanded: $showDevVault) {
                                    devActionButton("Write sample_test=hello", action: onDevWriteSample)
                                    devActionButton("Read sample_test", action: onDevReadSample)
                                    devActionButton("Read foo", action: onDevReadFoo)
                                    devActionButton("Read bar", action: onDevReadBar)
                                    devActionButton("Cred get bank demo", action: onDevCredGet)
                                    devActionButton("Seed bank credential", action: onDevCredSeed)
                                }

                                DisclosureGroup("Proximity Experiments", isExpanded: $showDevProximity) {
                                    devActionButton("Prox intent", action: onDevProxIntent)
                                    devActionButton("Prox pause 5m", action: onDevProxPause)
                                    devActionButton("Prox resume", action: onDevProxResume)
                                    devActionButton("Prox status", action: onDevProxStatus)
                                }

                                DisclosureGroup("Recovery (Dev)", isExpanded: $showDevRecovery) {
                                    devActionButton("Copy recovery phrase", action: onCopyRecoveryPhrase)
                                    devActionButton("Generate phrase", action: onGeneratePhrase)
                                    devActionButton("Start rekey (30s)", action: onStartRekey)

                                    if pendingRekeyToken != nil {
                                        Text("Rekey in progress: \(rekeySecondsLeft)s")
                                            .font(AppTypography.caption())
                                            .foregroundStyle(AppTheme.textSecondary)
                                        devActionButton("Commit rekey", action: onCommitRekey)
                                        devActionButton("Abort rekey", role: .destructive, action: onAbortRekey)
                                    }
                                }
                            } else {
                                Text("Enable Developer Mode to view advanced tools.")
                                    .font(AppTypography.body(14))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                        .appPanel()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("About")
                        HStack {
                            Text("Version")
                                .font(AppTypography.body(15))
                            Spacer()
                            Text(appVersionText)
                                .font(AppTypography.caption())
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !devToolsUnlocked else { return }
                            versionTapCount += 1
                            if versionTapCount >= 7 {
                                devToolsUnlocked = true
                                versionTapCount = 0
                            }
                        }

                        if !devToolsUnlocked {
                            Text("Tap version 7 times to unlock developer tools.")
                                .font(AppTypography.caption())
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .appPanel()
                }
                .padding()
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget local pairing data?", isPresented: $showForgetEndpointConfirm, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                onForgetEndpoint()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved endpoint and disconnects current trust setup.")
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text("[ \(title.uppercased()) ]")
            .font(AppTypography.caption(12))
            .foregroundStyle(AppTheme.textSecondary)
            .tracking(1.6)
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(AppTypography.body(16))
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    private func devActionButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(AppTypography.body(14))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(role == .destructive ? AppTheme.danger : AppTheme.textPrimary)
        .padding(.vertical, 2)
    }
}
