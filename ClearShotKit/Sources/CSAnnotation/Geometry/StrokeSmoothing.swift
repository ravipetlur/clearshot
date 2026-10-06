import CoreGraphics
import Foundation

/// Freehand strokes: thinning the mouse points, and the optional smooth drawing.
public enum StrokeSmoothing {
    /// Drops points closer than `minimumDistance` to the last kept one; the final point is always kept.
    public static func simplified(_ points: [CGPoint], minimumDistance: Double) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var result = [last]
        for point in points.dropFirst() where hypot(point.x - last.x, point.y - last.y) >= minimumDistance {
            result.append(point)
            last = point
        }
        if let final = points.last, final != result.last {
            result.append(final)
        }
        return result
    }

    /// Straight segments through the points, or Catmull-Rom curves when `smoothed`. A single point is a dot (round
    /// line caps draw it).
    public static func path(through points: [CGPoint], smoothed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else {
            path.addLine(to: first)
            return path
        }
        guard smoothed, points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }
}
