import SwiftUI

struct IndustrialChamberDetailPanelView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @State private var inlineNoteDraft: String = ""
    @State private var inlineNoteFormat: String = "plain_text"

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.showingChamberEditor {
                IndustrialChamberEditorPanel(viewModel: viewModel)
            } else if let item = viewModel.selectedChamberItem {
                detailBody(item)
            }
        }
        .frame(width: 430, height: 620)
        .background(ChamberTerminalTheme.panelFill)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if let item = viewModel.selectedChamberItem, item.kind == .note {
                inlineNoteDraft = item.textContent ?? ""
                inlineNoteFormat = item.textFormat ?? "plain_text"
            }
        }
        .onChange(of: viewModel.selectedChamberItemId) { _ in
            if let item = viewModel.selectedChamberItem, item.kind == .note {
                inlineNoteDraft = item.textContent ?? ""
                inlineNoteFormat = item.textFormat ?? "plain_text"
            }
        }
        .onChange(of: viewModel.showingChamberEditor) { isShowing in
            if isShowing {
                viewModel.chamberFilterVisible = false
            }
        }
    }

    @ViewBuilder
    private func detailBody(_ item: ChamberItem) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⌈ \(item.title.uppercased()) ⌋")
                        .font(.chamberMono(size: 13, weight: .semibold))
                        .foregroundStyle(ChamberTerminalTheme.textPrimary)
                        .lineLimit(2)
                    Text(detailSubtitle(item))
                        .font(.chamberMono(size: 9))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    viewModel.selectedChamberItemId = nil
                } label: {
                    Text("[X]")
                        .font(.chamberMono(size: 10, weight: .medium))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            Divider().overlay(ChamberTerminalTheme.panelStroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch item.kind {
                    case .secret:
                        secretDetail(item)
                    case .note:
                        noteDetail(item)
                    case .document:
                        documentDetail(item)
                    }

                    metadataSection(item)

                    if !item.tags.isEmpty {
                        detailSectionLabel("tags")
                        Text(item.tags.joined(separator: " · "))
                            .font(.chamberMono(size: 10))
                            .foregroundStyle(ChamberTerminalTheme.textSecondary)
                    }
                }
                .padding(14)
            }
        }
    }

    private func secretDetail(_ item: ChamberItem) -> some View {
        let secretName = item.secretName ?? item.title
        let revealed = viewModel.revealedSecretValues[secretName]
        return VStack(alignment: .leading, spacing: 12) {
            detailSectionLabel("identity")
            metadataLine("Label", item.title)
            metadataLine("Env", secretName)
            metadataLine("Type", formattedSecretType(item.secretType))
            metadataLine("Shell", item.secretAvailableInShell ? "enabled" : "chamber only")

            detailSectionLabel("value")
            Text(revealed ?? "••••••••••••••••••")
                .font(.chamberMono(size: 13, weight: .medium))
                .foregroundStyle(ChamberTerminalTheme.textPrimary)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.2))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))

            HStack(spacing: 8) {
                detailButton(revealed == nil ? "[ REVEAL ]" : "[ HIDE ]") {
                    viewModel.revealSelectedSecret()
                }
                detailButton("[ COPY ]") {
                    viewModel.copySelectedChamberItem()
                }
            }
            .disabled(!viewModel.hasActiveTrust || !item.secretAvailable)

            detailFooterActions(item)
        }
    }

    private func noteDetail(_ item: ChamberItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                detailButton(inlineNoteFormat == "plain_text" ? "[ TEXT* ]" : "[ TEXT ]") {
                    inlineNoteFormat = "plain_text"
                }
                detailButton(inlineNoteFormat == "markdown" ? "[ MD* ]" : "[ MD ]") {
                    inlineNoteFormat = "markdown"
                }
                Spacer()
            }

            if inlineNoteFormat == "markdown" {
                HStack(spacing: 8) {
                    detailButton("[ B ]") { inlineNoteDraft = appendMarkdown("**bold**") }
                    detailButton("[ I ]") { inlineNoteDraft = appendMarkdown("*italic*") }
                    detailButton("[ # ]") { inlineNoteDraft = appendMarkdown("# heading") }
                    detailButton("[ • ]") { inlineNoteDraft = appendMarkdown("- list item") }
                    detailButton("[ CODE ]") { inlineNoteDraft = appendMarkdown("```\ncode\n```") }
                    Spacer()
                }
            }

            detailSectionLabel("body")
            TextEditor(text: Binding(
                get: { inlineNoteDraft },
                set: { inlineNoteDraft = $0 }
            ))
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(ChamberTerminalTheme.textPrimary)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 360)
            .padding(8)
            .background(Color.black.opacity(0.2))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))

            HStack(spacing: 8) {
                detailButton("[ SAVE ]") {
                    viewModel.saveInlineNote(body: inlineNoteDraft, format: inlineNoteFormat)
                }
                detailButton("[ COPY ]") {
                    viewModel.copySelectedChamberItem()
                }
                detailButton("[ EXPORT ]") {
                    viewModel.exportSelectedNote(bodyOverride: inlineNoteDraft, formatOverride: inlineNoteFormat)
                }
            }
            .disabled(!viewModel.hasActiveTrust)

            detailFooterActions(item, includeEdit: false)
        }
    }

    @ViewBuilder
    private func documentDetail(_ item: ChamberItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let fileName = item.fileName {
                detailSectionLabel("file")
                metadataLine("Name", fileName)
                if let fileSize = item.fileSize {
                    metadataLine("Size", ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                }
                metadataLine("Imported", item.updatedAt.formatted(date: .abbreviated, time: .omitted))
            }

            detailSectionLabel("preview")
            if isPDFDocument(item), let data = item.fileData {
                PDFDocumentPreview(data: data)
                    .frame(height: 310)
                    .background(Color.black.opacity(0.2))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
            } else if let text = documentPreviewText(item), !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.chamberMono(size: 10))
                        .foregroundStyle(ChamberTerminalTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 310)
                .background(Color.black.opacity(0.2))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
            } else {
                Text("Preview not available.")
                    .font(.chamberMono(size: 10))
                    .foregroundStyle(ChamberTerminalTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                    .padding(10)
                    .background(Color.black.opacity(0.2))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
            }

            HStack(spacing: 8) {
                detailButton("[ EXPORT ]") {
                    viewModel.copySelectedChamberItem()
                }
            }
            .disabled(!viewModel.hasActiveTrust)

            detailFooterActions(item)
        }
    }

    private func detailFooterActions(_ item: ChamberItem, includeEdit: Bool = true) -> some View {
        HStack(spacing: 8) {
            detailButton(item.favorite ? "[ UNFAV ]" : "[ FAV ]") {
                viewModel.toggleSelectedChamberFavorite()
            }
            if includeEdit && item.kind != .note {
                detailButton("[ EDIT ]") {
                    viewModel.openEditChamberDraft()
                }
            }
            detailButton("[ DELETE ]", tint: .red) {
                viewModel.deleteSelectedChamberItem()
            }
        }
    }

    private func detailButton(_ title: String, tint: Color = ChamberTerminalTheme.textSecondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.chamberMono(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(ChamberTerminalTheme.rowFill)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func detailSectionLabel(_ title: String) -> some View {
        Text("• \(title.uppercased())")
            .font(.chamberMono(size: 8, weight: .medium))
            .foregroundStyle(ChamberTerminalTheme.textSecondary)
    }

    private func metadataSection(_ item: ChamberItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            detailSectionLabel("metadata")
            metadataLine("Created", formattedMetadataDate(item.createdAt))
            metadataLine("Updated", formattedMetadataDate(item.updatedAt))
            metadataLine("Opened", formattedMetadataDate(item.lastOpenedAt))
        }
    }

    private func metadataLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased())
                .font(.chamberMono(size: 8, weight: .medium))
                .foregroundStyle(ChamberTerminalTheme.textSecondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.chamberMono(size: 10))
                .foregroundStyle(ChamberTerminalTheme.textPrimary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func formattedSecretType(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "password":
            return "password"
        case "token":
            return "token"
        case "api_key":
            return "api key"
        case "multiline":
            return "multiline"
        default:
            return "custom"
        }
    }

    private func formattedMetadataDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        if date == Date.distantPast {
            return "—"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func detailSubtitle(_ item: ChamberItem) -> String {
        switch item.kind {
        case .secret:
            if !item.secretAvailable {
                return "secret unavailable"
            }
            if item.createdAt != Date.distantPast {
                return "created \(item.createdAt.formatted(date: .abbreviated, time: .omitted))"
            }
            return "Protected secret"
        case .note:
            return "Editable private note"
        case .document:
            return item.fileName ?? "Document preview"
        }
    }

    private func appendMarkdown(_ token: String) -> String {
        if inlineNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token
        }
        if inlineNoteDraft.hasSuffix("\n") {
            return inlineNoteDraft + token
        }
        return inlineNoteDraft + "\n" + token
    }

    private func documentPreviewText(_ item: ChamberItem) -> String? {
        if let text = item.textContent, !text.isEmpty {
            return text
        }
        guard let data = item.fileData else { return nil }
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
}

