import AppKit
import Combine
import SwiftUI

final class FloatingChamberPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SecretChamberWindowController: NSObject, NSWindowDelegate {
    private enum PersistedPosition {
        static let x = "SecretChamber.spine.origin.x"
        static let y = "SecretChamber.spine.origin.y"
    }

    private let viewModel: PreferencesViewModel
    private let onManualClose: () -> Void
    private let onEndSession: () -> Void
    private var spinePanel: FloatingChamberPanel?
    private var listPanel: FloatingChamberPanel?
    private var searchPanel: FloatingChamberPanel?
    private var detailPanel: FloatingChamberPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var suppressCloseCallback = false
    private var suppressPanelSync = false
    private var detailModeHost: NSHostingController<AnyView>?

    init(
        viewModel: PreferencesViewModel,
        onManualClose: @escaping () -> Void,
        onEndSession: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onManualClose = onManualClose
        self.onEndSession = onEndSession
        super.init()
        bindViewModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isChamberVisible: Bool {
        spinePanel?.isVisible == true || listPanel?.isVisible == true || searchPanel?.isVisible == true || detailPanel?.isVisible == true
    }

    func showChamber() {
        ensurePanels()
        suppressPanelSync = true
        viewModel.resetChamberTransientState()
        NSApp.activate(ignoringOtherApps: true)
        let firstShow = spinePanel?.isVisible != true
        if firstShow {
            positionPanelsIfNeeded(forceReset: true)
        } else {
            positionPanelsIfNeeded(forceReset: false)
        }
        show(panel: spinePanel, animated: firstShow)
        hide(panel: listPanel)
        hide(panel: searchPanel)
        hide(panel: detailPanel)
        suppressPanelSync = false
        syncSecondaryPanels(animated: false)
        viewModel.refreshTrustStateOnly()
        viewModel.refreshChamberData()
    }

    func closeChamber() {
        suppressCloseCallback = true
        hide(panel: detailPanel)
        hide(panel: searchPanel)
        hide(panel: listPanel)
        spinePanel?.orderOut(nil)
        spinePanel?.alphaValue = 1
        suppressCloseCallback = false
    }

    func windowWillClose(_ notification: Notification) {
        if suppressCloseCallback { return }
        closeChamber()
        onManualClose()
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == spinePanel else { return }
        persistSpineOrigin(window.frame.origin)
    }

    private func bindViewModel() {
        viewModel.$selectedChamberItemId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.suppressPanelSync == false else { return }
                self?.syncDetailPanel(animated: true)
            }
            .store(in: &cancellables)

        viewModel.$showingChamberEditor
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.suppressPanelSync == false else { return }
                self?.syncDetailPanel(animated: true)
            }
            .store(in: &cancellables)

