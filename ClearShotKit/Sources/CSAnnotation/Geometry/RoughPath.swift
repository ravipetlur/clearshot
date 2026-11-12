import CoreGraphics
import Foundation

/// A small seeded generator (SplitMix64), so a hand-drawn shape is the same on every draw, in every process: undo, copy,
/// save and reopen all give back exactly the strokes the seed made. Nothing here reads the system's randomness.
public struct RoughRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt32) {
        state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 ^ 0xD1B5_4A32_D192_ED03
    }

    mutating func nextBits() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// In 0 ..< 1.
    public mutating func unit() -> Double {
        Double(nextBits() >> 11) / Double(1 << 53)
    }

    /// In -1 ..< 1.
    public mutating func signed() -> Double {
        unit() * 2 - 1
    }
}

/// The hand-drawn look: every shape is drawn as two slightly different passes, each wobbling off the clean outline by up to
/// `amplitude` and, on an open stroke, overshooting its ends a little. The strokes are lists of points (`path(from:)` joins
/// them smoothly), so the result can be checked against the clean shape; no point is farther from it than
/// `RoughPath.reachFactor * amplitude`.
public enum RoughPath {
    /// How far, in amplitudes, a stroke can stray from the clean shape.
    public static let reachFactor = 3.0
    static let passes = 2

    /// How far a stroke wobbles, in base pixels: with the line width, but never enough to wreck a small shape.
    public static func amplitude(lineWidth: Double, extent: Double) -> Double {
        min(max(lineWidth * 0.75, 1.5), max(extent * 0.05, 0.75))
    }

    /// Two passes along the straight line from `start` to `end`.
    public static func line(from start: CGPoint, to end: CGPoint, amplitude: Double, seed: UInt32) -> [[CGPoint]] {
        var random = RoughRandom(seed: seed)
        return line(from: start, to: end, amplitude: amplitude, random: &random)
    }

    /// Two passes along an open or closed run of points.
    public static func polyline(_ points: [CGPoint], closed: Bool, amplitude: Double, seed: UInt32) -> [[CGPoint]] {
        var random = RoughRandom(seed: seed)
        return polyline(points, closed: closed, amplitude: amplitude, random: &random)
    }

    /// A rectangle drawn as four sides, each of two passes that overshoot the corners.
    public static func rectangle(_ rect: CGRect, amplitude: Double, seed: UInt32) -> [[CGPoint]] {
        var random = RoughRandom(seed: seed)
        let rect = rect.standardized
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        return corners.indices.flatMap { index in
            line(from: corners[index], to: corners[(index + 1) % corners.count], amplitude: amplitude, random: &random)
        }
    }

    /// An ellipse drawn as a closed curve of two passes, each starting at its own angle and running a little past where it
    /// began.
    public static func ellipse(_ rect: CGRect, amplitude: Double, seed: UInt32) -> [[CGPoint]] {
        var random = RoughRandom(seed: seed)
        let rect = rect.standardized
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        let perimeter = Double.pi * (3 * (radiusX + radiusY) - ((3 * radiusX + radiusY) * (radiusX + 3 * radiusY)).squareRoot())
        let count = min(max(Int((perimeter / step(for: amplitude)).rounded()), 12), 72)
        return (0..<passes).map { _ in
            let first = random.unit() * 2 * Double.pi
            // One point past the full turn: the ends meet loosely, as a pen's do.
            return (0...(count + 1)).map { index in
                let angle = first + 2 * Double.pi * Double(index) / Double(count)
                return wobbled(CGPoint(x: rect.midX + radiusX * cos(angle), y: rect.midY + radiusY * sin(angle)),
                               amplitude: amplitude, random: &random)
            }
        }
    }

    /// The strokes as one path: smooth curves through the points.
    public static func path(from strokes: [[CGPoint]]) -> CGPath {
        let path = CGMutablePath()
        for stroke in strokes where stroke.count >= 2 {
            path.move(to: stroke[0])
            if stroke.count == 2 {
                path.addLine(to: stroke[1])
                continue
            }
            for index in 1..<(stroke.count - 1) {
                let next = stroke[index + 1]
                path.addQuadCurve(to: CGPoint(x: (stroke[index].x + next.x) / 2, y: (stroke[index].y + next.y) / 2),
                                  control: stroke[index])
            }
            path.addLine(to: stroke[stroke.count - 1])
        }
        return path
    }

    // MARK: Passes

    /// The distance between wobbles.
    private static func step(for amplitude: Double) -> Double {
        max(18, amplitude * 8)
    }

    private static func wobbled(_ point: CGPoint, amplitude: Double, random: inout RoughRandom) -> CGPoint {
        CGPoint(x: point.x + random.signed() * amplitude, y: point.y + random.signed() * amplitude)
    }

    static func line(from start: CGPoint, to end: CGPoint, amplitude: Double, random: inout RoughRandom) -> [[CGPoint]] {
        polyline([start, end], closed: false, amplitude: amplitude, random: &random)
    }

    static func polyline(_ points: [CGPoint], closed: Bool, amplitude: Double, random: inout RoughRandom) -> [[CGPoint]] {
        guard points.count >= 2 else { return [] }
        let legs = closed ? points.count : points.count - 1
        return (0..<passes).map { _ in
            var stroke: [CGPoint] = []
            for leg in 0..<legs {
                let from = points[leg]
                let to = points[(leg + 1) % points.count]
                let pieces = max(1, Int((hypot(to.x - from.x, to.y - from.y) / step(for: amplitude)).rounded()))
                for piece in 0..<pieces {
                    let t = Double(piece) / Double(pieces)
                    stroke.append(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                }
            }
            if closed {
                // Round again to just past the start, so the ends overlap instead of meeting exactly.
                stroke.append(stroke[0])
                stroke.append(stroke[1 % stroke.count])
            } else {
                stroke.append(points[points.count - 1])
                stroke[0] = overshoot(stroke[0], towards: stroke[1], amplitude: amplitude, random: &random)
                let last = stroke.count - 1
                stroke[last] = overshoot(stroke[last], towards: stroke[last - 1], amplitude: amplitude, random: &random)
            }
            return stroke.map { wobbled($0, amplitude: amplitude, random: &random) }
        }
    }

    /// `point` pushed up to one and a half amplitudes away from `neighbour`.
    private static func overshoot(_ point: CGPoint, towards neighbour: CGPoint, amplitude: Double,
                                  random: inout RoughRandom) -> CGPoint {
        let dx = point.x - neighbour.x
        let dy = point.y - neighbour.y
        let length = hypot(dx, dy)
        let extra = random.unit() * amplitude * 1.5
        guard length > 0 else { return point }
        return CGPoint(x: point.x + dx / length * extra, y: point.y + dy / length * extra)
    }
}
