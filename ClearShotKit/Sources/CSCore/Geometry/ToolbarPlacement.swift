import CoreGraphics

/// Where a selection's toolbar goes: centred under the selection, else over it, else inside its bottom edge, always
/// within the screen's visible frame. AppKit global points.
public enum ToolbarPlacement {
    public enum Side: Sendable, Equatable {
        case below, above, inside
    }

    /// Between the selection and the toolbar.
    public static let gap: CGFloat = 12
    /// Kept clear along the edges of the visible frame.
    public static let margin: CGFloat = 8

    /// The toolbar's frame (origin in whole points) and which side of the selection it ended up on. `visibleFrame` is the
    /// selection's screen without the menu bar and the Dock (`NSScreen.visibleFrame`).
    public static func frame(size: CGSize, anchoredTo selection: CGRect, visibleFrame: CGRect) -> (frame: CGRect, side: Side) {
        let lowest = visibleFrame.minY + margin
        let highest = visibleFrame.maxY - margin
        let below = selection.minY - gap - size.height
        let above = selection.maxY + gap
        let y: CGFloat
        let side: Side
        if below >= lowest {
            (y, side) = (below, .below)
        } else if above + size.height <= highest {
            (y, side) = (above, .above)
        } else {
            (y, side) = (max(selection.minY + gap, lowest), .inside)
        }
        // A toolbar wider than the visible frame keeps its left end on screen.
        let x = max(min(selection.midX - size.width / 2, visibleFrame.maxX - margin - size.width), visibleFrame.minX + margin)
        return (CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size), side)
    }
}
