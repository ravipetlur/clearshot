import CoreGraphics
import Foundation

/// Crop & Resize's aspect ratios.
public enum CropRatio: Hashable, Sendable {
    case freeform
    /// The picture's own proportions, after image operations.
    case original
    case fixed(width: Double, height: Double)
    /// The person's own W:H.
    case custom(width: Double, height: Double)

    /// The ratio menu, in order; Custom follows it.
    public static let presets: [CropRatio] = [
        .freeform, .original,
        .fixed(width: 1, height: 1), .fixed(width: 5, height: 4), .fixed(width: 7, height: 5), .fixed(width: 4, height: 3),
        .fixed(width: 3, height: 2), .fixed(width: 16, height: 10), .fixed(width: 16, height: 9),
        .fixed(width: 2.35, height: 1), .fixed(width: 1.85, height: 1),
        .fixed(width: 4, height: 5), .fixed(width: 3, height: 4), .fixed(width: 2, height: 3), .fixed(width: 9, height: 16),
    ]

    public var title: String {
        switch self {
        case .freeform: "Freeform"
        case .original: "Original"
        case .fixed(let width, let height):
            width.isFinite && height.isFinite ? "\(Self.number(width)):\(Self.number(height))" : "Custom"
        case .custom: "Custom"
        }
    }

    /// Width ÷ height, or nil when any shape goes: Freeform, a picture with no size (for Original), or a ratio whose sides
    /// aren't positive, finite numbers. A typed ratio further out than 1:100 to 100:1 is no ratio a crop could have, so it
    /// is Freeform too. `pictureSize` is the picture's size after image operations, for Original.
    public func aspect(pictureSize: CGSize) -> Double? {
        switch self {
        case .freeform:
            return nil
        case .original:
            return Self.quotient(pictureSize.width, pictureSize.height)
        case .fixed(let width, let height), .custom(let width, let height):
            guard let aspect = Self.quotient(width, height), aspect >= 1.0 / Self.widestRatio, aspect <= Self.widestRatio else {
                return nil
            }
            return aspect
        }
    }

    /// How far from square a typed ratio may go: 1:100 to 100:1.
    private static let widestRatio = 100.0

    /// `width` ÷ `height` when both are positive, finite numbers and so is the answer.
    private static func quotient(_ width: Double, _ height: Double) -> Double? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let quotient = width / height
        return quotient.isFinite && quotient > 0 ? quotient : nil
    }

    /// "16" for 16, "2.35" for 2.35.
    private static func number(_ value: Double) -> String {
        Int(exactly: value).map(String.init) ?? String(value)
    }
}

/// The crop rectangle's arithmetic, in output pixels: handle drags with or without a fixed ratio, snapping, limits, and
/// what the canvas shows while cropping.
public enum CropGeometry {
    /// The smallest a crop may be on a side, in output pixels.
    public static let minimumSide = 8.0

    /// The crop's handles: four corners, then four edges.
    public static let handles: [Handle] = Corner.allCases.map(Handle.corner) + RectEdge.allCases.map(Handle.edge)

