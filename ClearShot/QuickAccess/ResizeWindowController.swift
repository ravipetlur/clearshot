import AppKit
import SwiftUI

/// The Resize… dialog window. One at a time; it keeps itself alive while open.
final class ResizeWindowController: NSWindowController, NSWindowDelegate {
    private static var current: ResizeWindowController?
    private var onClose: (() -> Void)?

    /// `onClose` runs once when the dialog goes away, however it closes (Resize, Cancel, the close button, or being
    /// replaced by another Resize dialog).
    static func present(pixelSize: CGSize, onResize: @escaping (Int, Int) -> Void, onClose: @escaping () -> Void) {
        current?.close()
        let controller = ResizeWindowController(pixelSize: pixelSize, onResize: onResize, onClose: onClose)
        current = controller
        controller.window?.center()
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(pixelSize: CGSize, onResize: @escaping (Int, Int) -> Void, onClose: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Resize"
        window.isReleasedWhenClosed = false
        self.onClose = onClose
        super.init(window: window)
        window.delegate = self
        let view = ResizeView(original: pixelSize,
                              onResize: { [weak self] width, height in
                                  onResize(width, height)
                                  self?.close()
                              },
                              onCancel: { [weak self] in self?.close() })
        window.contentViewController = NSHostingController(rootView: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
        let handler = onClose
        onClose = nil
        handler?()
    }
}
