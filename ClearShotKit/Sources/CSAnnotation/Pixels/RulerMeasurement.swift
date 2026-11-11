import CoreGraphics
import Foundation

/// The axis a ruler measures along, as shown on screen.
public enum RulerAxis: Sendable {
    case horizontal, vertical
}

/// A measurement of the picture through a point: from the edge on one side to the edge on the other, along one axis.
public struct RulerMeasurement: Equatable, Sendable {
    /// Where the measured run begins and ends (left to right, or top to bottom as shown), in base pixels, on the line through
    /// the middle of the pixel measured from: the ends of a ruler.
    public let start: CGPoint
    public let end: CGPoint
    /// The length in the picture's pixels as shown.
    public let pixels: Int
}

extension PixelSampler {
    /// The run through the pixel under `point` along `axis`, as the pixel positions where it begins and ends (`lower` on the
    /// left or top side, `upper` on the right or bottom side; the run is `upper - lower` pixels long). Nil off the picture.
    ///
    /// An **edge** is where the color changes by more than `tolerance` (`edge(from:direction:tolerance:)`). The **inner** size
    /// runs from the nearest edge on one side to the nearest on the other: the extent of the color under the cursor.
    /// The **outer** size steps over each first edge: the run of color just beyond it is crossed too (its own tolerance, from
    /// its first pixel), and the size ends where that run does. A button with a one-pixel border measures, outer, as the
    /// button and its border. A side whose first run already reaches the picture's border has nothing beyond it and stays
    /// at the border.
    public func rulerSpan(through point: CGPoint, axis: RulerAxis, outer: Bool, tolerance: Int) -> (lower: Int, upper: Int)? {
        guard let (x, y) = Self.index(of: point), contains(x: x, y: y) else { return nil }
        let (before, after): (PixelDirection, PixelDirection) = axis == .horizontal ? (.left, .right) : (.up, .down)
        let position = axis == .horizontal ? x : y
        let limit = axis == .horizontal ? width : height

        func pixel(_ along: Int) -> CGPoint {
            axis == .horizontal ? CGPoint(x: Double(along) + 0.5, y: Double(y) + 0.5) : CGPoint(x: Double(x) + 0.5, y: Double(along) + 0.5)
        }
        guard let near = edge(from: pixel(position), direction: before, tolerance: tolerance),
              let far = edge(from: pixel(position), direction: after, tolerance: tolerance) else { return nil }
        var lower = position - near + 1
        var upper = position + far
        if outer {
            // The first pixel past each edge begins the run to cross.
            if position - near >= 0, let beyond = edge(from: pixel(position - near), direction: before, tolerance: tolerance) {
                lower = position - near - beyond + 1
            }
            if position + far < limit, let beyond = edge(from: pixel(position + far), direction: after, tolerance: tolerance) {
                upper = position + far + beyond
            }
        }
        return (lower, upper)
    }
}

extension PicturePixels {
    /// The measurement through `point` (base pixels) along `axis` as shown on screen; `outer` steps over the first edges (see
    /// `PixelSampler.rulerSpan`). Nil off the picture.
    public func measure(through point: CGPoint, axis: RulerAxis, outer: Bool, tolerance: Int) -> RulerMeasurement? {
        let center = pixelPoint(fromBase: point)
        guard let span = sampler.rulerSpan(through: center, axis: axis, outer: outer, tolerance: tolerance),
              let (x, y) = PixelSampler.index(of: center) else { return nil }
        let first: CGPoint, last: CGPoint
        switch axis {
        case .horizontal:
            first = CGPoint(x: Double(span.lower), y: Double(y) + 0.5)
            last = CGPoint(x: Double(span.upper), y: Double(y) + 0.5)
        case .vertical:
            first = CGPoint(x: Double(x) + 0.5, y: Double(span.lower))
            last = CGPoint(x: Double(x) + 0.5, y: Double(span.upper))
        }
        return RulerMeasurement(start: basePoint(fromPixel: first), end: basePoint(fromPixel: last), pixels: span.upper - span.lower)
    }
}
