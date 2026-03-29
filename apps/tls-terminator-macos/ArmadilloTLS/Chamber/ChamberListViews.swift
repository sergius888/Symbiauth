import SwiftUI

struct IndustrialChamberListPanelView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(panelTitle)
                        .font(.chamberMono(size: 14, weight: .semibold))
                        .foregroundStyle(ChamberTerminalTheme.textPrimary)
                    Text(panelSubtitle)
                        .font(.chamberMono(size: 9))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    filterButton
                    addButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, viewModel.chamberCategory == .shell ? 10 : 12)
            .frame(height: viewModel.chamberCategory == .shell ? 64 : 76, alignment: .top)

            Divider().overlay(ChamberTerminalTheme.panelStroke)

            if viewModel.chamberCategory == .shell {
                IndustrialTrustedShellPanelView(viewModel: viewModel)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if viewModel.chamberItems.isEmpty {
                            emptyBlock
                        } else {
                            ForEach(viewModel.chamberItems) { item in
                                IndustrialChamberListRow(
                                    item: item,
                                    selected: viewModel.selectedChamberItemId == item.id,
                                    revealedSecretValue: item.kind == .secret ? viewModel.revealedSecretValues[item.secretName ?? ""] : nil,
                                    revealButtonTitle: item.kind == .secret ? (viewModel.revealedSecretValues[item.secretName ?? ""] == nil ? "[REVEAL]" : "[HIDE]") : nil,
                                    onToggleRevealSecret: item.kind == .secret ? {
                                        viewModel.toggleReveal(for: item, selectItem: false)
                                    } : nil,
                                    onBlindCopySecret: item.kind == .secret ? {
                                        viewModel.copyChamberItem(item, selectItem: false)
                                    } : nil
                                ) {
                                    viewModel.selectChamberItem(item)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }

            Divider().overlay(ChamberTerminalTheme.panelStroke)

            HStack(spacing: 8) {
                Rectangle()
                    .fill(viewModel.hasActiveTrust ? ChamberTerminalTheme.accentAcid.opacity(0.75) : ChamberTerminalTheme.accentCopper.opacity(0.65))
                    .frame(width: 10, height: 2)
                    .opacity(viewModel.chamberActionStatus == nil ? 0 : 1)
                Text(viewModel.chamberActionStatus ?? " ")
                    .font(.chamberMono(size: 9))
                    .foregroundStyle(ChamberTerminalTheme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChamberTerminalTheme.panelFill)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var panelTitle: String {
        switch viewModel.chamberCategory {
        case .all: return "⌈ ALL ENTRIES ⌋"
        case .secrets: return "⌈ SECRET VAULT ⌋"
        case .notes: return "⌈ NOTE FIELD ⌋"
        case .documents: return "⌈ DOCUMENT BAY ⌋"
        case .shell: return "⌈ TRUSTED SHELL ⌋"
        case .favorites: return "⌈ PINNED ITEMS ⌋"
        }
    }

    private var panelSubtitle: String {
        switch viewModel.chamberCategory {
        case .all: return "Private workspace. Sealed at session end."
        case .secrets: return "Blind-copy or reveal live values while trust stays online."
        case .notes: return "Working notes held inside the chamber shell."
        case .documents: return "Preview records here or emit a temporary export while trusted."
        case .shell: return viewModel.trustedShellLive ? "Chamber shell with on-demand secret injection." : "Open a chamber-owned shell for sensitive commands."
        case .favorites: return "Pinned artifacts kept close to hand."
        }
    }

    @ViewBuilder
    private var addButton: some View {
        switch viewModel.chamberCategory {
        case .secrets:
            terminalActionButton("[+ NEW]") { viewModel.openNewChamberDraft(kind: .secret) }
        case .notes:
            terminalActionButton("[+ NEW]") { viewModel.openNewChamberDraft(kind: .note) }
        case .documents:
            terminalActionButton("[+ NEW]") { viewModel.openNewChamberDraft(kind: .document) }
        case .shell:
            EmptyView()
        default:
            Menu {
                Button("New Secret") { viewModel.openNewChamberDraft(kind: .secret) }
                Button("New Note") { viewModel.openNewChamberDraft(kind: .note) }
                Button("Import Document") { viewModel.openNewChamberDraft(kind: .document) }
            } label: {
                Text("[+ NEW]")
                    .font(.chamberMono(size: 10, weight: .medium))
                    .foregroundStyle(ChamberTerminalTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(ChamberTerminalTheme.rowFill)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .disabled(!viewModel.hasActiveTrust)
        }
    }

    private var filterButton: some View {
        Group {
            if viewModel.chamberCategory == .shell {
                EmptyView()
            } else {
                terminalActionButton(viewModel.chamberSelectedTagFilter == nil ? "[+ FILTER]" : "[FILTER*]") {
                    viewModel.toggleChamberFilter()
                }
            }
        }
    }

    private var emptyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No items yet.")
                .font(.chamberMono(size: 11, weight: .semibold))
                .foregroundStyle(ChamberTerminalTheme.textPrimary)
            Text(emptyHint)
                .font(.chamberMono(size: 9))
                .foregroundStyle(ChamberTerminalTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ChamberTerminalTheme.rowFill)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
    }

    private func terminalActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.chamberMono(size: 10, weight: .medium))
                .foregroundStyle(ChamberTerminalTheme.textSecondary.opacity(0.95))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(ChamberTerminalTheme.rowFill)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke.opacity(0.95), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.hasActiveTrust)
    }

    private var emptyHint: String {
        switch viewModel.chamberCategory {
        case .secrets:
            return "Create the first protected secret in this section."
        case .notes:
            return "Create the first private note for this chamber."
        case .documents:
            return "Import the first document you want available inside the chamber."
        case .shell:
            return "Open a trusted shell to work with chamber-managed secrets."
        case .favorites:
            return "Mark an item as favorite to pin it here."
        case .all:
            return "Create the first protected item in this chamber."
        }
    }
}

struct IndustrialChamberListRow: View {
    let item: ChamberItem
    let selected: Bool
    let revealedSecretValue: String?
    let revealButtonTitle: String?
    let onToggleRevealSecret: (() -> Void)?
    let onBlindCopySecret: (() -> Void)?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("• \(tagText)")
                            .font(.chamberMono(size: 8, weight: .medium))
                        if item.favorite {
                            Text("✦")
                                .font(.chamberMono(size: 9, weight: .semibold))
                                .foregroundStyle(ChamberTerminalTheme.accentCopper.opacity(0.9))
                        }
                    }
                    .foregroundStyle(ChamberTerminalTheme.textSecondary)

                    if let preview = previewText, !preview.isEmpty {
                        Text(preview)
                            .font(.chamberMono(size: 9))
                            .foregroundStyle(ChamberTerminalTheme.textMuted)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(item.title)
                        .font(.chamberMono(size: 11, weight: .semibold))
                        .foregroundStyle(ChamberTerminalTheme.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(metaText)
                        .font(.chamberMono(size: 9))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                        .lineLimit(2)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? ChamberTerminalTheme.rowHover : (hovered ? ChamberTerminalTheme.noiseFill : ChamberTerminalTheme.rowFill))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(selected ? ChamberTerminalTheme.accentRail.opacity(0.9) : Color.clear)
                        .frame(width: 2)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(selected ? ChamberTerminalTheme.accentRail.opacity(0.18) : (hovered ? ChamberTerminalTheme.panelStroke.opacity(0.9) : ChamberTerminalTheme.panelStroke), lineWidth: 1)
                )
                .overlay(alignment: .bottomLeading) {
                    if hovered || selected {
                        Text("░▒▓")
                            .font(.chamberMono(size: 7))
                            .foregroundStyle(ChamberTerminalTheme.textGhost)
                            .padding(.leading, 10)
                            .padding(.bottom, 6)
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }

            if revealButtonTitle != nil || onBlindCopySecret != nil {
                VStack(alignment: .trailing, spacing: 6) {
                    if let revealButtonTitle, let onToggleRevealSecret {
                        rowActionButton(revealButtonTitle, tint: ChamberTerminalTheme.textPrimary.opacity(0.86), action: onToggleRevealSecret)
                    }
                    if let onBlindCopySecret {
                        rowActionButton("[COPY>]", tint: ChamberTerminalTheme.accentCopper.opacity(0.92), action: onBlindCopySecret)
                    }
                }
                .padding(8)
            }
        }
    }

    private func rowActionButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.chamberMono(size: 8, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var tagText: String {
        switch item.kind {
        case .secret: return "SECRET"
        case .note: return "NOTE"
        case .document: return "DOC"
        }
    }

    private var previewText: String? {
        switch item.kind {
        case .secret:
            if let revealedSecretValue, !revealedSecretValue.isEmpty {
                return revealedSecretValue
            }
            return "························"
        case .note:
            return item.textContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .document:
            if let size = item.fileSize {
                return "\(item.fileName ?? item.title) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
            }
            return item.fileName ?? item.title
        }
    }

    private var metaText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let stamp = item.updatedAt
        switch item.kind {
        case .secret:
            if let opened = item.lastOpenedAt {
                return "opened \(formatter.localizedString(for: opened, relativeTo: Date()))"
            }
            if item.createdAt != Date.distantPast {
                return "created \(item.createdAt.formatted(date: .numeric, time: .omitted))"
            }
            return "stored locally"
        case .note:
            return "modified \(formatter.localizedString(for: stamp, relativeTo: Date()))"
        case .document:
            return "imported \(item.updatedAt.formatted(date: .numeric, time: .omitted))"
        }
    }
}

