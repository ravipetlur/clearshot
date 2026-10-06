import AppKit
import SwiftUI

@Observable
final class SettingsModel {
    var selection: SettingsPane? = .general
}

final class SettingsWindowController: NSWindowController {
    private let model: SettingsModel

    init(coordinator: AppCoordinator) {
        let model = SettingsModel()
        self.model = model
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(pane: SettingsPane?) {
        if let pane { model.selection = pane }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
