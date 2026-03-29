import SwiftUI

struct HubView: View {
    @ObservedObject var viewModel: PairingViewModel

    private var activeMac: PairedMac? {
        guard let activeId = viewModel.activeMacId else { return nil }
        return viewModel.pairedMacs.first(where: { $0.macId == activeId })
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 16) {
                    TerminalSectionHeader(
                        kicker: "[ CONTROL HUB ]",
                        title: "Companion Hub",
                        detail: "Choose an active Mac, inspect trust state, and launch sessions."
                    )
                    .padding(.top, 10)

                    StatusCard(
                        title: "[ DATA LINK ]",
                        value: viewModel.dataConnectionTitle,
                        detail: viewModel.dataConnectionDetail,
                        tint: viewModel.dataConnectionTint
                    )

                    StatusCard(
                        title: "[ TRUST SESSION ]",
                        value: viewModel.trustSessionTitle,
                        detail: viewModel.trustSessionDetail,
                        tint: viewModel.trustSessionTint
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("[ ACTIVE MAC ]")
                            .font(AppTypography.heading(18))
                            .foregroundStyle(AppTheme.textPrimary)

                        if let activeMac {
                            Text(activeMac.label)
                                .font(AppTypography.heading(20))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text("ID: …\(activeMac.macId.suffix(12))")
                                .font(AppTypography.caption())
                                .foregroundStyle(AppTheme.textSecondary)
                        } else {
                            Text("No active Mac selected")
                                .font(AppTypography.body(15))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appPanel()

                    PairedMacListView(
                        pairedMacs: viewModel.pairedMacs,
                        activeMacId: viewModel.activeMacId,
                        onSetActiveMac: { viewModel.setActiveMac($0) },
                        onRenameMac: { macId, label in viewModel.renameMac(macId, label: label) },
                        onRemoveMac: { viewModel.removeMac($0) }
                    )
                    .frame(minHeight: 160, maxHeight: 300)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.panel)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.stroke, lineWidth: 1)
                    )

                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.and.hand.point.up.left")
                            .foregroundStyle(AppTheme.textSecondary)
                        Text("Long-press a Mac row to rename or remove.")
                            .font(AppTypography.caption())
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Start Session") {
                        viewModel.startTrustSession()
                    }
                    .buttonStyle(PrimaryPillButton())
                    .disabled(!viewModel.hasActiveMacWithTrustKeys || !AppSettings.shared.blePresence)

                    if startSessionBlockedReason != nil {
                        Text(startSessionBlockedReason!)
                            .font(AppTypography.caption())
                            .foregroundStyle(AppTheme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: {
                        viewModel.startQRScanning()
                    }) {
                        Label("Scan QR to Add Mac", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(SecondaryPillButton())

                    NavigationLink {
                        SettingsScreen(viewModel: viewModel)
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(SecondaryPillButton())
                }
                .padding()
            }
        }
        .sheet(isPresented: $viewModel.showingQRScanner) {
            QRScannerView { payload in
                viewModel.handleQRPayload(payload)
            }
        }
        .alert("Recovery Phrase (Dev)", isPresented: $viewModel.showRecoveryPhraseAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.recoveryPhraseAlertText)
        }
    }

    private var startSessionBlockedReason: String? {
        if !AppSettings.shared.blePresence {
            return "BLE presence is disabled. Enable it in Settings to start trust proofs."
        }
        if !viewModel.hasActiveMacWithTrustKeys {
            return "Select an active Mac with trust keys before starting a session."
        }
        return nil
    }
}

private struct StatusCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppTypography.heading(16))
                .foregroundStyle(AppTheme.textPrimary)
            Text(value)
                .font(AppTypography.heading(22))
                .foregroundStyle(tint)
            Text(detail)
                .font(AppTypography.caption())
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel()
    }
}