struct IndustrialChamberSearchPanelView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("⌈ SEARCH ⌋")
                    .font(.chamberMono(size: 13, weight: .semibold))
                    .foregroundStyle(ChamberTerminalTheme.textPrimary)
                HStack(spacing: 8) {
                    TextField("search chamber", text: $viewModel.chamberSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(ChamberTerminalTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(ChamberTerminalTheme.rowFill)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
                    Button(viewModel.chamberSelectedTagFilter == nil ? "[+ FILTER]" : "[FILTER*]") {
                        viewModel.toggleChamberFilter()
                    }
                    .buttonStyle(.plain)
                    .font(.chamberMono(size: 10, weight: .medium))
                    .foregroundStyle(ChamberTerminalTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(ChamberTerminalTheme.rowFill)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
                }
            }
            .padding(14)

            Divider().overlay(ChamberTerminalTheme.panelStroke)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if !viewModel.chamberSearchResults.isEmpty {
                        ForEach(viewModel.chamberSearchResults) { item in
                            IndustrialChamberListRow(
                                item: item,
                                selected: viewModel.selectedChamberItemId == item.id,
                                revealedSecretValue: item.kind == .secret ? viewModel.revealedSecretValues[item.secretName ?? ""] : nil,
                                revealButtonTitle: item.kind == .secret ? (viewModel.revealedSecretValues[item.secretName ?? ""] == nil ? "[REVEAL]" : "[HIDE]") : nil,
                                onToggleRevealSecret: item.kind == .secret ? {
                                    viewModel.toggleReveal(for: item, selectItem: false)
                                } : nil,
                                onBlindCopySecret: item.kind == .secret ? {
                                    viewModel.copyChamberItem(item, selectItem: false)
                                } : nil
                            ) {
                                viewModel.selectChamberItem(item)
                            }
                        }
                    } else if viewModel.chamberSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              viewModel.chamberSelectedTagFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        Text("Type to search secrets, notes, and documents.")
                            .font(.chamberMono(size: 9))
                            .foregroundStyle(ChamberTerminalTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        Text("No chamber items match this query.")
                            .font(.chamberMono(size: 9))
                            .foregroundStyle(ChamberTerminalTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 390, height: 620)
        .background(ChamberTerminalTheme.panelFill)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
