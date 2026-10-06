import CoreGraphics

/// Toggle fullscreen: fills a selection's display, or, when it already fills it, brings back the selection it replaced
/// there. All-In-One's toolbar and a recording's Ready toolbar each keep one.
public struct FullscreenToggle: Sendable {
    /// The selection the last fill replaced, and its display.
    private var replaced: (rect: CGRect, displayID: UInt32)?

    public init() {}

    /// Only an adjustable selection that isn't being dragged, moved or resized: one that already fills its display
    /// comes back to what it replaced on that display, if anything; any other fills it.
    public mutating func toggle(_ selection: inout AdjustableSelection) {
        guard selection.phase == .adjusting, let rect = selection.rect, let display = selection.display else { return }
        if rect != display.frame {
            replaced = (rect, display.id)
            selection.setRect(display.frame, onDisplay: display.id)
        } else if let replaced, replaced.displayID == display.id {
            self.replaced = nil
            selection.setRect(replaced.rect, onDisplay: replaced.displayID)
        }
    }
}