    /// `rect` with `handle` dragged to `point`, keeping `aspect` (width ÷ height) when there is one, on whole output
    /// pixels and within the limits (`minimumSide` to `AnnotationDocument.maximumOutputSide` a side).
    ///
    /// The edge or corner opposite the handle stays where it is, at the limits too. A drag past it flips the crop over it,
    /// and a pull of no length keeps the crop on the handle's own side. With an aspect, a corner keeps it about the
    /// opposite corner, the larger pull winning, and an edge keeps it by growing the other side about the crop's middle.
    /// A drag that would pass a limit then scales both sides down (or up) together, so the ratio holds.
    ///
    /// A pointer that isn't a number leaves the crop as it was, and an aspect no crop can have (not finite, not positive,
    /// or so far from square that the limits can't both be met) is no aspect.
    public static func dragging(_ handle: Handle, of rect: CGRect, to point: CGPoint, aspect: Double?) -> CGRect {
        guard rect.isFiniteRect, point.x.isFinite, point.y.isFinite else { return clamped(rect) }
        let aspect = feasible(aspect)
        switch handle {
        case .corner(let corner):
            let towardsLeft = corner == .topLeft || corner == .bottomLeft
            let towardsTop = corner == .topLeft || corner == .topRight
            let anchor = CGPoint(x: (towardsLeft ? rect.maxX : rect.minX).rounded(), y: (towardsTop ? rect.maxY : rect.minY).rounded())
            let pull = CGVector(dx: point.x - anchor.x, dy: point.y - anchor.y)
            var width = abs(pull.dx), height = abs(pull.dy)
            if let aspect {
                width = limited(max(width, height * aspect), widthBounds(for: aspect))
                height = width / aspect
            } else {
                width = limited(width, sideBounds)
                height = limited(height, sideBounds)
            }
            let x = side(from: anchor.x, pull: pull.dx, towardsLow: towardsLeft, length: width)
            let y = side(from: anchor.y, pull: pull.dy, towardsLow: towardsTop, length: height)
            return CGRect(x: x.low, y: y.low, width: x.high - x.low, height: y.high - y.low)
        case .edge(let edge):
            let horizontal = edge == .left || edge == .right
            let towardsLow = edge == .left || edge == .top
            let along = horizontal ? (low: rect.minX, high: rect.maxX) : (low: rect.minY, high: rect.maxY)
            let across = horizontal ? (low: rect.minY, high: rect.maxY) : (low: rect.minX, high: rect.maxX)
            let anchor = (towardsLow ? along.high : along.low).rounded()
            let pull = (horizontal ? point.x : point.y) - anchor
            let dragged: (low: Double, high: Double)
            let other: (low: Double, high: Double)
            if let aspect {
                let length = limited(abs(pull), horizontal ? widthBounds(for: aspect) : heightBounds(for: aspect))
                let otherLength = (horizontal ? length / aspect : length * aspect).rounded()
                let start = (across.low / 2 + across.high / 2 - otherLength / 2).rounded()
                dragged = side(from: anchor, pull: pull, towardsLow: towardsLow, length: length)
                other = (start, start + otherLength)
            } else {
                dragged = side(from: anchor, pull: pull, towardsLow: towardsLow, length: limited(abs(pull), sideBounds))
                other = limitedSide(across.low, across.high)
            }
            return horizontal
                ? CGRect(x: dragged.low, y: other.low, width: dragged.high - dragged.low, height: other.high - other.low)
                : CGRect(x: other.low, y: dragged.low, width: other.high - other.low, height: dragged.high - dragged.low)
        case .start, .end, .control:
            return clamped(rect)
        }
    }

    /// `rect` on whole output pixels, at least `minimumSide` and at most `AnnotationDocument.maximumOutputSide` on a side.
    /// A side that is too short or too long is grown or shrunk from its origin edge (the left or the top), so a moved crop
    /// stays where it is. A rect that isn't finite is replaced by the smallest crop, at the origin.
    public static func clamped(_ rect: CGRect) -> CGRect {
        let rect = rect.isFiniteRect ? rect : CGRect(x: 0, y: 0, width: minimumSide, height: minimumSide)
        let x = limitedSide(rect.minX, rect.maxX)
        let y = limitedSide(rect.minY, rect.maxY)
        return CGRect(x: x.low, y: y.low, width: x.high - x.low, height: y.high - y.low)
    }

    // MARK: Limits

    private static let sideBounds = (lower: minimumSide, upper: AnnotationDocument.maximumOutputSide)

    private static func limited(_ value: Double, _ bounds: (lower: Double, upper: Double)) -> Double {
        min(max(value, bounds.lower), bounds.upper)
    }

    /// The widths a crop of `aspect` can have with both sides within the limits.
    private static func widthBounds(for aspect: Double) -> (lower: Double, upper: Double) {
        (max(minimumSide, minimumSide * aspect), min(AnnotationDocument.maximumOutputSide, AnnotationDocument.maximumOutputSide * aspect))
    }

    /// The heights a crop of `aspect` can have with both sides within the limits.
    private static func heightBounds(for aspect: Double) -> (lower: Double, upper: Double) {
        (max(minimumSide, minimumSide / aspect), min(AnnotationDocument.maximumOutputSide, AnnotationDocument.maximumOutputSide / aspect))
    }

    /// `aspect` if a crop of it can exist within the limits, or nil.
    private static func feasible(_ aspect: Double?) -> Double? {
        guard let aspect, aspect.isFinite, aspect > 0 else { return nil }
        let widths = widthBounds(for: aspect), heights = heightBounds(for: aspect)
        return widths.lower <= widths.upper && heights.lower <= heights.upper ? aspect : nil
    }

    /// A side of `length` pixels (whole) from `anchor`, towards the low end if `pull` goes that way (or has no direction
    /// and `towardsLow` says so).
    private static func side(from anchor: Double, pull: Double, towardsLow: Bool, length: Double) -> (low: Double, high: Double) {
        let length = length.rounded()
        return pull < 0 || (pull == 0 && towardsLow) ? (anchor - length, anchor) : (anchor, anchor + length)
    }

