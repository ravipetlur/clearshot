import AppKit
import CSCapture

/// One display's desktop cover: a borderless panel just above the desktop icons and widgets and below every window
/// (`WindowLevels.desktopCover`), on every Space and left in place by Mission Control and Show Desktop. It never
/// activates ClearShot and never takes key; its view takes clicks and drops all the same.
final class DesktopCoverPanel: NSPanel {
    private let cover: DesktopCoverView

    /// A double-click on the cover, or "Show Desktop Icons" from its right-click menu.
    var onShowIcons: (() -> Void)? {
        get { cover.onShowIcons }
        set { cover.onShowIcons = newValue }
    }

    init(drops: DesktopDropReceiver) {
        cover = DesktopCoverView(frame: .zero, drops: drops)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: WindowLevels.desktopCover)
        // No .fullScreenAuxiliary: a full-screen app's Space has no desktop to cover.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = cover
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `picture`, the provider's own image. The panel comes on screen with its first picture, so it never shows
    /// black.
    func show(_ picture: CGImage) {
        cover.picture = picture
        if !isVisible { orderFrontRegardless() }
    }
}
