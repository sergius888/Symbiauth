import PDFKit
import SwiftUI

struct ChamberHomeTabView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 14) {
                        Image("SymbiAuthMark")
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Secret Chamber")
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text("A private workspace that becomes available only while your paired iPhone trust session is active.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        statusPill(
                            title: viewModel.chamberTrustStateLabel,
                            tint: viewModel.hasActiveTrust ? .green : .orange
                        )
                        statusPill(
                            title: viewModel.settingsMode == "strict" ? "Strict Default" : "Advanced Mode: \(viewModel.settingsModeLabel)",
                            tint: viewModel.settingsMode == "strict" ? .white : .orange
                        )
                        if viewModel.protectedClipboardActive {
                            statusPill(title: "Clipboard Armed", tint: .orange)
                        }
                    }
                }

                chamberHero

                HStack(alignment: .top, spacing: 16) {
                    featureColumn(
                        title: "V1 Categories",
                        description: "The first chamber release is structured around only the categories we can support cleanly.",
                        items: [
                            "Secrets: passwords, API keys, tokens, passphrases",
                            "Notes: private text, instructions, personal records",
                            "Documents: local files previewed or exported temporarily"
                        ]
                    )

                    featureColumn(
                        title: "Trust Behavior",
                        description: "The chamber follows phone trust directly. It is not a long-lived background vault.",
                        items: [
                            "First trust activation opens the chamber automatically",
                            "Closing the chamber does not end trust",
                            "Trust ending closes and relocks the chamber immediately"
                        ]
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    summaryCard(
                        title: "Current Inventory",
                        rows: [
                            ("Secrets Available", "\(viewModel.availableSecrets)"),
                            ("Secrets Missing", "\(viewModel.missingSecrets)"),
                            ("Protected Items", "\(viewModel.chamberStoredItems.count + viewModel.secretRows.count)"),
                            ("Notes + Documents", "\(viewModel.chamberStoredItems.count)"),
                            ("Recent History", "\(viewModel.sessionHistory.count)")
                        ]
                    )

                    featureColumn(
                        title: "What Is Parked",
                        description: "Earlier managed-session work is preserved, but it no longer defines the main product surface.",
                        items: [
                            "Managed Sessions and tunnel templates are parked",
                            "DevOps-oriented flows stay out of the main chamber UX",
                            "The old work can return later as an advanced branch"
                        ]
                    )
                }
            }
            .padding(20)
        }
        .onAppear {
            viewModel.refresh()
            viewModel.refreshTrustConfig()
        }
    }

    private var chamberHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Workspace")
                .font(.headline)
            Text("The chamber is now a real trust-bound workspace with secrets, notes, and documents. When trust ends, the window closes and protected state is cleared.")
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 22)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.06, green: 0.06, blue: 0.06),
                            Color(red: 0.10, green: 0.10, blue: 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 250)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            HStack(spacing: 10) {
                                Image("SymbiAuthMark")
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .frame(width: 28, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text("Secret Chamber")
                                    .font(.title3.weight(.semibold))
                            }
                            Spacer()
                            Text(viewModel.hasActiveTrust ? "Trusted" : "Locked")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill((viewModel.hasActiveTrust ? Color.green : Color.orange).opacity(0.15)))
                        }

                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("All")
                                Text("Secrets")
                                Text("Notes")
                                Text("Documents")
                                Divider()
                                Text("Favorites")
                                Text("Recent")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Protected items live here")
                                    .font(.headline)
                                Text("Left-side categories, a main content area, and a stable detail pane replace the old utility-style preferences flow.")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                HStack(spacing: 10) {
                                    mockCard("Secret", "API Token", "Reveal / Copy")
                                    mockCard("Note", "Infra Notes", "Read / Edit")
                                    mockCard("Document", "backup.json", "Preview / Export")
                                }
                                HStack {
                                    Text(viewModel.hasActiveTrust ? "Trust is active. The chamber can be opened from the menu bar." : "Open the iPhone app to unlock the chamber.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("First trust activation opens the chamber automatically.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(20)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
        .padding(16)
        .background(Color.white.opacity(0.035))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func featureColumn(title: String, description: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Color.white.opacity(0.035))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func summaryCard(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1)
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Color.white.opacity(0.035))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statusPill(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.14)))
            .foregroundStyle(tint)
    }

    private func mockCard(_ type: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(type.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 150, height: 120, alignment: .topLeading)
        .background(Color.white.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct PDFDocumentPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = false
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = PDFDocument(data: data)
    }
}

struct ChamberItemEditorSheet: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editorTitle)
                .font(.title3.weight(.semibold))

            if let lockedKind = lockedDraftKind {
                HStack(spacing: 8) {
                    Text("Type")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(lockedKind.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            } else {
                Picker("Type", selection: $viewModel.chamberDraft.kind) {
                    ForEach(ChamberStoredKind.allCases, id: \.rawValue) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.chamberDraft.editingStoredItemId != nil)
            }

            TextField("Title", text: $viewModel.chamberDraft.title)
                .textFieldStyle(.roundedBorder)

            switch viewModel.chamberDraft.kind {
            case .secret:
                TextField("Secret Name", text: $viewModel.chamberDraft.secretName)
                    .textFieldStyle(.roundedBorder)
                SecureField("Secret Value", text: $viewModel.chamberDraft.secretValue)
                    .textFieldStyle(.roundedBorder)
            case .note:
                TextEditor(text: $viewModel.chamberDraft.body)
                    .frame(height: 180)
                    .padding(8)
                    .background(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            case .document:
                HStack {
                    Button(viewModel.chamberDraft.fileData == nil ? "Choose File" : "Replace File") {
                        viewModel.importDocumentForDraft()
                    }
                    if !viewModel.chamberDraft.fileName.isEmpty {
                        Text(viewModel.chamberDraft.fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = viewModel.chamberDraftError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Note (optional)", text: $viewModel.chamberDraft.note)
                .textFieldStyle(.roundedBorder)
            TextField("Tags (comma separated)", text: $viewModel.chamberDraft.tagsText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    viewModel.saveChamberDraft()
                    if !viewModel.showingChamberEditor {
                        dismiss()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
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
        switch viewModel.chamberDraft.kind {
        case .secret:
            return "Add Secret"
        case .note:
            return "Add Note"
        case .document:
            return "Add Document"
        }
    }
}
