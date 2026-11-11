import CoreGraphics
import Foundation

/// An arrow's drawable pieces: `shaft` is stroked with the line width, `fills` are filled (heads, the fancy body).
public struct ArrowParts: @unchecked Sendable {
    public var shaft: CGPath
    public var fills: [CGPath]
}

/// Arrow shapes: standard, curved, fancy (tapered) and double-headed. Any of them can be bent: an arrow with a control point
/// follows a quadratic curve through it.
public enum ArrowGeometry {
    public static func headLength(for width: Double) -> Double {
        max(10, width * 3.5)
    }

    /// The curve's control point: the stored one, or the midpoint (a straight arrow) when none is set.
    public static func controlPoint(of arrow: ArrowShape) -> CGPoint {
        arrow.control ?? CGPoint(x: (arrow.start.x + arrow.end.x) / 2, y: (arrow.start.y + arrow.end.y) / 2)
    }

    /// A curved arrow's first bend, a quarter of its length off its middle, so it's clearly curved and its bend handle
    /// is easy to grab.
    public static func initialControl(start: CGPoint, end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return CGPoint(x: (start.x + end.x) / 2 - dy * 0.25, y: (start.y + end.y) / 2 + dx * 0.25)
    }

    /// The curve's point at its middle, where the bend handle sits: for a straight arrow, the middle of the chord.
    public static func midpoint(of arrow: ArrowShape) -> CGPoint {
        let control = controlPoint(of: arrow)
        return CGPoint(x: (arrow.start.x + 2 * control.x + arrow.end.x) / 4, y: (arrow.start.y + 2 * control.y + arrow.end.y) / 4)
    }

    /// The control point that makes the curve pass through `point` at its middle (dragging the bend handle).
    public static func control(throughMidpoint point: CGPoint, of arrow: ArrowShape) -> CGPoint {
        CGPoint(x: 2 * point.x - (arrow.start.x + arrow.end.x) / 2, y: 2 * point.y - (arrow.start.y + arrow.end.y) / 2)
    }

    /// Points along the arrow's centre line, for hit testing and bounds.
    public static func spine(of arrow: ArrowShape, segments: Int = 24) -> [CGPoint] {
        guard let control = arrow.control else { return [arrow.start, arrow.end] }
        return quadPoints(from: arrow.start, control: control, to: arrow.end, segments: segments)
    }

    private static func quadPoints(from start: CGPoint, control: CGPoint, to end: CGPoint, segments: Int) -> [CGPoint] {
        (0...segments).map { index in quadPoint(from: start, control: control, to: end, at: Double(index) / Double(segments)) }
    }

    private static func quadPoint(from start: CGPoint, control: CGPoint, to end: CGPoint, at t: Double) -> CGPoint {
        let a = (1 - t) * (1 - t)
        let b = 2 * (1 - t) * t
        let c = t * t
        return CGPoint(x: a * start.x + b * control.x + c * end.x, y: a * start.y + b * control.y + c * end.y)
    }

    /// The pieces to draw. Stroke `shaft` with round caps (it stops `width / 2` short of each head's base, so the cap
    /// meets the base instead of sinking into the head) and fill `fills`.
    ///
    /// Heads never take more than half the arrow (40% each when double-headed), so a short arrow keeps a forward-
    /// pointing head and the two heads of a double arrow never overlap. A shaft with no room left is empty. A bent arrow
    /// (any style) has each head along the curve's tangent at that end.
    public static func parts(for arrow: ArrowShape, width: Double) -> ArrowParts {
        guard let layout = layout(for: arrow, width: width) else {
            return ArrowParts(shaft: CGMutablePath(), fills: [])
        }
        let shaft = CGMutablePath()
        if let line = layout.shaft {
            shaft.move(to: line.from)
            if let control = line.control {
                shaft.addQuadCurve(to: line.to, control: control)
            } else {
                shaft.addLine(to: line.to)
            }
        }
        return ArrowParts(shaft: shaft, fills: layout.fills.map(closedPath))
    }

