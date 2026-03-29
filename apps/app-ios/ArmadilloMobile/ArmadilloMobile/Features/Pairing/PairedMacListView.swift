import SwiftUI

struct PairedMacListView: View {
    let pairedMacs: [PairedMac]
    let activeMacId: String?
    let onSetActiveMac: (String) -> Void
    let onRenameMac: ((String, String) -> Void)?
    let onRemoveMac: ((String) -> Void)?
    @State private var renameTarget: PairedMac?
    @State private var renameDraft: String = ""

    var body: some View {
        if pairedMacs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("[ NO PAIRED MACS ]")
                    .font(AppTypography.heading(15))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Scan a QR code from your Mac to seed the registry.")
                    .font(AppTypography.body(14))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        } else {
            LazyVStack(spacing: 10) {
                ForEach(pairedMacs) { mac in
                    Button(action: {
                        onSetActiveMac(mac.macId)
                    }) {
                        HStack(alignment: .center, spacing: 14) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(AppTheme.accent.opacity(activeMacId == mac.macId ? 1.0 : 0.12))
                                .frame(width: 12, height: 56)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(mac.label)
                                    .font(AppTypography.heading(16))
                                    .foregroundStyle(AppTheme.textPrimary)

                                Text("ID: …\(mac.macId.suffix(12))")
                                    .font(AppTypography.caption())
                                    .foregroundStyle(AppTheme.textSecondary)

                                if mac.wrapPubB64 == nil {
                                    Text("⚠ Pairing incomplete — proximity unavailable")
                                        .font(AppTypography.caption(12))
                                        .foregroundStyle(AppTheme.warning)
                                }
                            }

                            Spacer()

                            if activeMacId == mac.macId {
                                Text("[ ACTIVE ]")
                                    .font(AppTypography.caption())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(AppTheme.accent.opacity(0.14))
                                    .foregroundStyle(AppTheme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(AppTheme.panelStrong)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(AppTheme.stroke, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if onRenameMac != nil {
                            Button {
                                renameTarget = mac
                                renameDraft = mac.label
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                        }
                        if let onRemove = onRemoveMac {
                            Button(role: .destructive) {
                                onRemove(mac.macId)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if let onRemove = onRemoveMac {
                            Button(role: .destructive) {
                                onRemove(mac.macId)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .alert("Rename Mac", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Mac label", text: $renameDraft)
                Button("Save") {
                    guard let target = renameTarget else { return }
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onRenameMac?(target.macId, trimmed)
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) {
                    renameTarget = nil
                }
            } message: {
                if let target = renameTarget {
                    Text("Set a custom label for …\(target.macId.suffix(12))")
                }
            }
        }
    }
}
