import CoreGraphics
import Foundation

/// An arrow's drawable pieces: `shaft` is stroked with the line width, `fills` are filled (heads, the fancy body).
public struct ArrowParts: @unchecked Sendable {
    public var shaft: CGPath
    public var fills: [CGPath]
}

/// Arrow shapes: standard, curved (quadratic, with a control point), fancy (tapered) and double-headed.
public enum ArrowGeometry {
    public static func headLength(for width: Double) -> Double {
        max(10, width * 3.5)
    }

    /// The curve's control point: the stored one, or the midpoint (a straight arrow) when none is set.
    public static func controlPoint(of arrow: ArrowShape) -> CGPoint {
        arrow.control ?? CGPoint(x: (arrow.start.x + arrow.end.x) / 2, y: (arrow.start.y + arrow.end.y) / 2)
    }

    /// A curved arrow's first bend, a quarter of its length off its middle, so it's clearly curved and its control handle
    /// is easy to grab.
    public static func initialControl(start: CGPoint, end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return CGPoint(x: (start.x + end.x) / 2 - dy * 0.25, y: (start.y + end.y) / 2 + dx * 0.25)
    }

    /// Points along the arrow's centre line, for hit testing and bounds.
    public static func spine(of arrow: ArrowShape, segments: Int = 24) -> [CGPoint] {
        guard arrow.style == .curved else { return [arrow.start, arrow.end] }
        let control = controlPoint(of: arrow)
        return (0...segments).map { index in
            let t = Double(index) / Double(segments)
            let a = (1 - t) * (1 - t)
            let b = 2 * (1 - t) * t
            let c = t * t
            return CGPoint(x: a * arrow.start.x + b * control.x + c * arrow.end.x,
                           y: a * arrow.start.y + b * control.y + c * arrow.end.y)
        }
    }

    /// The pieces to draw. Stroke `shaft` with round caps (it stops `width / 2` short of each head's base, so the cap
    /// meets the base instead of sinking into the head) and fill `fills`.
    ///
    /// Heads never take more than half the arrow (40% each when double-headed), so a short arrow keeps a forward-
    /// pointing head and the two heads of a double arrow never overlap. A shaft with no room left is empty.
    public static func parts(for arrow: ArrowShape, width: Double) -> ArrowParts {
        let chord = hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y)
        guard chord > 0.001 else {
            return ArrowParts(shaft: CGMutablePath(), fills: [])
        }
        if arrow.style == .fancy {
            return ArrowParts(shaft: CGMutablePath(), fills: [fancyBody(arrow, width: width, head: headLength(for: width))])
        }
        let isDouble = arrow.style == .double
        let length = min(headLength(for: width), chord * (isDouble ? 0.4 : 0.5))
        let chordDirection = unit(from: arrow.start, to: arrow.end)
        let control = controlPoint(of: arrow)
        // A control point sitting on the end makes the curve a straight line along the chord.
        let hook = hypot(arrow.end.x - control.x, arrow.end.y - control.y)
        let bent = arrow.style == .curved && hook > 0.001
        let endDirection = bent ? unit(from: control, to: arrow.end) : chordDirection

        var fills = [head(tip: arrow.end, direction: endDirection, length: length)]
        var endSetBack = length + width / 2
        if bent {
            // Never back the shaft up past the control point, or the curve would hook.
            endSetBack = min(endSetBack, hook)
        }
        var startSetBack = 0.0
        if isDouble {
            fills.append(head(tip: arrow.start, direction: unit(from: arrow.end, to: arrow.start), length: length))
            startSetBack = length + width / 2
        }
        guard chord - startSetBack - endSetBack > 0.001 else {
            return ArrowParts(shaft: CGMutablePath(), fills: fills)
        }
        let shaft = CGMutablePath()
        shaft.move(to: offset(arrow.start, chordDirection, startSetBack))
        let shaftEnd = offset(arrow.end, endDirection, -endSetBack)
        if bent {
            shaft.addQuadCurve(to: shaftEnd, control: control)
        } else {
            shaft.addLine(to: shaftEnd)
        }
        return ArrowParts(shaft: shaft, fills: fills)
    }

    private static func head(tip: CGPoint, direction: CGVector, length: Double) -> CGPath {
        let base = offset(tip, direction, -length)
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let half = length * 0.42
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: offset(base, normal, half))
        path.addLine(to: offset(base, normal, -half))
        path.closeSubpath()
        return path
    }

    /// A body that widens from the start towards a broad head.
    private static func fancyBody(_ arrow: ArrowShape, width: Double, head: Double) -> CGPath {
        let direction = unit(from: arrow.start, to: arrow.end)
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let total = hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y)
        let headBase = offset(arrow.end, direction, -min(head, total))
        let path = CGMutablePath()
        path.move(to: offset(arrow.start, normal, width * 0.2))
        path.addLine(to: offset(headBase, normal, width * 0.7))
        path.addLine(to: offset(headBase, normal, head * 0.6))
        path.addLine(to: arrow.end)
        path.addLine(to: offset(headBase, normal, -head * 0.6))
        path.addLine(to: offset(headBase, normal, -width * 0.7))
        path.addLine(to: offset(arrow.start, normal, -width * 0.2))
        path.closeSubpath()
        return path
    }

    static func unit(from a: CGPoint, to b: CGPoint) -> CGVector {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        return length > 0 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 1, dy: 0)
    }

    static func offset(_ point: CGPoint, _ direction: CGVector, _ distance: Double) -> CGPoint {
        CGPoint(x: point.x + direction.dx * distance, y: point.y + direction.dy * distance)
    }
}
