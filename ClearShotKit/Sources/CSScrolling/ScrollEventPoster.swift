import CoreGraphics

/// Auto-scroll's hands: continuous pixel scroll-wheel events, like a trackpad's, and the cursor that aims them.
/// Positions are CG global points (origin at the main display's top-left, y down), the space `CGEvent` uses.
public enum ScrollEventPoster {
    /// Whether macOS lets ClearShot post events (Accessibility permission).
    public static var canPost: Bool {
        CGPreflightPostEventAccess()
    }

    /// A scroll of `points` that reveals content below (vertical) or to the right (horizontal); negative `points`
    /// scroll back. A wheel delta is positive for "scroll up" (content moves down), so going forward posts negative
    /// deltas. The event goes to whatever is under `location`.
    public static func makeEvent(axis: ScrollAxis, points: Int32, atCG location: CGPoint) -> CGEvent? {
        let (vertical, horizontal): (Int32, Int32) = axis == .vertical ? (-points, 0) : (0, -points)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return nil }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.location = location
        return event
    }

    /// Posts `makeEvent`'s scroll to the HID event stream, as if it came from a trackpad.
    public static func post(axis: ScrollAxis, points: Int32, atCG location: CGPoint) {
        makeEvent(axis: axis, points: points, atCG: location)?.post(tap: .cghidEventTap)
    }

    /// Where the cursor is now.
    public static func cursorLocationCG() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Moves the cursor without a mouse event, then reconnects it to the mouse at once (warping alone leaves the
    /// cursor frozen for a moment).
    public static func warpCursor(toCG location: CGPoint) {
        CGWarpMouseCursorPosition(location)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