struct IndustrialChamberEditorPanel: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⌈ \(editorTitle.uppercased()) ⌋")
                        .font(.chamberMono(size: 13, weight: .semibold))
                        .foregroundStyle(ChamberTerminalTheme.textPrimary)
                    Text("New chamber item.")
                        .font(.chamberMono(size: 9))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                }
                Spacer()
                Button {
                    viewModel.showingChamberEditor = false
                } label: {
                    Text("[X]")
                        .font(.chamberMono(size: 10, weight: .medium))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            Divider().overlay(ChamberTerminalTheme.panelStroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if lockedDraftKind == nil {
                        Picker("Type", selection: $viewModel.chamberDraft.kind) {
                            ForEach(ChamberStoredKind.allCases, id: \.rawValue) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                    } else if let lockedDraftKind {
                        terminalEditorLabel("TYPE")
                        Text(lockedDraftKind.title.uppercased())
                            .font(.chamberMono(size: 10, weight: .semibold))
                            .foregroundStyle(ChamberTerminalTheme.textPrimary)
                    }

                    terminalEditorLabel("TITLE")
                    terminalTextField("title", text: $viewModel.chamberDraft.title)

                    switch viewModel.chamberDraft.kind {
                    case .secret:
                        terminalEditorLabel("ENV KEY")
                        terminalTextField("secret_name", text: $viewModel.chamberDraft.secretName)
                        terminalEditorLabel("SECRET TYPE")
                        Picker("", selection: $viewModel.chamberDraft.secretType) {
                            Text("Custom").tag("custom")
                            Text("Password").tag("password")
                            Text("Token").tag("token")
                            Text("API Key").tag("api_key")
                            Text("Multiline").tag("multiline")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.chamberMono(size: 10, weight: .medium))
                        .foregroundStyle(ChamberTerminalTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(ChamberTerminalTheme.rowFill)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
                        Toggle(isOn: $viewModel.chamberDraft.secretAvailableInShell) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AVAILABLE IN TRUSTED SHELL")
                                    .font(.chamberMono(size: 9, weight: .semibold))
                                    .foregroundStyle(ChamberTerminalTheme.textPrimary)
                                Text("Allow this secret to appear in shell injection lists.")
                                    .font(.chamberMono(size: 8))
                                    .foregroundStyle(ChamberTerminalTheme.textSecondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .foregroundStyle(ChamberTerminalTheme.textPrimary)
                        terminalEditorLabel("SECRET VALUE")
                        SecureField("", text: $viewModel.chamberDraft.secretValue)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(ChamberTerminalTheme.textPrimary)
                            .padding(10)
                            .background(ChamberTerminalTheme.rowFill)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
                    case .note:
                        terminalEditorLabel("BODY")
                        TextEditor(text: $viewModel.chamberDraft.body)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(ChamberTerminalTheme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(height: 200)
                            .padding(8)
                            .background(ChamberTerminalTheme.rowFill)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
                    case .document:
                        terminalEditorLabel("DOCUMENT")
                        Button(viewModel.chamberDraft.fileData == nil ? "[ CHOOSE FILE ]" : "[ REPLACE FILE ]") {
                            viewModel.importDocumentForDraft()
                        }
                        .buttonStyle(.plain)
                        .font(.chamberMono(size: 10, weight: .medium))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(ChamberTerminalTheme.rowFill)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
                        if !viewModel.chamberDraft.fileName.isEmpty {
                            Text(viewModel.chamberDraft.fileName)
                                .font(.chamberMono(size: 10))
                                .foregroundStyle(ChamberTerminalTheme.textSecondary)
                        }
                    }

                    terminalEditorLabel("NOTE")
                    terminalTextField("optional", text: $viewModel.chamberDraft.note)

                    terminalEditorLabel("TAGS")
                    terminalTextField("comma,separated", text: $viewModel.chamberDraft.tagsText)
                    if !viewModel.suggestedDraftTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(viewModel.suggestedDraftTags, id: \.self) { tag in
                                    editorButton("[\(tag)]") {
                                        viewModel.applySuggestedDraftTag(tag)
                                    }
                                }
                            }
                        }
                    }

                    if let error = viewModel.chamberDraftError, !error.isEmpty {
                        Text(error)
                            .font(.chamberMono(size: 9))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }

                    HStack(spacing: 8) {
                        editorButton("[ CANCEL ]") {
                            viewModel.showingChamberEditor = false
                        }
                        editorButton("[ SAVE ]") {
                            viewModel.saveChamberDraft()
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private var lockedDraftKind: ChamberStoredKind? {
        guard viewModel.chamberDraft.editingStoredItemId == nil else { return nil }
        switch viewModel.chamberCategory {
        case .secrets:
            return .secret
        case .notes:
            return .note
        case .documents:
            return .document
        default:
            return nil
        }
    }

    private var editorTitle: String {
        if viewModel.chamberDraft.editingStoredItemId != nil {
            return "Edit \(viewModel.chamberDraft.kind.title)"
        }
        return "New \(viewModel.chamberDraft.kind.title)"
    }

    private func terminalEditorLabel(_ title: String) -> some View {
        Text("• \(title)")
            .font(.chamberMono(size: 8, weight: .medium))
            .foregroundStyle(ChamberTerminalTheme.textSecondary)
    }

    private func terminalTextField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(ChamberTerminalTheme.textPrimary)
            .padding(10)
            .background(ChamberTerminalTheme.rowFill)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
    }

    private func editorButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.chamberMono(size: 10, weight: .medium))
                .foregroundStyle(ChamberTerminalTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(ChamberTerminalTheme.rowFill)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct IndustrialChamberFilterPanelView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⌈ FILTER ⌋")
                        .font(.chamberMono(size: 13, weight: .semibold))
                        .foregroundStyle(ChamberTerminalTheme.textPrimary)
                    Text(filterSubtitle)
                        .font(.chamberMono(size: 9))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    viewModel.closeChamberFilter()
                } label: {
                    Text("[X]")
                        .font(.chamberMono(size: 10, weight: .medium))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            Divider().overlay(ChamberTerminalTheme.panelStroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let active = viewModel.chamberSelectedTagFilter, !active.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ACTIVE FILTER")
                                .font(.chamberMono(size: 9, weight: .medium))
                                .foregroundStyle(ChamberTerminalTheme.textSecondary)
                            HStack(spacing: 8) {
                                Text(active.uppercased())
                                    .font(.chamberMono(size: 10, weight: .semibold))
                                    .foregroundStyle(ChamberTerminalTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    viewModel.clearTagFilter()
                                } label: {
                                    Text("[RESET FILTER]")
                                        .font(.chamberMono(size: 10, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.93, green: 0.54, blue: 0.26))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(ChamberTerminalTheme.rowHover)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.93, green: 0.54, blue: 0.26).opacity(0.5), lineWidth: 1))
                        }
                        .padding(.bottom, 6)
                    }

                    if viewModel.availableFilterTags.isEmpty {
                        Text("No tags available in this view.")
                            .font(.chamberMono(size: 10))
                            .foregroundStyle(ChamberTerminalTheme.textSecondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(viewModel.availableFilterTags, id: \.self) { tag in
                            filterChip(tag, active: viewModel.chamberSelectedTagFilter?.caseInsensitiveCompare(tag) == .orderedSame) {
                                viewModel.selectTagFilter(tag)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 430, height: 620)
        .background(ChamberTerminalTheme.panelFill)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var filterSubtitle: String {
        if viewModel.chamberSearchVisible {
            return "Filter search results by tag."
        }
        return "Filter the current category by tag."
    }

    private func filterChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.chamberMono(size: 10, weight: .medium))
                    .foregroundStyle(active ? ChamberTerminalTheme.textPrimary : ChamberTerminalTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(active ? ChamberTerminalTheme.rowHover : ChamberTerminalTheme.rowFill)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