    /// `parts` drawn by hand: the shaft as two wobbling passes, and each head (or the fancy body) filled and then outlined
    /// by two more. Stroke `shaft` with the line width and fill `fills`, as for `parts`. The same seed gives the same
    /// strokes.
    public static func roughParts(for arrow: ArrowShape, width: Double, seed: UInt32) -> ArrowParts {
        guard let layout = layout(for: arrow, width: width) else {
            return ArrowParts(shaft: CGMutablePath(), fills: [])
        }
        let chord = hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y)
        let amplitude = RoughPath.amplitude(lineWidth: width, extent: chord)
        var random = RoughRandom(seed: seed)
        var strokes: [[CGPoint]] = []
        if let line = layout.shaft {
            let points = line.control.map { quadPoints(from: line.from, control: $0, to: line.to, segments: 12) } ?? [line.from, line.to]
            strokes += RoughPath.polyline(points, closed: false, amplitude: amplitude, random: &random)
        }
        for outline in layout.fills {
            strokes += RoughPath.polyline(outline, closed: true, amplitude: amplitude * 0.5, random: &random)
        }
        return ArrowParts(shaft: RoughPath.path(from: strokes), fills: layout.fills.map(closedPath))
    }

    /// An arrow's shaft and filled shapes (as closed runs of points), before they become paths.
    private struct Layout {
        var shaft: (from: CGPoint, to: CGPoint, control: CGPoint?)?
        var fills: [[CGPoint]]
    }

    private static func layout(for arrow: ArrowShape, width: Double) -> Layout? {
        let chord = hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y)
        guard chord > 0.001 else { return nil }
        let headLength = headLength(for: width)
        // A control point sitting on an end makes the curve a straight line along the chord.
        let control = arrow.control.flatMap { control in
            hypot(arrow.end.x - control.x, arrow.end.y - control.y) > 0.001
                && hypot(arrow.start.x - control.x, arrow.start.y - control.y) > 0.001 ? control : nil
        }
        let chordDirection = unit(from: arrow.start, to: arrow.end)
        let endDirection = control.map { unit(from: $0, to: arrow.end) } ?? chordDirection
        if arrow.style == .fancy {
            return Layout(shaft: nil, fills: [fancyBody(arrow, control: control, width: width, head: headLength,
                                                        endDirection: endDirection)])
        }
        let isDouble = arrow.style == .double
        let length = min(headLength, chord * (isDouble ? 0.4 : 0.5))
        let startDirection = control.map { unit(from: $0, to: arrow.start) }
            ?? CGVector(dx: -chordDirection.dx, dy: -chordDirection.dy)

        var fills = [head(tip: arrow.end, direction: endDirection, length: length)]
        var endSetBack = length + width / 2
        var startSetBack = 0.0
        if isDouble {
            fills.append(head(tip: arrow.start, direction: startDirection, length: length))
            startSetBack = length + width / 2
        }
        if let control {
            // Never back the shaft up past the control point, or the curve would hook.
            endSetBack = min(endSetBack, hypot(arrow.end.x - control.x, arrow.end.y - control.y))
            startSetBack = min(startSetBack, hypot(arrow.start.x - control.x, arrow.start.y - control.y))
        }
        guard chord - startSetBack - endSetBack > 0.001 else {
            return Layout(shaft: nil, fills: fills)
        }
        return Layout(shaft: (offset(arrow.start, startDirection, -startSetBack),
                              offset(arrow.end, endDirection, -endSetBack), control),
                      fills: fills)
    }

    private static func closedPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    private static func head(tip: CGPoint, direction: CGVector, length: Double) -> [CGPoint] {
        let base = offset(tip, direction, -length)
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let half = length * 0.42
        return [tip, offset(base, normal, half), offset(base, normal, -half)]
    }

    /// A body that widens from the start towards a broad head. A bent arrow's body follows the curve and its head points
    /// along the tangent at the end.
    private static func fancyBody(_ arrow: ArrowShape, control: CGPoint?, width: Double, head: Double,
                                  endDirection direction: CGVector) -> [CGPoint] {
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let total = hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y)
        let headBase = offset(arrow.end, direction, -min(head, total))
        guard let control else {
            return [offset(arrow.start, normal, width * 0.2), offset(headBase, normal, width * 0.7),
                    offset(headBase, normal, head * 0.6), arrow.end, offset(headBase, normal, -head * 0.6),
                    offset(headBase, normal, -width * 0.7), offset(arrow.start, normal, -width * 0.2)]
        }
        // The body runs along the curve up to the head's base: to the last sample at least as far from the tip as the base.
        let reach = hypot(arrow.end.x - headBase.x, arrow.end.y - headBase.y)
        let samples = 24
        let bodyEnd = max(1, (0...samples).last { index in
            let point = quadPoint(from: arrow.start, control: control, to: arrow.end, at: Double(index) / Double(samples))
            return hypot(arrow.end.x - point.x, arrow.end.y - point.y) >= reach
        } ?? 1)
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for index in 0...bodyEnd {
            let t = Double(index) / Double(samples)
            let point = quadPoint(from: arrow.start, control: control, to: arrow.end, at: t)
            let tangent = tangent(from: arrow.start, control: control, to: arrow.end, at: t)
            let side = CGVector(dx: -tangent.dy, dy: tangent.dx)
            let half = width * (0.2 + 0.5 * Double(index) / Double(bodyEnd))
            left.append(offset(point, side, half))
            right.append(offset(point, side, -half))
        }
        return left + [offset(headBase, normal, head * 0.6), arrow.end, offset(headBase, normal, -head * 0.6)] + right.reversed()
    }

    /// The unit tangent of the quadratic curve at `t`.
    private static func tangent(from start: CGPoint, control: CGPoint, to end: CGPoint, at t: Double) -> CGVector {
        let dx = 2 * (1 - t) * (control.x - start.x) + 2 * t * (end.x - control.x)
        let dy = 2 * (1 - t) * (control.y - start.y) + 2 * t * (end.y - control.y)
        let length = hypot(dx, dy)
        return length > 0 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 1, dy: 0)
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
