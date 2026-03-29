import SwiftUI

struct IndustrialTrustedShellPanelView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.trustedShellLive {
                liveShellView
            } else {
                shellSetupView
            }
        }
    }

    private var shellSetupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                terminalSectionLabel("SHELL")
                terminalValueBlock(viewModel.trustedShellExecutable)

                terminalSectionLabel("WORKDIR")
                terminalTextField("working_directory", text: $viewModel.trustedShellWorkingDirectory)

                terminalSectionLabel("GUARD")
                HStack(spacing: 8) {
                    shellModeButton("[ STRICT ]", active: viewModel.trustedShellGuardMode == "strict") {
                        viewModel.trustedShellGuardMode = "strict"
                    }
                    shellModeButton("[ TTL ]", active: viewModel.trustedShellGuardMode == "background_ttl") {
                        viewModel.trustedShellGuardMode = "background_ttl"
                    }
                    Spacer()
                }

                if viewModel.trustedShellGuardMode == "background_ttl" {
                    terminalSectionLabel("BACKGROUND TTL")
                    terminalTextField("seconds", text: $viewModel.trustedShellBackgroundTTL)
                }

                terminalSectionLabel("SHELL-ELIGIBLE SECRETS")
                if viewModel.trustedShellEligibleSecrets.isEmpty {
                    terminalHintBlock("No secrets are marked for Trusted Shell yet. Edit a secret and enable AVAILABLE IN TRUSTED SHELL.")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.trustedShellEligibleSecrets.prefix(8), id: \.id) { secret in
                            HStack(spacing: 8) {
                                Text("•")
                                    .font(.chamberMono(size: 8, weight: .medium))
                                    .foregroundStyle(ChamberTerminalTheme.textSecondary)
                                Text(secret.name)
                                    .font(.chamberMono(size: 10))
                                    .foregroundStyle(ChamberTerminalTheme.textPrimary)
                                Spacer()
                                Text("READY")
                                    .font(.chamberMono(size: 8, weight: .semibold))
                                    .foregroundStyle(ChamberTerminalTheme.accentAcid.opacity(0.82))
                            }
                        }
                    }
                    .padding(10)
                    .background(ChamberTerminalTheme.rowFill)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
                }

                terminalHintBlock("Secrets are injected during the session with chamber inject. You do not need to preselect them here.")

                HStack(spacing: 8) {
                    shellActionButton("[ OPEN TRUSTED SHELL ]", tint: ChamberTerminalTheme.accentAcid.opacity(0.92)) {
                        viewModel.openTrustedShellSession()
                    }
                    Spacer()
                }

                if let status = viewModel.trustedShellStatus, !status.isEmpty {
                    terminalHintBlock(status)
                }
            }
            .padding(14)
        }
    }

    private var liveShellView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Text("MODE \(viewModel.trustedShellGuardMode == "strict" ? "STRICT" : "TTL")")
                        .font(.chamberMono(size: 9, weight: .semibold))
                        .foregroundStyle(viewModel.trustedShellGuardMode == "strict" ? ChamberTerminalTheme.accentCopper.opacity(0.9) : ChamberTerminalTheme.accentAcid.opacity(0.88))
                    Text("DIR \(viewModel.trustedShellCurrentDirectory)")
                        .font(.chamberMono(size: 9))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    shellActionButton("[ INJECT ]", tint: ChamberTerminalTheme.accentAcid.opacity(0.9)) {
                        viewModel.openTrustedShellInject()
                    }
                    shellActionButton("[ CLOSE ]", tint: ChamberTerminalTheme.accentCopper.opacity(0.92)) {
                        viewModel.closeTrustedShellSession()
                    }
                }
                if !viewModel.trustedShellInjectedSecrets.isEmpty {
                    Text("ENV \(viewModel.trustedShellInjectedSecrets.joined(separator: ", "))")
                        .font(.chamberMono(size: 9))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                        .lineLimit(1)
                }
                if let status = viewModel.trustedShellStatus, !status.isEmpty {
                    Text(status)
                        .font(.chamberMono(size: 9))
                        .foregroundStyle(ChamberTerminalTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().overlay(ChamberTerminalTheme.panelStroke)

            ZStack(alignment: .topTrailing) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(viewModel.trustedShellTranscript.isEmpty ? "trusted shell waiting for output…" : viewModel.trustedShellTranscript)
                            .font(.chamberMono(size: 12))
                            .foregroundStyle(ChamberTerminalTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .id("shellTranscriptEnd")
                    }
                    .onChange(of: viewModel.trustedShellTranscript) { _ in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo("shellTranscriptEnd", anchor: .bottom)
                        }
                    }
                }

                if viewModel.trustedShellInjectVisible {
                    trustedShellInjectOverlay
                        .padding(14)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.18))

            Divider().overlay(ChamberTerminalTheme.panelStroke)

            HStack(spacing: 8) {
                Text("cmbo>")
                    .font(.chamberMono(size: 11, weight: .semibold))
                    .foregroundStyle(ChamberTerminalTheme.accentAcid.opacity(0.88))
                TrustedShellCommandField(
                    text: $viewModel.trustedShellInput,
                    onSubmit: { viewModel.sendTrustedShellInput() },
                    onHistoryUp: { viewModel.navigateTrustedShellHistory(direction: -1) },
                    onHistoryDown: { viewModel.navigateTrustedShellHistory(direction: 1) }
                )
                .frame(maxWidth: .infinity)
                shellActionButton("[ SEND ]", tint: ChamberTerminalTheme.accentRail.opacity(0.9)) {
                    viewModel.sendTrustedShellInput()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var trustedShellInjectOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("[ CHAMBER INJECT ]")
                    .font(.chamberMono(size: 10, weight: .semibold))
                    .foregroundStyle(ChamberTerminalTheme.accentAcid.opacity(0.9))
                Spacer()
                shellActionButton("[X]", tint: ChamberTerminalTheme.textSecondary) {
                    viewModel.cancelTrustedShellInject()
                }
            }

            terminalTextField("filter secrets", text: $viewModel.trustedShellInjectSearch)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if viewModel.trustedShellFilteredSecrets.isEmpty {
                        terminalHintBlock(
                            viewModel.trustedShellEligibleSecrets.isEmpty
                            ? "No secrets are currently marked AVAILABLE IN TRUSTED SHELL."
                            : "No shell-eligible secrets match this filter."
                        )
                    } else {
                        ForEach(viewModel.trustedShellFilteredSecrets, id: \.id) { secret in
                            injectRow(secret)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack(spacing: 8) {
                shellActionButton("[ INJECT SELECTED ]", tint: ChamberTerminalTheme.accentCopper.opacity(0.92)) {
                    viewModel.injectSelectedTrustedShellSecrets()
                }
                shellActionButton("[ CANCEL ]", tint: ChamberTerminalTheme.textSecondary) {
                    viewModel.cancelTrustedShellInject()
                }
                Spacer()
            }

            Text("Type chamber inject inside the shell to reopen this selector.")
                .font(.chamberMono(size: 9))
                .foregroundStyle(ChamberTerminalTheme.textSecondary)
        }
        .padding(10)
        .frame(width: 332)
        .background(ChamberTerminalTheme.panelFill)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ChamberTerminalTheme.accentRail.opacity(0.18), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 8)
    }

    private func injectRow(_ secret: PreferencesViewModel.SecretRow) -> some View {
        let selected = viewModel.trustedShellInjectSelection.contains(secret.name)
        let config = viewModel.chamberSecretConfiguration(for: secret.name)
        let label = viewModel.chamberSecretDisplayTitle(for: secret.name)
        return Button {
            viewModel.toggleTrustedShellInjectSelection(secretName: secret.name)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(selected ? "[x]" : "[ ]")
                    .font(.chamberMono(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? ChamberTerminalTheme.accentAcid.opacity(0.92) : ChamberTerminalTheme.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.chamberMono(size: 10, weight: .semibold))
                        .foregroundStyle(ChamberTerminalTheme.textPrimary)
                    HStack(spacing: 8) {
                        Text(secret.name)
                            .font(.chamberMono(size: 9))
                            .foregroundStyle(ChamberTerminalTheme.textSecondary)
                        Text(config.type.uppercased())
                            .font(.chamberMono(size: 8, weight: .medium))
                            .foregroundStyle(ChamberTerminalTheme.accentCopper.opacity(0.82))
                    }
                }
                Spacer()
            }
            .padding(9)
            .background(selected ? ChamberTerminalTheme.rowHover : ChamberTerminalTheme.rowFill)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? ChamberTerminalTheme.accentAcid.opacity(0.2) : ChamberTerminalTheme.panelStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func terminalSectionLabel(_ title: String) -> some View {
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

    private func terminalValueBlock(_ value: String) -> some View {
        Text(value)
            .font(.chamberMono(size: 10))
            .foregroundStyle(ChamberTerminalTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(ChamberTerminalTheme.rowFill)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1))
    }

    private func terminalHintBlock(_ text: String) -> some View {
        Text(text)
            .font(.chamberMono(size: 9))
            .foregroundStyle(ChamberTerminalTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(ChamberTerminalTheme.noiseFill)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChamberTerminalTheme.panelStroke.opacity(0.9), lineWidth: 1))
    }

    private func shellModeButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.chamberMono(size: 10, weight: .medium))
                .foregroundStyle(active ? ChamberTerminalTheme.textPrimary : ChamberTerminalTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(active ? ChamberTerminalTheme.rowHover : ChamberTerminalTheme.rowFill)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? ChamberTerminalTheme.accentRail.opacity(0.18) : ChamberTerminalTheme.panelStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func shellActionButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.chamberMono(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(ChamberTerminalTheme.rowFill)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.hasActiveTrust)
    }
}

