import CoreGraphics
import Foundation

/// Making, placing and resizing magnifiers, in base pixels. The source and the callout always share one aspect ratio, and
/// the zoom between them stays within `MagnifierObject.zoomRange`.
///
/// Handles: the callout's four corners resize the callout (the zoom changes, the source stays); `.start`, in the middle
/// of the source, moves the source; `.end`, at the source's bottom-right corner, resizes the source from its top-left
/// (the zoom changes, the callout stays). Moving the object (`ObjectGeometry.translated`) moves the callout: the source
/// stays on the pixels it magnifies.
public enum MagnifierGeometry {
    /// The smallest a source gets on a side.
    public static let minimumSourceSide = 2.0

    /// `zoom` within `MagnifierObject.zoomRange`; the default zoom for a number that isn't finite.
    public static func clampedZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return MagnifierObject.defaultZoom }
        return min(max(zoom, MagnifierObject.zoomRange.lowerBound), MagnifierObject.zoomRange.upperBound)
    }

    /// A new magnifier of `source` at the default zoom, its callout beside the source (`placedCallout`).
    public static func make(source: CGRect, within area: CGRect, gap: Double, shape: MagnifierShape,
                            border: Bool) -> MagnifierObject {
        var source = source.standardized
        source.size.width = max(source.width, minimumSourceSide)
        source.size.height = max(source.height, minimumSourceSide)
        let zoom = MagnifierObject.defaultZoom
        let size = CGSize(width: source.width * zoom, height: source.height * zoom)
        return MagnifierObject(source: source, callout: placedCallout(size: size, beside: source, within: area, gap: gap),
                               shape: shape, border: border)
    }

    /// Where a callout of `size` goes beside `source`, `gap` away from it: to the right, the left, below or above, the
    /// first that lies wholly inside `area` (the canvas). When none does, the one with the most of it inside, moved into
    /// `area` as far as it fits.
    public static func placedCallout(size: CGSize, beside source: CGRect, within area: CGRect, gap: Double) -> CGRect {
        let candidates = [
            CGRect(x: source.maxX + gap, y: source.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: source.minX - gap - size.width, y: source.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: source.midX - size.width / 2, y: source.maxY + gap, width: size.width, height: size.height),
            CGRect(x: source.midX - size.width / 2, y: source.minY - gap - size.height, width: size.width, height: size.height),
        ]
        guard area.width > 0, area.height > 0, area.isFiniteRect else { return candidates[0] }
        if let inside = candidates.first(where: { area.contains($0) }) { return inside }
        func covered(_ rect: CGRect) -> Double {
            let overlap = rect.intersection(area)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        let best = candidates.max { covered($0) < covered($1) } ?? candidates[0]
        // Moved into the area on each axis it fits on; one that is larger than the area keeps its place on that axis.
        var moved = best
        if best.width <= area.width { moved.origin.x = min(max(best.minX, area.minX), area.maxX - best.width) }
        if best.height <= area.height { moved.origin.y = min(max(best.minY, area.minY), area.maxY - best.height) }
        return moved
    }

    /// The magnifier at `zoom` (clamped), its callout resized about its middle and the source unchanged.
    public static func withZoom(_ magnifier: MagnifierObject, _ zoom: Double) -> MagnifierObject {
        let zoom = clampedZoom(zoom)
        var copy = magnifier
        let source = magnifier.source.standardized, callout = magnifier.callout.standardized
        let size = CGSize(width: source.width * zoom, height: source.height * zoom)
        copy.callout = CGRect(x: callout.midX - size.width / 2, y: callout.midY - size.height / 2, width: size.width,
                              height: size.height)
        return copy
    }

    /// The magnifier made whole: both rects standardized, the source at least `minimumSourceSide` on a side, and the callout
    /// re-made from the source at the (clamped) zoom about its middle, so the two share an aspect ratio. A document from a
    /// file is drawn from this, so a crafted one can't stretch or divide by nothing.
    public static func normalized(_ magnifier: MagnifierObject) -> MagnifierObject {
        var copy = magnifier
        var source = magnifier.source.standardized
        source.size.width = max(source.width, minimumSourceSide)
        source.size.height = max(source.height, minimumSourceSide)
        copy.source = source
        copy.callout = magnifier.callout.standardized
        return withZoom(copy, copy.zoom)
    }

    // MARK: Handles

    /// The handles of a selected magnifier: the callout's corners, then the source's resize and move handles.
    public static let handles: [Handle] = Corner.allCases.map(Handle.corner) + [.end, .start]

    /// Where `handle` sits.
    public static func handlePoint(_ handle: Handle, of magnifier: MagnifierObject) -> CGPoint {
        let source = magnifier.source.standardized
        switch handle {
        case .start: return CGPoint(x: source.midX, y: source.midY)
        case .end: return CGPoint(x: source.maxX, y: source.maxY)
        default: return ObjectGeometry.point(of: handle, in: magnifier.callout.standardized)
        }
    }

    /// The magnifier with `handle` dragged to `point`:
    /// - a callout corner resizes the callout about the opposite corner, keeping its aspect ratio, the zoom clamped;
    /// - `.start` moves the source so its middle is at `point`;
    /// - `.end` resizes the source from its top-left corner, keeping its aspect ratio, the zoom clamped.
    public static func dragging(_ handle: Handle, of magnifier: MagnifierObject, to point: CGPoint) -> MagnifierObject {
        var copy = magnifier
        let source = magnifier.source.standardized, callout = magnifier.callout.standardized
        guard source.width > 0, source.height > 0 else { return magnifier }
        let aspect = source.width / source.height
        switch handle {
        case .corner(let corner):
            let anchor: CGPoint = switch corner {
            case .topLeft: CGPoint(x: callout.maxX, y: callout.maxY)
            case .topRight: CGPoint(x: callout.minX, y: callout.maxY)
            case .bottomLeft: CGPoint(x: callout.maxX, y: callout.minY)
            case .bottomRight: CGPoint(x: callout.minX, y: callout.minY)
            }
            // The corner keeps to its own side of the anchor: the callout never flips.
            let xSign: Double = corner == .topLeft || corner == .bottomLeft ? -1 : 1
            let ySign: Double = corner == .topLeft || corner == .topRight ? -1 : 1
            let pull = max(xSign * (point.x - anchor.x), ySign * (point.y - anchor.y) * aspect)
            let width = min(max(pull, source.width * MagnifierObject.zoomRange.lowerBound),
                            source.width * MagnifierObject.zoomRange.upperBound)
            let height = width / aspect
            copy.callout = CGRect(x: xSign < 0 ? anchor.x - width : anchor.x, y: ySign < 0 ? anchor.y - height : anchor.y,
                                  width: width, height: height)
        case .start:
            copy.source = source.offsetBy(dx: point.x - source.midX, dy: point.y - source.midY)
        case .end:
            let pull = max(point.x - source.minX, (point.y - source.minY) * aspect)
            let lower = max(callout.width / MagnifierObject.zoomRange.upperBound, minimumSourceSide * max(aspect, 1))
            let upper = max(callout.width / MagnifierObject.zoomRange.lowerBound, lower)
            let width = min(max(pull, lower), upper)
            copy.source = CGRect(x: source.minX, y: source.minY, width: width, height: width / aspect)
        case .edge, .control:
            break
        }
        return copy
    }

    // MARK: Drawing

    /// The outline of `shape` over `rect`: an ellipse for the circle, a square with rounded corners for the other.
    public static func path(of shape: MagnifierShape, in rect: CGRect) -> CGPath {
        let rect = rect.standardized
        switch shape {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .roundedSquare:
            let radius = max(0, min(rect.width, rect.height) * 0.15)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }

    /// The connector: from the source's outline to the callout's, on the line between their middles. Nil when the two
    /// overlap along that line, so there is nothing between them to draw.
    public static func connector(of magnifier: MagnifierObject) -> (start: CGPoint, end: CGPoint)? {
        let source = magnifier.source.standardized, callout = magnifier.callout.standardized
        let dx = callout.midX - source.midX, dy = callout.midY - source.midY
        let length = hypot(dx, dy)
        guard length > 0, length.isFinite else { return nil }
        let unit = CGVector(dx: dx / length, dy: dy / length)
        let out = reach(of: magnifier.shape, in: source, along: unit)
        let into = reach(of: magnifier.shape, in: callout, along: unit)
        guard out + into < length else { return nil }
        return (CGPoint(x: source.midX + unit.dx * out, y: source.midY + unit.dy * out),
                CGPoint(x: callout.midX - unit.dx * into, y: callout.midY - unit.dy * into))
    }

    /// How far the outline of `shape` over `rect` lies from its middle along `unit` (a rounded square counts as its square).
    private static func reach(of shape: MagnifierShape, in rect: CGRect, along unit: CGVector) -> Double {
        let a = rect.width / 2, b = rect.height / 2
        guard a > 0, b > 0 else { return 0 }
        switch shape {
        case .circle:
            return 1 / hypot(unit.dx / a, unit.dy / b)
        case .roundedSquare:
            let x = unit.dx == 0 ? Double.infinity : a / abs(unit.dx)
            let y = unit.dy == 0 ? Double.infinity : b / abs(unit.dy)
            return min(x, y)
        }
    }
}