        viewModel.$chamberFilterVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.suppressPanelSync == false else { return }
                self?.syncDetailPanel(animated: true)
            }
            .store(in: &cancellables)

        viewModel.$chamberPanelCategory
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.suppressPanelSync == false else { return }
                self?.syncSecondaryPanels(animated: true)
            }
            .store(in: &cancellables)

        viewModel.$chamberSearchVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.suppressPanelSync == false else { return }
                self?.syncSecondaryPanels(animated: true)
            }
            .store(in: &cancellables)

        viewModel.$trustedShellExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.suppressPanelSync == false else { return }
                self?.positionPanelsIfNeeded(forceReset: false, anchoredToSpine: true)
            }
            .store(in: &cancellables)
    }

    private func ensurePanels() {
        if spinePanel == nil {
            let host = NSHostingController(rootView: IndustrialChamberSpineView(
                viewModel: viewModel,
                onSelect: { [weak self] category in
                    self?.viewModel.selectChamberCategory(category)
                },
                onSearch: { [weak self] in
                    self?.viewModel.toggleChamberSearch()
                }
            ))
            let panel = makePanel(size: NSSize(width: 56, height: 470), content: host)
            panel.delegate = self
            panel.isMovableByWindowBackground = true
            spinePanel = panel
        }

        if listPanel == nil {
            let host = NSHostingController(rootView: IndustrialChamberListPanelView(viewModel: viewModel))
            let panel = makePanel(size: NSSize(width: 390, height: 620), content: host)
            panel.delegate = self
            listPanel = panel
        }

        if searchPanel == nil {
            let host = NSHostingController(rootView: IndustrialChamberSearchPanelView(viewModel: viewModel))
            let panel = makePanel(size: NSSize(width: 390, height: 620), content: host)
            panel.delegate = self
            searchPanel = panel
        }

        if detailPanel == nil {
            let host = NSHostingController(rootView: AnyView(IndustrialChamberDetailPanelView(viewModel: viewModel)))
            detailModeHost = host
            let panel = makePanel(size: NSSize(width: 430, height: 620), content: host)
            panel.delegate = self
            detailPanel = panel
        }
    }

    private func makePanel(size: NSSize, content: NSHostingController<some View>) -> FloatingChamberPanel {
        let panel = FloatingChamberPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentViewController = content
        return panel
    }

    private func show(panel: FloatingChamberPanel?, animated: Bool) {
        guard let panel else { return }
        attachIfNeeded(panel)
        let wasVisible = panel.isVisible
        panel.alphaValue = wasVisible || !animated ? 1 : 0
        panel.orderFrontRegardless()
        panel.makeKey()
        guard animated, !wasVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    private func hide(panel: FloatingChamberPanel?) {
        guard let panel else { return }
        panel.orderOut(nil)
        panel.alphaValue = 0
        panel.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
    }

    private func attachIfNeeded(_ panel: FloatingChamberPanel) {
        guard let spinePanel, panel !== spinePanel else { return }
        if panel.parent !== spinePanel {
            panel.parent?.removeChildWindow(panel)
            spinePanel.addChildWindow(panel, ordered: .above)
        }
    }

    private func syncDetailPanel(animated: Bool) {
        guard let detailPanel else { return }
        let shouldShowFilter = viewModel.chamberFilterVisible && (viewModel.chamberSearchVisible || viewModel.chamberPanelCategory != nil)
        let shouldShowDetail = (viewModel.showingChamberEditor || viewModel.selectedChamberItem != nil) &&
            (!viewModel.chamberSearchVisible && viewModel.chamberPanelCategory != nil)
        let shouldShow = shouldShowFilter || shouldShowDetail
        positionPanelsIfNeeded(forceReset: false)
        if shouldShow {
            syncDetailModeContent()
            show(panel: detailPanel, animated: animated)
        } else {
            hide(panel: detailPanel)
        }
    }

    private func syncDetailModeContent() {
        if viewModel.chamberFilterVisible {
            detailModeHost?.rootView = AnyView(IndustrialChamberFilterPanelView(viewModel: viewModel))
        } else {
            detailModeHost?.rootView = AnyView(IndustrialChamberDetailPanelView(viewModel: viewModel))
        }
    }

    private func syncSecondaryPanels(animated: Bool) {
        ensurePanels()
        positionPanelsIfNeeded(forceReset: false)
        if viewModel.chamberSearchVisible {
            hide(panel: listPanel)
            hide(panel: detailPanel)
            show(panel: searchPanel, animated: animated)
        } else if viewModel.chamberPanelCategory != nil {
            hide(panel: searchPanel)
            show(panel: listPanel, animated: animated)
        } else {
            hide(panel: searchPanel)
            hide(panel: listPanel)
            hide(panel: detailPanel)
        }
        syncDetailPanel(animated: animated)
    }

    private func positionPanelsIfNeeded(forceReset: Bool, anchoredToSpine: Bool = false) {
        ensurePanels()
        guard let spinePanel, let listPanel, let searchPanel, let detailPanel else { return }
        guard let screen = spinePanel.screen ?? NSScreen.main ?? listPanel.screen else { return }
        let visible = screen.visibleFrame
        let gap: CGFloat = 14
        let spineSize = NSSize(width: 62, height: 470)
        let safe = visible.insetBy(dx: 24, dy: 24)
        let listSize = currentListPanelSize(in: safe, spineSize: spineSize, gap: gap)
        let detailSize = NSSize(width: 430, height: 620)

        var spineOrigin = spinePanel.frame.origin
        if forceReset {
            spineOrigin = restoredSpineOrigin(in: safe, spineSize: spineSize) ?? centeredSpineOrigin(in: visible, safe: safe, spineSize: spineSize, listSize: listSize, detailSize: detailSize, gap: gap)
        } else if !anchoredToSpine && !safe.contains(spinePanel.frame) {
            spineOrigin = centeredSpineOrigin(in: visible, safe: safe, spineSize: spineSize, listSize: listSize, detailSize: detailSize, gap: gap)
        }

        let maxSpineXForAttachedList = max(safe.minX, safe.maxX - spineSize.width - gap - listSize.width)
        spineOrigin.x = max(safe.minX, min(spineOrigin.x, maxSpineXForAttachedList))
        spineOrigin.y = max(safe.minY, min(spineOrigin.y, safe.maxY - spineSize.height))

        let listOrigin = CGPoint(
            x: min(spineOrigin.x + spineSize.width + gap, safe.maxX - listSize.width),
            y: max(safe.minY, min(spineOrigin.y - (listSize.height - spineSize.height) / 2, safe.maxY - listSize.height))
        )

        let detailOrigin = CGPoint(
            x: min(listOrigin.x + listSize.width + gap, safe.maxX - detailSize.width),
            y: max(safe.minY, min(listOrigin.y, safe.maxY - detailSize.height))
        )

        spinePanel.setFrame(NSRect(origin: spineOrigin, size: spineSize), display: false)
        listPanel.setFrame(NSRect(origin: listOrigin, size: listSize), display: false)
        searchPanel.setFrame(NSRect(origin: listOrigin, size: listSize), display: false)
        detailPanel.setFrame(NSRect(origin: detailOrigin, size: detailSize), display: false)
        listPanel.level = .statusBar
        attachIfNeeded(listPanel)
    }

    private func currentListPanelSize(in safe: NSRect, spineSize: NSSize, gap: CGFloat) -> NSSize {
        if viewModel.chamberCategory == .shell {
            let availableWidth = max(900, safe.width - spineSize.width - gap - 8)
            let width = min(1120, availableWidth)
            let height = min(820, safe.height)
            return NSSize(width: width, height: height)
        }
        return NSSize(width: 390, height: 620)
    }

    private func centeredSpineOrigin(in visible: NSRect, safe: NSRect, spineSize: NSSize, listSize: NSSize, detailSize: NSSize, gap: CGFloat) -> CGPoint {
        let totalWidth = spineSize.width + gap + listSize.width + gap + detailSize.width
        let targetX = max(safe.minX, min(visible.midX - (totalWidth / 2), safe.maxX - totalWidth))
        let targetY = max(safe.minY, min(visible.midY - (listSize.height / 2), safe.maxY - listSize.height))
        return CGPoint(x: targetX, y: targetY + (listSize.height - spineSize.height) / 2)
    }

    private func restoredSpineOrigin(in safe: NSRect, spineSize: NSSize) -> CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PersistedPosition.x) != nil,
              defaults.object(forKey: PersistedPosition.y) != nil else {
            return nil
        }
        let x = defaults.double(forKey: PersistedPosition.x)
        let y = defaults.double(forKey: PersistedPosition.y)
        return CGPoint(
            x: max(safe.minX, min(CGFloat(x), safe.maxX - spineSize.width)),
            y: max(safe.minY, min(CGFloat(y), safe.maxY - spineSize.height))
        )
    }

    private func persistSpineOrigin(_ origin: CGPoint) {
        let defaults = UserDefaults.standard
        defaults.set(origin.x, forKey: PersistedPosition.x)
        defaults.set(origin.y, forKey: PersistedPosition.y)
    }
}
