import CoreGraphics
import Foundation

/// What ⇧ does while drawing and moving.
public enum ShapeConstraints {
    /// The rect from `anchor` to `point`; `square` makes it square, keeping the drag direction.
    public static func rect(from anchor: CGPoint, to point: CGPoint, square: Bool) -> CGRect {
        var dx = point.x - anchor.x
        var dy = point.y - anchor.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return CGRect(x: anchor.x, y: anchor.y, width: dx, height: dy).standardized
    }

    /// `point` moved so the line from `anchor` sits at a multiple of 45°, keeping its length.
    public static func snapped(_ point: CGPoint, from anchor: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        let step = Double.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
    }

    /// A move locked to its dominant axis.
    public static func axisLocked(_ delta: CGVector) -> CGVector {
        abs(delta.dx) >= abs(delta.dy) ? CGVector(dx: delta.dx, dy: 0) : CGVector(dx: 0, dy: delta.dy)
    }
}