    /// One side of a rect on whole pixels, grown or shrunk from its low end into the limits.
    private static func limitedSide(_ low: Double, _ high: Double) -> (low: Double, high: Double) {
        let start = low.rounded()
        return (start, start + limited(high.rounded() - start, sideBounds))
    }

    // MARK: Snapping

    /// The edges a crop snaps to, in output pixels.
    public struct SnapTargets: Equatable, Sendable {
        public var x: [Double]
        public var y: [Double]

        public init(x: [Double], y: [Double]) {
            self.x = x
            self.y = y
        }

        /// No snapping (⌘ held).
        public static let empty = SnapTargets(x: [], y: [])
    }

    /// The picture's edges and every object's painted bounds, in output pixels.
    public static func snapTargets(for document: AnnotationDocument) -> SnapTargets {
        let picture = document.pictureBounds
        var x: [Double] = [picture.minX, picture.maxX]
        var y: [Double] = [picture.minY, picture.maxY]
        for object in document.objects {
            let bounds = document.outputBounds(of: object)
            guard bounds.isFiniteRect else { continue }
            x += [bounds.minX, bounds.maxX]
            y += [bounds.minY, bounds.maxY]
        }
        return SnapTargets(x: x, y: y)
    }

    /// `value` moved onto the nearest target within `threshold`, or left alone.
    public static func snapped(_ value: Double, to targets: [Double], threshold: Double) -> Double {
        guard let nearest = targets.min(by: { abs($0 - value) < abs($1 - value) }), abs(nearest - value) <= threshold else {
            return value
        }
        return nearest
    }

    /// `point` with each coordinate snapped on its own axis.
    public static func snapped(_ point: CGPoint, to targets: SnapTargets, threshold: Double) -> CGPoint {
        CGPoint(x: snapped(point.x, to: targets.x, threshold: threshold), y: snapped(point.y, to: targets.y, threshold: threshold))
    }

    /// A moved crop, shifted on each axis so whichever of its two edges is nearer a target within `threshold` lies on it.
    /// An edge already on a target is nearest of all (a shift of nothing), so it stays while the other edge is near
    /// another target; an edge with no target in range has no say.
    public static func snappedMove(_ rect: CGRect, to targets: SnapTargets, threshold: Double) -> CGRect {
        func shift(_ low: Double, _ high: Double, _ candidates: [Double]) -> Double {
            let shifts = [low, high].compactMap { edge -> Double? in
                guard let target = candidates.min(by: { abs($0 - edge) < abs($1 - edge) }), abs(target - edge) <= threshold else {
                    return nil
                }
                return target - edge
            }
            return shifts.min(by: { abs($0) < abs($1) }) ?? 0
        }
        return rect.offsetBy(dx: shift(rect.minX, rect.maxX, targets.x), dy: shift(rect.minY, rect.maxY, targets.y))
    }

    // MARK: Ratio and viewport

    /// The largest rect of `aspect` inside `rect`, sharing its centre (choosing a ratio), then limited.
    public static func conformed(_ rect: CGRect, aspect: Double) -> CGRect {
        guard rect.isFiniteRect, aspect.isFinite, aspect > 0, rect.width > 0, rect.height > 0 else { return clamped(rect) }
        var size = CGSize(width: rect.width, height: rect.width / aspect)
        if size.height > rect.height { size = CGSize(width: rect.height * aspect, height: rect.height) }
        return clamped(CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    /// What the canvas shows while cropping: the picture, the canvas, every object and the crop, with a quarter of the
    /// larger side spare all round, so an edge can be dragged out past the picture. Whole pixels, and within
    /// `AnnotationDocument.maximumSide` on a side (shrunk about its middle if need be). A crop that isn't a rect is
    /// left out.
    public static func viewport(for document: AnnotationDocument, crop: CGRect) -> CGRect {
        var area = document.pictureBounds.union(document.canvasBounds)
        if crop.isFiniteRect { area = area.union(crop) }
        for object in document.objects {
            let bounds = document.outputBounds(of: object)
            guard bounds.isFiniteRect else { continue }
            area = area.union(bounds)
        }
        let spare = (max(area.width, area.height) * 0.25).rounded()
        var viewport = area.insetBy(dx: -spare, dy: -spare).integral
        let limit = AnnotationDocument.maximumSide
        if viewport.width > limit {
            viewport = CGRect(x: (viewport.midX - limit / 2).rounded(.down), y: viewport.minY, width: limit, height: viewport.height)
        }
        if viewport.height > limit {
            viewport = CGRect(x: viewport.minX, y: (viewport.midY - limit / 2).rounded(.down), width: viewport.width, height: limit)
        }
        return viewport
    }
}
