import SwiftUI

struct SessionTabView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Session")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Monitor the current trust link, paired-device state, and runtime readiness that powers the chamber.")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                card {
                    row("Trust State", viewModel.diagnostics.state)
                    row("Mode", viewModel.diagnostics.mode)
                    row("Trust ID", viewModel.diagnostics.trustId)
                    row("Latest Event", viewModel.diagnostics.event)
                    if !viewModel.diagnostics.reason.isEmpty {
                        row("Reason", viewModel.diagnostics.reason)
                    }
                    row("Deadline", formatDeadline(viewModel.diagnostics.deadlineMs))
                }

                card {
                    row("Managed Sessions", "\(viewModel.launcherCount)")
                    row("Running", "\(viewModel.runningLaunchers)")
                    row("Secrets Available", "\(viewModel.availableSecrets)")
                    row("Secrets Missing", "\(viewModel.missingSecrets)")
                    row("Last Refresh", formatDate(viewModel.lastRefreshAt))
                    row("Offline Revoke Window", "~\(viewModel.settingsPresenceTimeout)s")
                }

                if let err = viewModel.lastError, !err.isEmpty {
                    card {
                        Text("Last Error")
                            .font(.headline)
                        Text(err)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Spacer()
                    Button("Refresh") { viewModel.refresh() }
                    Spacer()
                }
                .padding(.top, 8)

                if !viewModel.sessionHistory.isEmpty {
                    card {
                        Text("Recent History")
                            .font(.headline)
                        ForEach(viewModel.sessionHistory.prefix(6)) { entry in
                            HStack(alignment: .top) {
                                Circle()
                                    .fill(entry.category == .trust ? Color.orange : Color.green)
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                    Text(entry.detail)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                    Text(formatDate(entry.timestamp))
                                        .foregroundStyle(.secondary)
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear { viewModel.refresh() }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
        .font(.system(size: 13, weight: .regular, design: .rounded))
    }

    private func formatDate(_ value: Date?) -> String {
        guard let value else { return "never" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: value)
    }

    private func formatDeadline(_ ms: UInt64?) -> String {
        guard let ms else { return "none" }
        let deadline = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: deadline)
    }
}

struct HistoryTabView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("History")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Recent trust and chamber-related events. This stays visible after the live session ends.")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                if viewModel.sessionHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No history yet.")
                            .font(.headline)
                        Text("Start a trust session or run a protected action to populate the timeline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
                    .padding(16)
                    .background(Color.white.opacity(0.035))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.sessionHistory) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(entry.category == .trust ? Color.orange : Color.green)
                                    .frame(width: 8, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(entry.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.035))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(20)
        }
        .onAppear { viewModel.refresh() }
    }
}

struct PreferencesRootView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        TabView {
            ChamberHomeTabView(viewModel: viewModel)
                .tabItem { Label("Chamber", systemImage: "lock.shield.fill") }

            HistoryTabView(viewModel: viewModel)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            SessionTabView(viewModel: viewModel)
                .tabItem { Label("Session", systemImage: "waveform.path.ecg") }

            SettingsTabView(viewModel: viewModel)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(
            LinearGradient(
                colors: [Color.black, Color(red: 0.05, green: 0.06, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .frame(minWidth: 1080, minHeight: 740)
    }
}

struct SettingsTabView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Trust Settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Changes apply immediately and are persisted to ~/.armadillo/trust.yaml.")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Trust Mode")
                        .font(.headline)
                    Picker("Trust Mode", selection: $viewModel.settingsMode) {
                        Text("Background TTL").tag("background_ttl")
                        Text("Strict").tag("strict")
                        Text("Office").tag("office")
                    }
                    .pickerStyle(.segmented)
                    Text(modeHelperText(for: viewModel.settingsMode))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Background TTL (secs)")
                                .font(.headline)
                            TextField("300", text: $viewModel.settingsBackgroundTTL)
                                .textFieldStyle(.roundedBorder)
                                .disabled(!viewModel.modeAppliesBackgroundTTL)
                            Text("Range: 30–3600 seconds.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Office Idle (secs)")
                                .font(.headline)
                            TextField("900", text: $viewModel.settingsOfficeIdle)
                                .textFieldStyle(.roundedBorder)
                                .disabled(!viewModel.modeAppliesOfficeIdle)
                            Text("Minimum: 30 seconds.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Offline Presence Timeout (secs)")
                            .font(.headline)
                        TextField("12", text: $viewModel.settingsPresenceTimeout)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        Text("Read-only watchdog window (from ARM_TRUST_PRESENCE_TIMEOUT_SECS, clamped 5–60).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 580)
                .padding(12)
                .background(panelFill)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(panelStroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Parked Features")
                        .font(.headline)
                    Text("Managed Sessions and the earlier DevOps-oriented surfaces are preserved in the codebase but removed from the main product path while Secret Chamber becomes the primary experience.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Reason:")
                        .font(.caption.weight(.semibold))
                    Text("The chamber must read as a coherent private workspace. Tunnel/session tooling remains available for later reactivation, but it should no longer define the app shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 580, alignment: .leading)
                .padding(12)
                .background(panelFill)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(panelStroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    Button("Refresh") { viewModel.refreshTrustConfig() }
                    Button("Apply") { viewModel.saveTrustConfig() }
                }
                if let status = viewModel.settingsStatus, !status.isEmpty {
                    Text(status)
                        .foregroundStyle(status.lowercased().contains("failed") ? .orange : .green)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
                Text("New mode applies immediately to current trust controller.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Tip: Use menubar Trust Mode for quick switching during live sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .onAppear { viewModel.refreshTrustConfig() }
        }
    }

    private func modeHelperText(for raw: String) -> String {
        switch raw.lowercased() {
        case "strict":
            return "Strict: trust revokes immediately when signal is lost."
        case "office":
            return "Office: trust remains active while idle timeout window is valid."
        default:
            return "Background TTL: on signal loss, grace countdown starts before revoke."
        }
    }

    private var panelFill: Color { Color.white.opacity(0.035) }
    private var panelStroke: Color { Color.white.opacity(0.08) }
}
