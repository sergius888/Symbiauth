import SwiftUI

struct SessionView: View {
    @ObservedObject var viewModel: PairingViewModel

    var body: some View {
        ZStack {
            SessionBackground()

            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image("SymbiAuthMark")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    TerminalKicker(text: "[ TRUSTED SESSION ]", tint: AppTheme.ferroTextSecondary)

                    Text("SymbiAuth")
                        .font(AppTypography.title(32))
                        .foregroundStyle(AppTheme.ferroTextPrimary)
                        .tracking(1.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)

                    Text("Hardware presence is currently authorizing your active Mac")
                        .font(AppTypography.body(16))
                        .foregroundStyle(AppTheme.ferroTextSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }

                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    VStack(spacing: 18) {
                        HStack {
                            HStack(spacing: 8) {
                                Image(systemName: viewModel.trustSessionSymbol)
                                Text(viewModel.trustSessionTitle.uppercased())
                            }
                            .font(AppTypography.heading(17))
                            .foregroundStyle(viewModel.trustSessionTint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(viewModel.trustSessionTint.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            Spacer()

                            Text(trustModeLabel(viewModel.lastTrustMode).uppercased())
                                .font(AppTypography.caption(12))
                                .foregroundStyle(AppTheme.ferroTextSecondary)
                                .tracking(1.8)
                        }

                        Text(viewModel.trustSessionDetail(at: context.date))
                            .font(AppTypography.body(17))
                            .foregroundStyle(AppTheme.ferroTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()
                            .overlay(AppTheme.ferroStroke)

                        SessionMetricRow(
                            title: "ACTIVE NODE",
                            value: viewModel.activeMacLabel.uppercased(),
                            tint: AppTheme.ferroTextPrimary
                        )
                        SessionMetricRow(
                            title: "TRUST LINK",
                            value: viewModel.trustedSessionLinkTitle,
                            detail: viewModel.trustedSessionLinkDetail,
                            tint: viewModel.trustedSessionLinkTint
                        )
                        SessionMetricRow(
                            title: "DATA LINK",
                            value: viewModel.trustedSessionDataLinkTitle,
                            detail: viewModel.trustedSessionDataLinkDetail,
                            tint: viewModel.dataConnectionTint
                        )
                        SessionMetricRow(
                            title: "LAST PROOF",
                            value: viewModel.lastProofText(at: context.date).uppercased(),
                            tint: AppTheme.ferroTextPrimary
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .ferroPanel()
                }

                Text("Backgrounding iOS immediately ends the trust session.")
                    .font(AppTypography.caption())
                    .foregroundStyle(AppTheme.ferroTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Button("End Session", role: .destructive) {
                    viewModel.endTrustSession()
                }
                .buttonStyle(DangerPillButton())
            }
            .padding()
        }
        .interactiveDismissDisabled(true)
        .onAppear {
            viewModel.refreshTrustStatusFromMac()
        }
        .onReceive(Timer.publish(every: 4.0, on: .main, in: .common).autoconnect()) { _ in
            viewModel.refreshTrustStatusFromMac()
        }
    }

    private func trustModeLabel(_ rawMode: String) -> String {
        let raw = rawMode.lowercased()
        switch raw {
        case "strict":
            return "Strict"
        case "office":
            return "Office"
        default:
            return "Background TTL"
        }
    }
}

private struct SessionMetricRow: View {
    let title: String
    let value: String
    var detail: String? = nil
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppTypography.caption(11))
                .foregroundStyle(AppTheme.ferroTextSecondary)
                .tracking(1.6)

            Text(value)
                .font(AppTypography.heading(21))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AppTypography.caption(11))
                    .foregroundStyle(AppTheme.ferroTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}