private struct TrustedShellCommandField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onHistoryUp: () -> Void
    let onHistoryDown: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onHistoryUp: onHistoryUp, onHistoryDown: onHistoryDown)
    }

    func makeNSView(context: Context) -> HistoryAwareTextField {
        let field = HistoryAwareTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = NSColor(ChamberTerminalTheme.textPrimary)
        field.placeholderString = "enter command"
        field.delegate = context.coordinator
        field.historyDelegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: HistoryAwareTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, HistoryAwareTextFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void
        let onHistoryUp: () -> Void
        let onHistoryDown: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onHistoryUp: @escaping () -> Void, onHistoryDown: @escaping () -> Void) {
            self._text = text
            self.onSubmit = onSubmit
            self.onHistoryUp = onHistoryUp
            self.onHistoryDown = onHistoryDown
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                onHistoryUp()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                onHistoryDown()
                return true
            }
            return false
        }

        func historyFieldDidPressUp() {
            onHistoryUp()
        }

        func historyFieldDidPressDown() {
            onHistoryDown()
        }
    }
}

private protocol HistoryAwareTextFieldDelegate: AnyObject {
    func historyFieldDidPressUp()
    func historyFieldDidPressDown()
}

private final class HistoryAwareTextField: NSTextField {
    weak var historyDelegate: HistoryAwareTextFieldDelegate?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126:
            historyDelegate?.historyFieldDidPressUp()
        case 125:
            historyDelegate?.historyFieldDidPressDown()
        default:
            super.keyDown(with: event)
        }
    }
}
