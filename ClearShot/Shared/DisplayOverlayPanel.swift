import AppKit
import CSCore

/// A borderless, clear, click-through panel over one whole display, for what a live capture draws over the screen while
/// the person works in the apps below: the region frame (`RegionFrameWindow`) and the recording's click rings
/// (`ClickHighlighter`). Non-activating and never key or main, on every Space and over full-screen apps, left out of the
/// window cycle, and never released or animated by AppKit.
class DisplayOverlayPanel: NSPanel {
    init(display: DisplayInfo, level: NSWindow.Level) {
        super.init(contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(display.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
