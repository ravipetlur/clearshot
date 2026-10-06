import CoreGraphics

/// Vertical (`xs`) and horizontal (`ys`) lines a selection snaps to. AppKit global points.
public struct SnapLines: Sendable, Equatable {
    public var xs: [CGFloat]
    public var ys: [CGFloat]

    public init(xs: [CGFloat] = [], ys: [CGFloat] = []) {
        self.xs = xs
        self.ys = ys
    }

    /// The display edges plus the edges of windows that overlap the display.
    public static func from(windowFrames: [CGRect], bounds: CGRect) -> SnapLines {
        var xs: Set<CGFloat> = [bounds.minX, bounds.maxX]
        var ys: Set<CGFloat> = [bounds.minY, bounds.maxY]
        for frame in windowFrames where frame.intersects(bounds) {
            xs.formUnion([frame.minX, frame.maxX].filter { $0 >= bounds.minX && $0 <= bounds.maxX })
            ys.formUnion([frame.minY, frame.maxY].filter { $0 >= bounds.minY && $0 <= bounds.maxY })
        }
        return SnapLines(xs: Array(xs), ys: Array(ys))
    }

    public func snapped(_ point: CGPoint, threshold: CGFloat) -> CGPoint {
        CGPoint(x: Self.nearest(point.x, in: xs, threshold: threshold), y: Self.nearest(point.y, in: ys, threshold: threshold))
    }

    private static func nearest(_ value: CGFloat, in lines: [CGFloat], threshold: CGFloat) -> CGFloat {
        guard let closest = lines.min(by: { abs($0 - value) < abs($1 - value) }), abs(closest - value) <= threshold else { return value }
        return closest
    }
}
