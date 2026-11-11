import CoreGraphics

/// Fit to content: moves the edges of a pixel area inward over the flat margin around what is in it, so a rough drag
/// around a button becomes the button's own bounds.
///
/// An edge's row (or column) is margin while all of its pixels, within the area, are within `tolerance` of that edge's
/// first pixel: the same flat colour all along it, and the same one as the pixels it started on. So the margin stops at a
/// border line of another colour as well as at content. Edges move one at a time (top, bottom, left, right), the left and
/// right ones along the rows left by the first two, so a corner's margin is measured once.
///
/// An area that is flat all through has no content to fit to, and comes back unchanged; so does one that is already tight.
/// Work is the margin's size at most: nothing past the area's own pixels is read.
public enum PixelFit {
    /// `area` (whole pixels of `sampler`) with each of `edges` moved in over its margin. Returns `area` itself, clamped to
    /// the picture, when there is nothing to fit to.
    public static func fitted(_ area: CGRect, in sampler: PixelSampler, tolerance: Int, edges: Set<RectEdge> = Set(RectEdge.allCases)) -> CGRect {
        guard let clamped = PixelSelection.clamped(area, in: sampler.size) else { return area }
        var left = Int(clamped.minX), right = Int(clamped.maxX), top = Int(clamped.minY), bottom = Int(clamped.maxY)
        func reference(_ x: Int, _ y: Int) -> PixelSampler.Pixel? { sampler.pixel(x: x, y: y) }

        if edges.contains(.top), let first = reference(left, top) {
            while top < bottom, sampler.isFlat(row: top, columns: left..<right, matching: first, tolerance: tolerance) { top += 1 }
        }
        if edges.contains(.bottom), top < bottom, let first = reference(left, bottom - 1) {
            while top < bottom, sampler.isFlat(row: bottom - 1, columns: left..<right, matching: first, tolerance: tolerance) { bottom -= 1 }
        }
        if edges.contains(.left), top < bottom, let first = reference(left, top) {
            while left < right, sampler.isFlat(column: left, rows: top..<bottom, matching: first, tolerance: tolerance) { left += 1 }
        }
        if edges.contains(.right), left < right, top < bottom, let first = reference(right - 1, top) {
            while left < right, sampler.isFlat(column: right - 1, rows: top..<bottom, matching: first, tolerance: tolerance) { right -= 1 }
        }
        // Nothing left means the area was flat all through (or flat along the axis being fitted): no content to fit to.
        guard left < right, top < bottom else { return clamped }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
