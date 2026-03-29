import AppKit
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    private let viewModel: PreferencesViewModel

    init(viewModel: PreferencesViewModel) {
        self.viewModel = viewModel

        let root = PreferencesRootView(viewModel: viewModel)
        let host = NSHostingController(rootView: root)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SymbiAuth Preferences"
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 700)
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    func refresh() {
        viewModel.refresh()
    }

    func refreshTrustStateOnly() {
        viewModel.refreshTrustStateOnly()
    }
}
