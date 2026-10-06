import CoreGraphics

extension CGRect {
    /// Whether this is a real rect: not null or infinite, and every edge a finite number. Painted bounds that fail it (an
    /// object that paints nothing, or whose numbers aren't numbers) are left out of snapping, the crop viewport and
    /// auto-expand, and a crop rect that fails it is replaced before it is used.
    var isFiniteRect: Bool {
        !isNull && !isInfinite && [minX, minY, maxX, maxY].allSatisfy(\.isFinite)
    }
}
