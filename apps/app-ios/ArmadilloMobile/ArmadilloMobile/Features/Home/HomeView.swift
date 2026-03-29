import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: PairingViewModel

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                header
                    .padding(.top, 16)

                Spacer(minLength: 24)

                sessionButtonSection

                Spacer(minLength: 28)

                statusGrid

                Spacer(minLength: 18)

                if let startSessionBlockedReason {
                    Text(startSessionBlockedReason)
                        .font(AppTypography.caption())
                        .foregroundStyle(AppTheme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 104)
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
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

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image("SymbiAuthMark")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            TerminalSectionHeader(
                kicker: "[ TRUST RELAY ]",
                title: "SymbiAuth",
                detail: "Phone presence unlocks your active Mac."
            )
        }
    }

    private var sessionButtonSection: some View {
        Button {
            if viewModel.trustSessionActive {
                viewModel.endTrustSession()
            } else {
                viewModel.startTrustSession()
            }
        } label: {
            SessionButton(
                isActive: viewModel.trustSessionActive,
                isEnabled: startSessionBlockedReason == nil || viewModel.trustSessionActive
            )
        }
        .buttonStyle(SessionButtonStyle(isActive: viewModel.trustSessionActive))
        .disabled(!viewModel.trustSessionActive && startSessionBlockedReason != nil)
    }

    private var statusGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                StatusGridCell(
                    title: "[ TRUST ]",
                    value: trustValue,
                    valueColor: trustValueColor
                )

                Divider()
                    .background(AppTheme.stroke)

                StatusGridCell(
                    title: "[ MODE ]",
                    value: trustModeValue,
                    valueColor: AppTheme.textPrimary
                )
            }

            Divider()
                .background(AppTheme.stroke)

            HStack(spacing: 0) {
                StatusGridCell(
                    title: "[ LINK ]",
                    value: viewModel.dataConnectionTitle.uppercased(),
                    valueColor: viewModel.dataConnectionTint
                )

                Divider()
                    .background(AppTheme.stroke)

                StatusGridCell(
                    title: "[ NODE ]",
                    value: activeNodeValue,
                    valueColor: AppTheme.textPrimary
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(AppTheme.panelStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .stroke(AppTheme.strokeStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
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

    private var trustValue: String {
        viewModel.trustSessionTitle.uppercased()
    }

    private var trustValueColor: Color {
        if viewModel.trustSessionTitle == "Locked" {
            return AppTheme.textPrimary
        }
        return viewModel.trustSessionTint
    }

    private var trustModeValue: String {
        let raw = viewModel.lastTrustMode.lowercased()
        switch raw {
        case "strict":
            return "STRICT"
        case "office":
            return "OFFICE"
        default:
            return "TTL"
        }
    }

    private var activeNodeValue: String {
        if viewModel.activeMacId == nil {
            return "NO MAC"
        }
        return viewModel.activeMacLabel.uppercased()
    }
}

private struct StatusGridCell: View {
    let title: String
    let value: String
    let valueColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppTypography.caption(11))
                .foregroundStyle(AppTheme.textSecondary)
                .tracking(1.4)

            Text(value)
                .font(AppTypography.heading(17))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .allowsTightening(true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
