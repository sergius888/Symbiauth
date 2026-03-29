import SwiftUI

struct LogsView: View {
    @ObservedObject var viewModel: PairingViewModel
    @State private var selectedFilter: LogFilter = .all

    var body: some View {
        ZStack {
            AppBackground()

            VStack(alignment: .leading, spacing: 18) {
                TerminalSectionHeader(
                    kicker: "[ SESSION HISTORY ]",
                    title: "Logs",
                    detail: "Review trust changes, connection transitions, and session events."
                )

                filterBar

                if filteredEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("No events yet")
                            .font(AppTypography.heading(19))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("Start and end a session to build a history timeline here.")
                            .font(AppTypography.body(15))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .appPanel()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredEntries) { entry in
                                LogRow(entry: entry)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding()
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(LogFilter.allCases, id: \.self) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    Text(filter.label)
                        .font(AppTypography.caption(12))
                        .foregroundStyle(selectedFilter == filter ? Color.white : AppTheme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedFilter == filter ? AppTheme.accent : AppTheme.panelStrong)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppTheme.stroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var filteredEntries: [PairingViewModel.LogEntry] {
        switch selectedFilter {
        case .all:
            return viewModel.logEntries
        case .trust:
            return viewModel.logEntries.filter { $0.category == .trust }
        case .connection:
            return viewModel.logEntries.filter { $0.category == .connection }
        case .session:
            return viewModel.logEntries.filter { $0.category == .session }
        }
    }
}

private enum LogFilter: CaseIterable {
    case all
    case trust
    case connection
    case session

    var label: String {
        switch self {
        case .all: return "All"
        case .trust: return "Trust"
        case .connection: return "Connection"
        case .session: return "Session"
        }
    }
}

private struct LogRow: View {
    let entry: PairingViewModel.LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(categoryColor)
                .frame(width: 10, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                        .font(AppTypography.heading(16))
                        .foregroundStyle(AppTheme.textPrimary)

                    Spacer()

                    Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(AppTypography.caption())
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Text(entry.detail)
                    .font(AppTypography.body(15))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .appPanel()
    }

    private var categoryColor: Color {
        switch entry.category {
        case .trust:
            return AppTheme.accent
        case .connection:
            return AppTheme.warning
        case .session:
            return AppTheme.success
        }
    }
}
