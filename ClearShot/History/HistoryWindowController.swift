import AppKit
import CSCore
import CSHistory
import SwiftUI

/// Capture History: a titled window with SwiftUI chrome around the AppKit grid. It opens on the pointer's screen unless
/// it was left mostly there, and activates ClearShot without changing the activation policy, like Settings. The
/// coordinator makes it once and keeps it, so the grid, its caches and its selection last while ClearShot runs. It
/// carries out the grid's actions (`HistoryWindowController+Actions.swift`).
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private static let autosaveName = "ClearShotHistory"

    private let model: HistoryModel
    // Internal rather than private so HistoryWindowController+Actions.swift can use them.
    let grid: HistoryGrid
    let history: HistoryStore
    let preferences: Preferences
    let itemActions: HistoryItemActions
    let quickAccess: QuickAccessManager
    let annotate: AnnotateManager
    let videoEditor: VideoEditorManager
    let pins: PinManager
    let hud: HUDController
    /// No frame was saved when the window was made: the first show centres it on the pointer's screen.
    private var needsPlacement: Bool

    init(coordinator: AppCoordinator) {
        let model = HistoryModel(history: coordinator.history, preferences: coordinator.preferences)
        let grid = HistoryGrid(model: model, history: coordinator.history, itemActions: coordinator.itemActions)
        self.model = model
        self.grid = grid
        history = coordinator.history
        preferences = coordinator.preferences
        itemActions = coordinator.itemActions
        quickAccess = coordinator.quickAccess
        annotate = coordinator.annotate
        videoEditor = coordinator.videoEditor
        pins = coordinator.pins
        hud = coordinator.hud
        let root = HistoryView(model: model, grid: grid, coordinator: coordinator)
            .environment(coordinator.preferences)
        let hosting = NSHostingController(rootView: root)
        // The window's size is its own (and the person's); SwiftUI brings only the toolbar, not a title.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Capture History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 820, height: 560))
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        needsPlacement = !window.setFrameUsingName(Self.autosaveName)
        window.setFrameAutosaveName(Self.autosaveName)
        super.init(window: window)
        window.delegate = self
        grid.collectionView.actions = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        if !window.isVisible, let screen = NSScreen.activeScreen,
           needsPlacement || !Self.isMostly(window.frame, on: screen.frame) {
            window.setFrame(Self.centred(window.frame.size, in: screen.visibleFrame), display: false)
        }
        needsPlacement = false
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        grid.focus()
        model.startClock()
    }

    // MARK: Placement

    /// More than half of `frame` is on the screen.
    private static func isMostly(_ frame: NSRect, on screen: NSRect) -> Bool {
        let overlap = frame.intersection(screen)
        return overlap.width * overlap.height > frame.width * frame.height / 2
    }

    /// A frame of `size`, shrunk to fit if need be, in the middle of `visible`.
    private static func centred(_ size: NSSize, in visible: NSRect) -> NSRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        return NSRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(),
                      width: width, height: height)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        grid.collectionView.endQuickLook()
        model.stopClock()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model.stopClock()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        model.startClock()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        grid.refreshSelectionEmphasis()
    }

    func windowDidResignKey(_ notification: Notification) {
        grid.refreshSelectionEmphasis()
    }
}
