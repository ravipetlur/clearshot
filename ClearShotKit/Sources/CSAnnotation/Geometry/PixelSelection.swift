import CoreGraphics

/// The pixel-area selection the Select tool leaves on the picture (⌥-drag, or a drag that catches no object), and the
/// edits the editor's keys make to it. A selection is a rect on whole base pixels inside `0...bounds`, at least one pixel
/// a side; every function here returns one. The pixel tools (colour average, smart selection, contrast, object removal)
/// read `AnnotationEditor.pixelSelection`.
public enum PixelSelection {
    /// The selection a drag between two points makes: the corners round outward to the pixels they touch, then the rect is
    /// cut to the picture. Nil when the drag lies outside the picture or a point isn't a number.
    public static func between(_ a: CGPoint, _ b: CGPoint, in bounds: CGSize) -> CGRect? {
        guard [a.x, a.y, b.x, b.y].allSatisfy(\.isFinite) else { return nil }
        return clamped(CGRect(x: min(a.x, b.x).rounded(.down), y: min(a.y, b.y).rounded(.down),
                              width: abs(a.x - b.x).rounded(.up) + 1, height: abs(a.y - b.y).rounded(.up) + 1),
                       in: bounds)
    }

    /// `rect` on whole pixels and cut to the picture. Nil when it lies wholly outside the picture, isn't finite, or the
    /// picture is smaller than a pixel.
    public static func clamped(_ rect: CGRect, in bounds: CGSize) -> CGRect? {
        let rect = rect.standardized
        let width = bounds.width.rounded(.down), height = bounds.height.rounded(.down)
        guard [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite), width >= 1, height >= 1,
              rect.maxX >= 0, rect.maxY >= 0, rect.minX <= width, rect.minY <= height else { return nil }
        let left = min(max(rect.minX.rounded(), 0), width - 1)
        let top = min(max(rect.minY.rounded(), 0), height - 1)
        let right = min(max(rect.maxX.rounded(), left + 1), width)
        let bottom = min(max(rect.maxY.rounded(), top + 1), height)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The selection moved by `delta` pixels, stopping at the picture's edges with its size unchanged.
    public static func nudged(_ rect: CGRect, by delta: CGVector, in bounds: CGSize) -> CGRect {
        guard let fitted = clamped(rect, in: bounds) else { return rect }
        let dx = min(max(delta.dx.rounded(), -fitted.minX), bounds.width.rounded(.down) - fitted.maxX)
        let dy = min(max(delta.dy.rounded(), -fitted.minY), bounds.height.rounded(.down) - fitted.maxY)
        return fitted.offsetBy(dx: dx, dy: dy)
    }

    /// The right and bottom edges moved by `delta` pixels (negative shrinks), keeping the top left; one pixel is the least,
    /// the picture's edge the most.
    public static func resized(_ rect: CGRect, by delta: CGVector, in bounds: CGSize) -> CGRect {
        guard let fitted = clamped(rect, in: bounds) else { return rect }
        let width = min(max(fitted.width + delta.dx.rounded(), 1), bounds.width.rounded(.down) - fitted.minX)
        let height = min(max(fitted.height + delta.dy.rounded(), 1), bounds.height.rounded(.down) - fitted.minY)
        return CGRect(x: fitted.minX, y: fitted.minY, width: width, height: height)
    }

    /// Every edge moved out by `amount` pixels (negative moves them in), each stopping at the picture's edge. One that
    /// would shrink to nothing stays one pixel on that axis, at its middle.
    public static func grown(_ rect: CGRect, by amount: Double, in bounds: CGSize) -> CGRect {
        guard let fitted = clamped(rect, in: bounds) else { return rect }
        let amount = amount.rounded()
        var left = max(fitted.minX - amount, 0), right = min(fitted.maxX + amount, bounds.width.rounded(.down))
        var top = max(fitted.minY - amount, 0), bottom = min(fitted.maxY + amount, bounds.height.rounded(.down))
        if right - left < 1 { left = fitted.midX.rounded(.down); right = left + 1 }
        if bottom - top < 1 { top = fitted.midY.rounded(.down); bottom = top + 1 }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The selection with `handle` dragged to `point`: the opposite side stays, and a drag past it flips the selection
    /// over it. Whole pixels, inside the picture.
    public static func dragging(_ handle: Handle, of rect: CGRect, to point: CGPoint, in bounds: CGSize) -> CGRect {
        guard point.x.isFinite, point.y.isFinite, let fitted = clamped(rect, in: bounds) else { return rect }
        var x = (fitted.minX, fitted.maxX), y = (fitted.minY, fitted.maxY)
        switch handle {
        case .corner(let corner):
            if corner == .topLeft || corner == .bottomLeft { x.0 = point.x } else { x.1 = point.x }
            if corner == .topLeft || corner == .topRight { y.0 = point.y } else { y.1 = point.y }
        case .edge(let edge):
            switch edge {
            case .left: x.0 = point.x
            case .right: x.1 = point.x
            case .top: y.0 = point.y
            case .bottom: y.1 = point.y
            }
        case .start, .end, .control:
            return fitted
        }
        return clamped(CGRect(x: min(x.0, x.1), y: min(y.0, y.1), width: abs(x.1 - x.0), height: abs(y.1 - y.0)), in: bounds) ?? fitted
    }
}
