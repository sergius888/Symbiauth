import SwiftUI

struct SecretChamberWorkspaceView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    let onEndSession: () -> Void
    @State private var inlineNoteDraft: String = ""
    @State private var inlineEditingNoteID: String?

    var body: some View {
        VStack(spacing: 0) {
            chamberHeader
            chamberStatusStrip
            Divider().overlay(Color.white.opacity(0.05))

            HStack(spacing: 0) {
                chamberSidebar
                Divider().overlay(Color.white.opacity(0.05))
                chamberMainArea
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(Color(red: 0.045, green: 0.045, blue: 0.05))
        .sheet(isPresented: $viewModel.showingChamberEditor) {
            ChamberItemEditorSheet(viewModel: viewModel)
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.selectedChamberItemId)
        .onAppear {
            viewModel.ensureChamberSelection()
            syncInlineNoteEditor()
        }
        .onChange(of: viewModel.selectedChamberItemId) { _ in
            syncInlineNoteEditor()
        }
        .onChange(of: viewModel.hasActiveTrust) { trusted in
            if !trusted {
                inlineEditingNoteID = nil
            } else {
                syncInlineNoteEditor()
            }
        }
    }

    private var chamberHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Secret Chamber")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text(viewModel.hasActiveTrust
                     ? "Your private workspace is open while iPhone trust remains active."
                     : "The chamber is sealed. Open the iPhone app to reveal protected content.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 10) {
                TextField("Search chamber", text: $viewModel.chamberSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 238)

                HStack(spacing: 8) {
                    if viewModel.protectedClipboardActive {
                        chamberBadge(
                            "Clipboard Armed",
                            tint: Color.orange,
                            fill: Color.orange.opacity(0.12)
                        )
                    }
                    chamberBadge(
                        viewModel.chamberTrustStateLabel,
                        tint: viewModel.hasActiveTrust ? Color.green : Color.orange,
                        fill: (viewModel.hasActiveTrust ? Color.green : Color.orange).opacity(0.12)
                    )
                    Button("End Session", action: onEndSession)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.red.opacity(0.92))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(Color.red.opacity(0.08))
                        )
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(Color.white.opacity(0.025))
    }

    private var chamberStatusStrip: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(viewModel.hasActiveTrust ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .opacity(viewModel.chamberActionStatus == nil ? 0 : 1)
            Text(viewModel.chamberActionStatus ?? " ")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 34)
        .background(Color.white.opacity(0.014))
    }

    private var chamberSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Workspace")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.34))
                .textCase(.uppercase)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            ForEach(sidebarCategories, id: \.rawValue) { category in
                Button {
                    viewModel.selectChamberCategory(category)
                } label: {
                    sidebarLabel(sidebarTitle(for: category), active: viewModel.chamberCategory == category)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Text("Mode")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.34))
                    .textCase(.uppercase)
                Text(viewModel.chamberTrustStateLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(viewModel.hasActiveTrust ? Color.green : Color.orange)
                Text(viewModel.hasActiveTrust ? "Chamber content stays visible while the paired iPhone remains active." : "The chamber is sealed until trust returns.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(chamberPanelFill)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(chamberPanelStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding(20)
        .frame(width: 214, alignment: .topLeading)
        .background(Color.white.opacity(0.014))
    }

    private var chamberMainArea: some View {
        HStack(spacing: 0) {
            chamberContent
            if viewModel.selectedChamberItem != nil {
                Divider().overlay(Color.white.opacity(0.05))
                chamberDetail
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var chamberContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            chamberSectionHeader

            if viewModel.chamberItems.isEmpty {
                chamberEmptyState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: viewModel.selectedChamberItem == nil ? 248 : 220), spacing: 18)
                        ],
                        spacing: 18
                    ) {
                        ForEach(viewModel.chamberItems) { item in
                            chamberCard(item)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                }
                .clipped()
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var chamberSectionHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.chamberCategory.title)
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                Text(contentIntroText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .frame(maxWidth: 420, alignment: .leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 62, alignment: .topLeading)

            Spacer(minLength: 12)

            addButton
                .frame(minWidth: 140, alignment: .trailing)
        }
    }

    private var chamberEmptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: emptyStateIconName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
            Text(emptyStateTitle)
                .font(.title3.weight(.semibold))
            Text(emptyStateBody)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(maxWidth: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !viewModel.hasActiveTrust {
                Text("Open the iPhone app to unseal the chamber, then add your first protected item.")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        .background(chamberPanelFill)
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(chamberPanelStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var chamberDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = viewModel.selectedChamberItem {
                selectedDetailPanel(item)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 360, alignment: .topLeading)
        .background(Color.white.opacity(0.014))
    }

    private func selectedDetailPanel(_ item: ChamberItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Detail")
                        .font(.headline)
                    chamberBadge(
                        item.kind == .secret ? "SECRET" : item.kind == .note ? "NOTE" : "DOCUMENT",
                        tint: chamberItemTint(item),
                        fill: chamberItemTint(item).opacity(0.14)
                    )
                }
                Spacer()
                Button {
                    viewModel.selectedChamberItemId = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .padding(8)
                }
                .buttonStyle(.plain)
            }

            Text(item.title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)

            if !item.note.isEmpty {
                Text(item.note)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            detailContent(item)

            if !item.tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .textCase(.uppercase)
                    Text(item.tags.joined(separator: " · "))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            }

            Text("Created \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.42))

            HStack(spacing: 8) {
                subtleActionButton(item.favorite ? "Unfavorite" : "Favorite") {
                    viewModel.toggleSelectedChamberFavorite()
                }
                if item.kind != .note {
                    subtleActionButton("Edit") { viewModel.openEditChamberDraft() }
                }
                subtleActionButton("Delete", tint: .red) {
                    viewModel.deleteSelectedChamberItem()
                }
            }
            .disabled(!viewModel.hasActiveTrust)

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(chamberPanelFill)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(chamberPanelStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func sidebarLabel(_ title: String, active: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(active ? .semibold : .regular))
            Spacer()
            if active {
                Circle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 6, height: 6)
            }
        }
        .foregroundStyle(active ? Color.white : Color.white.opacity(0.6))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Color.white.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func detailContent(_ item: ChamberItem) -> some View {
        switch item.kind {
        case .secret:
            let secretName = item.secretName ?? item.title
            let revealed = viewModel.revealedSecretValues[secretName]
            VStack(alignment: .leading, spacing: 10) {
                Text(revealed ?? "Locked until revealed")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if !item.secretUsedBy.isEmpty {
                Text("Used by: \(item.secretUsedBy.joined(separator: ", "))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            HStack(spacing: 8) {
                subtleActionButton(revealed == nil ? "Reveal" : "Hide") {
                    viewModel.revealSelectedSecret()
                }
                subtleActionButton("Copy") {
                    viewModel.copySelectedChamberItem()
                }
            }
            .disabled(!viewModel.hasActiveTrust || !item.secretAvailable)
        case .note:
            noteDetailContent(item)
        case .document:
            Text(item.fileName ?? item.title)
                .font(.system(.body, design: .monospaced))
            if let fileSize = item.fileSize {
                Text(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            if isPDFDocument(item) {
                PDFDocumentPreview(data: item.fileData ?? Data())
                    .frame(height: 260)
                    .background(Color.black.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if let text = documentPreviewText(item), !text.isEmpty {
                ScrollView {
                    Text(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                .padding(10)
                .background(Color.black.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview not available")
                        .font(.caption.weight(.semibold))
                    Text("Export this document temporarily while trusted to inspect it outside the chamber.")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            subtleActionButton("Export") { viewModel.copySelectedChamberItem() }
                .disabled(!viewModel.hasActiveTrust)
        }
    }

    private func chamberCard(_ item: ChamberItem) -> some View {
        ZStack(alignment: .topLeading) {
            Button {
                if viewModel.selectedChamberItemId != item.id {
                    viewModel.selectChamberItem(item)
                }
            } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        chamberBadge(
                            item.kind == .secret ? "SECRET" : item.kind == .note ? "NOTE" : "DOCUMENT",
                            tint: chamberItemTint(item),
                            fill: chamberItemTint(item).opacity(0.14)
                        )
                        Spacer()
                        if item.favorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.orange)
                        }
                    }

                    cardBody(item)
                }
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: 192, maxHeight: 192, alignment: .topLeading)
                .background(cardSurface(selected: viewModel.selectedChamberItemId == item.id))
            }
            .buttonStyle(.plain)

            if item.kind == .secret {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        compactGhostButton(
                            viewModel.revealedSecretValues[item.secretName ?? ""] == nil ? "Reveal" : "Hide",
                            systemImage: "eye"
                        ) {
                            viewModel.toggleReveal(for: item)
                        }
                        compactGhostButton("Copy", systemImage: "doc.on.doc") {
                            viewModel.copyChamberItem(item)
                        }
                    }
                    .padding(.leading, 18)
                    .padding(.bottom, 16)
                }
                .allowsHitTesting(true)
            }
        }
    }

    private func cardSubtitle(_ item: ChamberItem) -> String {
        switch item.kind {
        case .secret:
            return item.secretAvailable ? "Available while trusted" : "Missing secret value"
        case .note:
            let content = item.textContent ?? ""
            return content.isEmpty ? "Empty note" : String(content.prefix(52))
        case .document:
            let file = item.fileName ?? item.title
            if let size = item.fileSize {
                return "\(file) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
            }
            return file
        }
    }

    @ViewBuilder
    private func cardBody(_ item: ChamberItem) -> some View {
        switch item.kind {
        case .secret:
            VStack(alignment: .leading, spacing: 14) {
                Text(item.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(2)
                Text(viewModel.revealedSecretValues[item.secretName ?? ""] == nil ? "••••••••••••" : (viewModel.revealedSecretValues[item.secretName ?? ""] ?? ""))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(cardSubtitle(item))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(1)
            }
        case .note:
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(2)
                Text(item.textContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (item.textContent ?? "") : "Empty note")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .lineLimit(1)
                }
            }
        case .document:
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(2)
                Image(systemName: "doc.text")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text(item.fileName ?? item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Color.white.opacity(0.82))
                Text(documentMetaLine(item))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(1)
                Text("Temporary export while trusted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
            }
        }
    }

    private func chamberBadge(_ title: String, tint: Color, fill: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(fill))
            .foregroundStyle(tint)
    }

    private func categoryTint(_ kind: ChamberStoredKind) -> Color {
        switch kind {
        case .secret:
            return Color.orange
        case .note:
            return Color.cyan
        case .document:
            return Color.green
        }
    }

    private func chamberItemTint(_ item: ChamberItem) -> Color {
        switch item.kind {
        case .secret:
            return .orange
        case .note:
            return .cyan
        case .document:
            return .green
        }
    }

    private var contentIntroText: String {
        switch viewModel.chamberCategory {
        case .all:
            return "A single view across secrets, notes, and documents currently sealed inside the chamber."
        case .secrets:
            return "Reveal or copy sensitive values only while trust remains active."
        case .notes:
            return "Private notes that appear only inside the active chamber and disappear when trust ends."
        case .documents:
            return "Imported files that can be previewed here or exported temporarily while trusted."
        case .favorites:
            return "Your favored items, collected for the quickest reveal and retrieval path."
        case .shell:
            return "A chamber-owned shell for sensitive commands with trust-bound lifetime."
        }
    }

    private var emptyStateIconName: String {
        switch viewModel.chamberCategory {
        case .all:
            return "sparkles.square.filled.on.square"
        case .secrets:
            return "key.horizontal"
        case .notes:
            return "note.text"
        case .documents:
            return "doc.text"
        case .favorites:
            return "star"
        case .shell:
            return "terminal"
        }
    }

    private var emptyStateTitle: String {
        switch viewModel.chamberCategory {
        case .all:
            return "Your chamber is empty."
        case .secrets:
            return "No chamber secrets yet."
        case .notes:
            return "No chamber notes yet."
        case .documents:
            return "No chamber documents yet."
        case .favorites:
            return "No favorites yet."
        case .shell:
            return "Trusted shell is not active."
        }
    }

    private var emptyStateBody: String {
        switch viewModel.chamberCategory {
        case .all:
            return "This is your private workspace. Items here are only accessible while your iPhone trust is active."
        case .secrets:
            return "Create a secret entry or reveal existing trust-gated values from the local SymbiAuth secret path."
        case .notes:
            return "Add a private note that stays inside the chamber."
        case .documents:
            return "Import a document and keep its export path temporary and trust-bound."
        case .favorites:
            return "Star important chamber items and they will appear here automatically."
        case .shell:
            return "Open the chamber-owned trusted shell to stage sensitive CLI work."
        }
    }

    private var sidebarCategories: [ChamberCategory] {
        [.all, .secrets, .notes, .documents, .shell, .favorites]
    }

    private func sidebarTitle(for category: ChamberCategory) -> String {
        switch category {
        case .all:
            return "All"
        case .secrets:
            return "Secrets (\(viewModel.secretRows.count))"
        case .notes:
            return "Notes (\(storedNotesCount))"
        case .documents:
            return "Documents (\(storedDocumentsCount))"
        case .shell:
            return "Trusted Shell"
        case .favorites:
            return "★ Favorites (\(favoritesCount))"
        }
    }

    @ViewBuilder
    private var addButton: some View {
        switch viewModel.chamberCategory {
        case .secrets:
            actionButton(title: "Add Secret") { viewModel.openNewChamberDraft(kind: .secret) }
        case .notes:
            actionButton(title: "Add Note") { viewModel.openNewChamberDraft(kind: .note) }
        case .documents:
            actionButton(title: "Add Document") { viewModel.openNewChamberDraft(kind: .document) }
        default:
            Menu {
                Button("New Secret") { viewModel.openNewChamberDraft(kind: .secret) }
                Button("New Note") { viewModel.openNewChamberDraft(kind: .note) }
                Button("Import Document") { viewModel.openNewChamberDraft(kind: .document) }
            } label: {
                Label("Add Item", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(viewModel.hasActiveTrust ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .disabled(!viewModel.hasActiveTrust)
        }
    }

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(viewModel.hasActiveTrust ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .disabled(!viewModel.hasActiveTrust)
    }

    private var favoritesCount: Int {
        viewModel.chamberItems.filter { $0.favorite }.count
    }

    private var storedNotesCount: Int {
        viewModel.chamberStoredItems.filter { $0.kind == .note }.count
    }

    private var storedDocumentsCount: Int {
        viewModel.chamberStoredItems.filter { $0.kind == .document }.count
    }

    private var chamberPanelFill: Color { Color.white.opacity(0.038) }
    private var chamberPanelStroke: Color { Color.white.opacity(0.08) }

    private func cardSurface(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(Color(red: 0.105, green: 0.105, blue: 0.115))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(selected ? Color.white.opacity(0.34) : Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(selected ? 0.22 : 0.12), radius: selected ? 16 : 10, x: 0, y: 8)
    }

    private func subtleActionButton(_ title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint.opacity(tint == .white ? 0.88 : 0.95))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill((tint == .white ? Color.white : tint).opacity(tint == .white ? 0.08 : 0.14))
                )
        }
        .buttonStyle(.plain)
    }

    private func compactGhostButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.74))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.16))
                )
        }
        .buttonStyle(.plain)
    }

    private func documentMetaLine(_ item: ChamberItem) -> String {
        if let size = item.fileSize {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return item.mimeType ?? "Document"
    }

    private func documentPreviewText(_ item: ChamberItem) -> String? {
        if let text = item.textContent, !text.isEmpty {
            return text
        }
        guard item.kind == .document, let data = item.fileData else { return nil }
        let name = (item.fileName ?? item.title).lowercased()
        let isTextLike = ["txt", "json", "md", "yaml", "yml", "pem", "env", "log", "csv", "xml", "toml", "ini", "conf"]
            .contains { name.hasSuffix(".\($0)") }
        guard isTextLike || (item.mimeType?.contains("text") == true) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func isPDFDocument(_ item: ChamberItem) -> Bool {
        let name = (item.fileName ?? item.title).lowercased()
        return item.mimeType == "application/pdf" || name.hasSuffix(".pdf")
    }

    @ViewBuilder
    private func noteDetailContent(_ item: ChamberItem) -> some View {
        let isEditingInline = inlineEditingNoteID == item.id
        if isEditingInline {
            TextEditor(text: $inlineNoteDraft)
                .frame(minHeight: 180)
                .padding(10)
                .background(Color.black.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                subtleActionButton("Save Note") {
                    viewModel.saveInlineNoteBody(inlineNoteDraft)
                    inlineEditingNoteID = nil
                }
                .disabled(!viewModel.hasActiveTrust)
                subtleActionButton("Cancel") {
                    inlineEditingNoteID = nil
                    syncInlineNoteEditor()
                }
                subtleActionButton("Copy") { viewModel.copySelectedChamberItem() }
                    .disabled(!viewModel.hasActiveTrust)
            }
        } else {
            Text(item.textContent ?? "")
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                subtleActionButton("Copy") { viewModel.copySelectedChamberItem() }
                    .disabled(!viewModel.hasActiveTrust)
                subtleActionButton("Edit Note") {
                    inlineEditingNoteID = item.id
                    inlineNoteDraft = item.textContent ?? ""
                }
                .disabled(!viewModel.hasActiveTrust)
            }
        }
    }

    private func syncInlineNoteEditor() {
        guard let item = viewModel.selectedChamberItem, item.kind == .note else {
            inlineEditingNoteID = nil
            inlineNoteDraft = ""
            return
        }
        if inlineEditingNoteID != item.id {
            inlineEditingNoteID = nil
            inlineNoteDraft = item.textContent ?? ""
        }
    }
}
