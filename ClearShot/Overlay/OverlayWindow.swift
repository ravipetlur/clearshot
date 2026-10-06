import AppKit
import CSCore

/// A full-display, borderless panel above everything (menu bar, Dock, full-screen apps).
final class OverlayWindow: NSPanel {
    let overlayView: OverlayView

    init(display: DisplayInfo) {
        overlayView = OverlayView(frame: NSRect(origin: .zero, size: display.frame.size))
        super.init(contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        // Not .clear: the window server passes mouse events through pixels with zero alpha, so a fully transparent
        // overlay (dim off, not frozen) would get no moves or clicks. 1% black is invisible but keeps it hit-testable.
        backgroundColor = NSColor.black.withAlphaComponent(0.01)
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = overlayView
        setFrame(display.frame, display: false)
        // Key events (Esc, Space, F, modifier changes) go to the first responder of the key window.
        makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
