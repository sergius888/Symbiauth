//
//  ContentView.swift
//  ArmadilloMobile
//
//  Created by Chiricescu Sergiu on 15.09.2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var pairingViewModel = PairingViewModel()
    @State private var selectedTab: AppTab = .home
    @State private var showLaunchOverlay = true

    var body: some View {
        ZStack {
            switch selectedTab {
            case .home:
                NavigationStack {
                    HomeView(viewModel: pairingViewModel)
                        .navigationBarTitleDisplayMode(.inline)
                }
            case .macs:
                NavigationStack {
                    MacsView(viewModel: pairingViewModel)
                        .navigationBarTitleDisplayMode(.inline)
                }
            case .logs:
                NavigationStack {
                    LogsView(viewModel: pairingViewModel)
                        .navigationBarTitleDisplayMode(.inline)
                }
            case .settings:
                NavigationStack {
                    SettingsScreen(viewModel: pairingViewModel)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }

            if showLaunchOverlay {
                AppLaunchOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    .zIndex(10)
            } else {
                VStack {
                    Spacer()
                    TerminalTabBar(
                        items: [
                            TerminalTabItem(id: AppTab.home.rawValue, marker: "[/]", label: "HOME"),
                            TerminalTabItem(id: AppTab.macs.rawValue, marker: "[M]", label: "MACS"),
                            TerminalTabItem(id: AppTab.logs.rawValue, marker: "[L]", label: "LOGS"),
                            TerminalTabItem(id: AppTab.settings.rawValue, marker: "[=]", label: "SET")
                        ],
                        selected: selectedTab.rawValue,
                        onSelect: { raw in
                            if let next = AppTab(rawValue: raw) {
                                selectedTab = next
                            }
                        }
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .fullScreenCover(isPresented: $pairingViewModel.trustSessionActive) {
            SessionView(viewModel: pairingViewModel)
        }
        .task {
            guard showLaunchOverlay else { return }
            try? await Task.sleep(for: .milliseconds(950))
            withAnimation(.easeOut(duration: 0.28)) {
                showLaunchOverlay = false
            }
        }
    }
}

private enum AppTab: String {
    case home
    case macs
    case logs
    case settings
}

#Preview {
    ContentView()
}
