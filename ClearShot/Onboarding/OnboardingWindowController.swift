import AppKit
import SwiftUI

final class OnboardingWindowController: NSWindowController {
    init(coordinator: AppCoordinator, onFinish: @escaping () -> Void) {
        let root = OnboardingView(coordinator: coordinator, onFinish: onFinish)
            .environment(coordinator.preferences)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Welcome to ClearShot"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
