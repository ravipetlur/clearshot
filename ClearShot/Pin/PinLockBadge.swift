import AppKit
import CSCapture

/// The unlock badge of a locked pin: a 24-pt dark circle with a lock, in its own small window at the pin's top-right
/// corner, shown while the pointer is over the pin. A click unlocks the pin. Like the pin it never activates ClearShot,
/// and it never becomes key.
final class PinLockBadge: NSPanel {
    private static let side: CGFloat = 24
    /// How far in from the pin's top-right corner it sits.
    private static let inset: CGFloat = 6

    /// A click on the badge.
    var onUnlock: (() -> Void)?
    /// The pointer left the badge. Global monitors get no events while the pointer is over ClearShot's own windows, so
    /// this is how the pin hears that it may have to hide the badge.
    var onPointerExited: (() -> Void)?

    private let button = CircleButton(symbol: "lock.fill", label: "Unlock")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: WindowLevels.pin)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // "Unlock" shows while another app is active, as it nearly always is.
        allowsToolTipsWhenApplicationIsInactive = true
        let content = PinLockBadgeView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        content.onExited = { [weak self] in self?.onPointerExited?() }
        button.frame = content.bounds
        button.autoresizingMask = [.width, .height]
        button.target = self
        button.action = #selector(unlockPressed(_:))
        content.addSubview(button)
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Where the badge goes for a pin with this frame.
    static func frame(forPin pinFrame: CGRect) -> CGRect {
        CGRect(x: pinFrame.maxX - inset - side, y: pinFrame.maxY - inset - side, width: side, height: side)
    }

    @objc private func unlockPressed(_ sender: Any?) {
        onUnlock?()
    }
}

/// The badge's content: tells the badge when the pointer leaves it.
private final class PinLockBadgeView: NSView {
    var onExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseExited(with event: NSEvent) {
        onExited?()
    }
}
