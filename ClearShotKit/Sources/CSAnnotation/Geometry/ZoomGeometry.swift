import CoreGraphics

/// Where the canvas's zoom goes for Z-click, Z-drag and Zoom to Selection: a magnification and the point of the canvas
/// (in its own view points, at 100%) that ends up in the middle of the window.
public struct ZoomTarget: Equatable, Sendable {
    public var magnification: Double
    public var center: CGPoint

    public init(magnification: Double, center: CGPoint) {
        self.magnification = magnification
        self.center = center
    }
}

public enum ZoomGeometry {
    /// The zoom that shows `rect` as large as fits in `available` (the window's visible size in points, before zoom),
    /// leaving `margin` points free on each side, and centred on it. The magnification stays within `limits`; a rect too
    /// small for the limit is centred at the most. Nil when `rect` has no area or a number isn't finite.
    public static func fitting(_ rect: CGRect, in available: CGSize, margin: Double = 16,
                               limits: ClosedRange<Double>) -> ZoomTarget? {
        let rect = rect.standardized
        let usableWidth = available.width - 2 * margin, usableHeight = available.height - 2 * margin
        guard [rect.minX, rect.minY, rect.width, rect.height, usableWidth, usableHeight].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0, usableWidth > 0, usableHeight > 0 else { return nil }
        let fit = min(usableWidth / rect.width, usableHeight / rect.height)
        return ZoomTarget(magnification: min(max(fit, limits.lowerBound), limits.upperBound), center: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// The zoom a click makes: `factor` times the current magnification (within `limits`), centred on `point`.
    public static func zooming(at point: CGPoint, from magnification: Double, by factor: Double = 2,
                               limits: ClosedRange<Double>) -> ZoomTarget? {
        guard point.x.isFinite, point.y.isFinite, magnification.isFinite, magnification > 0, factor.isFinite, factor > 0 else { return nil }
        return ZoomTarget(magnification: min(max(magnification * factor, limits.lowerBound), limits.upperBound), center: point)
    }

    /// Whether a press that moved from `start` to `end` (view points) was a click rather than a drag: a rect under
    /// `slop` points on either side is a click.
    public static func isClick(from start: CGPoint, to end: CGPoint, slop: Double = 4) -> Bool {
        abs(end.x - start.x) < slop && abs(end.y - start.y) < slop
    }
}
