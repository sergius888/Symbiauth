import SwiftUI

struct IndustrialChamberSpineView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    let onSelect: (ChamberCategory) -> Void
    let onSearch: () -> Void
    @State private var hoveredActionId: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image("SymbiAuthMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(spacing: 5) {
                    Text("::")
                    Text("::")
                }
            }
            .font(.chamberMono(size: 9, weight: .medium))
            .foregroundStyle(ChamberTerminalTheme.textGhost)
            .frame(height: 84)

            ForEach(spineActions, id: \.id) { item in
                spineButton(symbol: item.symbol, active: item.isActive(viewModel), tooltip: item.label) {
                    item.perform(onSelect: onSelect, onSearch: onSearch)
                }
            }

            Spacer(minLength: 0)

            spineSeparator

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let status = spineStatus(at: context.date)
                VStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(status.tint.opacity(0.72))
                            .frame(width: 6, height: 6)
                        Text(status.label)
                            .font(.chamberMono(size: 7, weight: .semibold))
                            .foregroundStyle(status.tint.opacity(0.85))
                    }
                    VStack(spacing: 1) {
                        Text("▓▒░")
                        Text("░▒▓")
                    }
                    .font(.chamberMono(size: 7))
                    .foregroundStyle(ChamberTerminalTheme.textGhost)
                    Text("v2.1")
                        .font(.chamberMono(size: 7))
                        .foregroundStyle(ChamberTerminalTheme.textGhost)
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: 62)
        .frame(maxHeight: .infinity)
        .background(ChamberTerminalTheme.panelFill)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChamberTerminalTheme.panelStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var spineActions: [SpineAction] {
        [
            .search,
            .category(.secrets, "[S]", "SECRETS"),
            .category(.notes, "[N]", "NOTES"),
            .category(.documents, "[D]", "DOCUMENTS"),
            .category(.shell, "[>_]", "TRUSTED SHELL"),
            .category(.favorites, "[★]", "FAVORITES")
        ]
    }

    private var spineSeparator: some View {
        Rectangle()
            .fill(ChamberTerminalTheme.panelStroke)
            .frame(width: 28, height: 1)
            .padding(.vertical, 8)
    }

    private func spineButton(symbol: String, active: Bool, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                if active || hoveredActionId == tooltip {
                    Rectangle()
                        .fill(active ? ChamberTerminalTheme.accentRail.opacity(0.82) : ChamberTerminalTheme.textSecondary.opacity(0.38))
                        .frame(width: 2, height: active ? 24 : 16)
                        .offset(x: -9)
                }

                Text(symbol)
                    .font(.chamberMono(size: 12, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? ChamberTerminalTheme.textPrimary : (hoveredActionId == tooltip ? ChamberTerminalTheme.textPrimary.opacity(0.82) : ChamberTerminalTheme.textSecondary))
                    .frame(width: 38, height: 38)
                    .background(active ? ChamberTerminalTheme.rowFill : (hoveredActionId == tooltip ? ChamberTerminalTheme.noiseFill : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(active ? ChamberTerminalTheme.accentRail.opacity(0.18) : (hoveredActionId == tooltip ? ChamberTerminalTheme.panelStroke.opacity(0.95) : Color.clear), lineWidth: 1)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredActionId = isHovering ? tooltip : (hoveredActionId == tooltip ? nil : hoveredActionId)
        }
        .help(tooltip)
        .padding(.vertical, 2)
    }

    private func spineStatus(at date: Date) -> (label: String, tint: Color) {
        let nowMs = UInt64(date.timeIntervalSince1970 * 1000)
        if let deadlineMs = viewModel.diagnostics.deadlineMs,
           deadlineMs > nowMs,
           viewModel.diagnostics.mode.lowercased() == "background_ttl" {
            let secs = max(1, Int((deadlineMs - nowMs) / 1000))
            return ("TTL \(secs)s", ChamberTerminalTheme.accentCopper)
        }

        if viewModel.hasActiveTrust {
            switch viewModel.diagnostics.mode.lowercased() {
            case "strict":
                return ("STRICT", ChamberTerminalTheme.accentAcid)
            case "office":
                return ("OFFICE", ChamberTerminalTheme.accentRail)
            case "background_ttl":
                return ("TTL", ChamberTerminalTheme.accentAcid)
            default:
                return ("TRUST", ChamberTerminalTheme.accentAcid)
            }
        }

        return ("SEALED", ChamberTerminalTheme.accentCopper)
    }

    private enum SpineAction {
        case search
        case category(ChamberCategory, String, String)

        var id: String {
            switch self {
            case .search:
                return "search"
            case .category(let category, _, _):
                return category.rawValue
            }
        }

        var symbol: String {
            switch self {
            case .search:
                return "[/]"
            case .category(_, let symbol, _):
                return symbol
            }
        }

        var label: String {
            switch self {
            case .search:
                return "SEARCH"
            case .category(_, _, let label):
                return label
            }
        }

        func isActive(_ viewModel: PreferencesViewModel) -> Bool {
            switch self {
            case .search:
                return viewModel.chamberSearchVisible
            case .category(let category, _, _):
                return viewModel.chamberPanelCategory == category && !viewModel.chamberSearchVisible
            }
        }

        func perform(onSelect: (ChamberCategory) -> Void, onSearch: () -> Void) {
            switch self {
            case .search:
                onSearch()
            case .category(let category, _, _):
                onSelect(category)
            }
        }
    }
}
