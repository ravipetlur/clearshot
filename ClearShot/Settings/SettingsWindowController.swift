import AppKit
import SwiftUI

@Observable
final class SettingsModel {
    var selection: SettingsPane? = .general
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel
    private unowned let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        let model = SettingsModel()
        self.model = model
        self.coordinator = coordinator
        let root = SettingsView(model: model, coordinator: coordinator)
            .environment(coordinator.preferences)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "ClearShot Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 760, height: 520))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ClearShotSettings")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The window is open on the About pane: where a check from Settings shows its answer.
    var isShowingAbout: Bool {
        (window?.isVisible ?? false) && model.selection == .about
    }

    /// Closing the window closes the About pane too, and with it the answer under Check Now.
    func windowWillClose(_ notification: Notification) {
        coordinator.updates?.aboutPaneClosed()
    }

    func show(pane: SettingsPane?) {
        if let pane { model.selection = pane }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
