import SwiftUI

struct MacsView: View {
    @ObservedObject var viewModel: PairingViewModel

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TerminalSectionHeader(
                        kicker: "[ PAIRED NODES ]",
                        title: "Mac Registry",
                        detail: "Choose the active node and manage local pairing records."
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        Button(action: {
                            viewModel.startQRScanning()
                        }) {
                            Label("Scan QR to Add Mac", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(PrimaryPillButton())

                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.and.hand.point.up.left")
                                .foregroundStyle(AppTheme.textSecondary)
                            Text("Tap a row to make it active. Long-press to rename or remove.")
                                .font(AppTypography.caption())
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .appPanel()

                    PairedMacListView(
                        pairedMacs: viewModel.pairedMacs,
                        activeMacId: viewModel.activeMacId,
                        onSetActiveMac: { viewModel.setActiveMac($0) },
                        onRenameMac: { macId, label in viewModel.renameMac(macId, label: label) },
                        onRemoveMac: { viewModel.removeMac($0) }
                    )
                    .appPanel()
                }
                .padding()
            }
        }
        .navigationTitle("Macs")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $viewModel.showingQRScanner) {
            QRScannerView { payload in
                viewModel.handleQRPayload(payload)
            }
        }
    }
}
