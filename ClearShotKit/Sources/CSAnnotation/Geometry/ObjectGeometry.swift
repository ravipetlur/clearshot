import CoreGraphics
import Foundation

public enum Corner: CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// A side of a rect. (Not `Edge`: that collides with `SwiftUI.Edge` in any file importing both.)
public enum RectEdge: CaseIterable, Sendable {
    case top, bottom, left, right
}

/// A selection handle.
public enum Handle: Hashable, Sendable {
    case corner(Corner)
    case edge(RectEdge)
    case start, end, control
}

/// Bounds, hit testing, moving and handle dragging for objects, in base pixels.
public enum ObjectGeometry {
    /// The rect a rect-based object occupies (text: its laid-out box; counter: its circle's box), or nil for lines,
    /// arrows and freehand marks.
    public static func rect(of kind: ObjectKind) -> CGRect? {
        switch kind {
        case .rectangle(let rect), .filledRectangle(let rect), .ellipse(let rect): rect
        case .redact(let redact): redact.rect
        case .spotlight(let spotlight): spotlight.rect
        case .image(let image): image.rect
        case .text(let text): TextLayout.frame(of: text)
        case .counter(let counter):
            CGRect(x: counter.center.x - counter.diameter / 2, y: counter.center.y - counter.diameter / 2,
                   width: counter.diameter, height: counter.diameter)
        case .line, .arrow, .stroke, .highlight: nil
        }
    }

    /// Everything the object paints: lines, arrows (heads included) and freehand marks are grown by their line
    /// width; rect-based shapes report their rect.
    public static func bounds(of object: AnnotationObject) -> CGRect {
        let width = object.style.lineWidth
        switch object.kind {
        case .line(let start, let end):
            return box(around: [start, end]).insetBy(dx: -width / 2, dy: -width / 2)
        case .arrow(let arrow):
            let head = ArrowGeometry.headLength(for: width)
            // A fancy arrow's body flares to 60% of the head length either side of its axis.
            let margin = arrow.style == .fancy ? max(width / 2, head * 0.6) : max(width, head) / 2
            return box(around: ArrowGeometry.spine(of: arrow)).insetBy(dx: -margin, dy: -margin)
        case .stroke(let stroke):
            return box(around: stroke.points).insetBy(dx: -width / 2, dy: -width / 2)
        case .highlight(let highlight):
            guard let first = highlight.rects.first else {
                return box(around: highlight.points).insetBy(dx: -highlight.width / 2, dy: -highlight.width / 2)
            }
            return highlight.rects.dropFirst().reduce(first) { $0.union($1) }
        default:
            return rect(of: object.kind) ?? .null
        }
    }

    /// The lit shape of a spotlight, as the renderer cuts it out of the dimming.
    static func shapePath(of spotlight: SpotlightObject) -> CGPath {
        let rect = spotlight.rect.standardized
        switch spotlight.shape {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .roundedRectangle:
            let radius = max(0, min(rect.width, rect.height) * 0.15)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        }
    }

    /// Whether `point` hits the object, within `tolerance` base pixels. Outline shapes are hit on their outline only,
    /// so objects under them stay reachable. So is a spotlight: its lit inside looks like the plain picture, so only its
    /// edge, where the dimming starts, takes a click. Redactions, which look filled, are hit anywhere inside.
    public static func hitTest(_ object: AnnotationObject, at point: CGPoint, tolerance: Double) -> Bool {
        let width = object.style.lineWidth
        switch object.kind {
        case .spotlight(let spotlight):
            guard tolerance > 0 else { return false }
            return shapePath(of: spotlight).copy(strokingWithWidth: 2 * tolerance, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
                .contains(point)
        case .rectangle(let rect):
            let inner = rect.insetBy(dx: width + tolerance, dy: width + tolerance)
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) && !(inner.width > 0 && inner.height > 0 && inner.contains(point))
        case .ellipse(let rect):
            let inner = rect.insetBy(dx: width + tolerance, dy: width + tolerance)
            let insideOuter = ellipseContains(rect.insetBy(dx: -tolerance, dy: -tolerance), point)
            let insideInner = inner.width > 0 && inner.height > 0 && ellipseContains(inner, point)
            return insideOuter && !insideInner
        case .line(let start, let end):
            return distance(from: point, toPolyline: [start, end]) <= width / 2 + tolerance
        case .arrow(let arrow):
            let reach = max(width, ArrowGeometry.headLength(for: width) * 0.5) / 2
            return distance(from: point, toPolyline: ArrowGeometry.spine(of: arrow)) <= reach + tolerance
        case .stroke(let stroke):
            return distance(from: point, toPolyline: stroke.points) <= width / 2 + tolerance
        case .highlight(let highlight):
            if !highlight.rects.isEmpty {
                return highlight.rects.contains { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            }
            return distance(from: point, toPolyline: highlight.points) <= highlight.width / 2 + tolerance
        case .counter(let counter):
            return hypot(point.x - counter.center.x, point.y - counter.center.y) <= counter.diameter / 2 + tolerance
        case .filledRectangle, .redact, .image, .text:
            return (rect(of: object.kind) ?? .null).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    /// The object moved by `delta`.
    public static func translated(_ object: AnnotationObject, by delta: CGVector) -> AnnotationObject {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + delta.dx, y: point.y + delta.dy) }
        func move(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: delta.dx, dy: delta.dy) }
        var copy = object
        switch object.kind {
        case .rectangle(let rect): copy.kind = .rectangle(move(rect))
        case .filledRectangle(let rect): copy.kind = .filledRectangle(move(rect))
        case .ellipse(let rect): copy.kind = .ellipse(move(rect))
        case .line(let start, let end): copy.kind = .line(start: move(start), end: move(end))
        case .arrow(var arrow):
            arrow.start = move(arrow.start)
            arrow.end = move(arrow.end)
            arrow.control = arrow.control.map(move)
            copy.kind = .arrow(arrow)
        case .text(var text):
            text.origin = move(text.origin)
            copy.kind = .text(text)
        case .redact(var redact):
            redact.rect = move(redact.rect)
            copy.kind = .redact(redact)
        case .spotlight(var spotlight):
            spotlight.rect = move(spotlight.rect)
            copy.kind = .spotlight(spotlight)
        case .counter(var counter):
            counter.center = move(counter.center)
            copy.kind = .counter(counter)
        case .stroke(var stroke):
            stroke.points = stroke.points.map(move)
            copy.kind = .stroke(stroke)
        case .highlight(var highlight):
            highlight.points = highlight.points.map(move)
            highlight.rects = highlight.rects.map(move)
            copy.kind = .highlight(highlight)
        case .image(var image):
            image.rect = move(image.rect)
            copy.kind = .image(image)
        }
        return copy
    }

    /// The handles shown on a single selected object.
    public static func handles(of object: AnnotationObject) -> [Handle] {
        switch object.kind {
        case .rectangle, .filledRectangle, .ellipse, .redact, .spotlight, .image:
            Corner.allCases.map(Handle.corner) + RectEdge.allCases.map(Handle.edge)
        case .stroke, .highlight: freehandHandles(of: object)
        case .text: [.edge(.left), .edge(.right)]
        case .line: [.start, .end]
        case .arrow(let arrow): arrow.style == .curved ? [.start, .end, .control] : [.start, .end]
        case .counter: []
        }
    }

    /// The most a freehand mark's points may spread, in base pixels, on an axis it can't be stretched along: a flat line
    /// (or a dot) has nothing there to scale.
    static let minimumFreehandExtent = 1.0

    /// The handles of a pen stroke or highlight: corners and edges on its painted bounds, less those that would stretch it
    /// along an axis its points don't spread on. A flat line can only be lengthened (left and right); an upright one only
    /// along its height; a single dot, or a mark with no points at all, has none.
    private static func freehandHandles(of object: AnnotationObject) -> [Handle] {
        let stretch = freehandStretch(of: object)
        var handles: [Handle] = []
        if stretch.horizontal, stretch.vertical { handles += Corner.allCases.map(Handle.corner) }
        if stretch.vertical { handles += [.edge(.top), .edge(.bottom)] }
        if stretch.horizontal { handles += [.edge(.left), .edge(.right)] }
        return handles
    }

    /// The axes a freehand mark can be stretched along: those its points (its snapped rects, for a smart highlight) spread
    /// at least `minimumFreehandExtent` on. Neither for a mark with no points.
    private static func freehandStretch(of object: AnnotationObject) -> (horizontal: Bool, vertical: Bool) {
        let extent: CGRect
        switch object.kind {
        case .stroke(let stroke): extent = box(around: stroke.points)
        case .highlight(let highlight): extent = highlight.rects.isEmpty ? box(around: highlight.points) : bounds(of: object)
        default: return (false, false)
        }
        guard extent.isFiniteRect else { return (false, false) }
        return (extent.width >= minimumFreehandExtent, extent.height >= minimumFreehandExtent)
    }

    /// The rect an object's corner and edge handles sit on: its rect, or for a freehand mark (pen stroke, highlight)
    /// its painted bounds.
    public static func handleFrame(of object: AnnotationObject) -> CGRect {
        rect(of: object.kind) ?? bounds(of: object)
    }

    /// Where a corner or edge handle sits on `rect`; the middle for the other handles. Any coordinate space.
    public static func point(of handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .corner(.topLeft): CGPoint(x: rect.minX, y: rect.minY)
        case .corner(.topRight): CGPoint(x: rect.maxX, y: rect.minY)
        case .corner(.bottomLeft): CGPoint(x: rect.minX, y: rect.maxY)
        case .corner(.bottomRight): CGPoint(x: rect.maxX, y: rect.maxY)
        case .edge(.top): CGPoint(x: rect.midX, y: rect.minY)
        case .edge(.bottom): CGPoint(x: rect.midX, y: rect.maxY)
        case .edge(.left): CGPoint(x: rect.minX, y: rect.midY)
        case .edge(.right): CGPoint(x: rect.maxX, y: rect.midY)
        case .start, .end, .control: CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    public static func handlePoint(_ handle: Handle, of object: AnnotationObject) -> CGPoint {
        switch (handle, object.kind) {
        case (.start, .line(let start, _)): return start
        case (.end, .line(_, let end)): return end
        case (.start, .arrow(let arrow)): return arrow.start
        case (.end, .arrow(let arrow)): return arrow.end
        case (.control, .arrow(let arrow)): return ArrowGeometry.controlPoint(of: arrow)
        case (.corner, _), (.edge, _):
            return point(of: handle, in: handleFrame(of: object))
        default:
            return bounds(of: object).origin
        }
    }

    /// The object with `handle` dragged to `point`. `constrained` (⇧) keeps a rect's proportions and snaps line and
    /// arrow ends to 45°.
    public static func dragging(_ handle: Handle, of object: AnnotationObject, to point: CGPoint, constrained: Bool) -> AnnotationObject {
        var copy = object
        switch object.kind {
        case .line(let start, let end):
            switch handle {
            case .start: copy.kind = .line(start: constrained ? ShapeConstraints.snapped(point, from: end) : point, end: end)
            case .end: copy.kind = .line(start: start, end: constrained ? ShapeConstraints.snapped(point, from: start) : point)
            default: break
            }
        case .arrow(var arrow):
            switch handle {
            case .start: arrow.start = constrained ? ShapeConstraints.snapped(point, from: arrow.end) : point
            case .end: arrow.end = constrained ? ShapeConstraints.snapped(point, from: arrow.start) : point
            case .control: arrow.control = point
            default: break
            }
            copy.kind = .arrow(arrow)
        case .text(var text):
            let frame = TextLayout.frame(of: text)
            // Narrowest a box can get: its padding both sides plus one em of text.
            let minimumWidth = 2 * TextLayout.padding(for: text.style, fontSize: text.fontSize).width + text.fontSize
            switch handle {
            case .edge(.right):
                text.width = max(minimumWidth, point.x - frame.minX)
            case .edge(.left):
                let width = max(minimumWidth, frame.maxX - point.x)
                text.origin.x = frame.maxX - width
                text.width = width
            default: break
            }
            copy.kind = .text(text)
        case .stroke, .highlight:
            // A freehand mark stretches with its bounds; ⇧ keeps their proportions. Its width stays. A handle it doesn't
            // show (a flat line has no top or corners) does nothing, and ⇧ means nothing on a line.
            guard handles(of: object).contains(handle) else { return object }
            let frame = bounds(of: object)
            let stretch = freehandStretch(of: object)
            let aspect: Double? = constrained && stretch.horizontal && stretch.vertical ? frame.width / frame.height : nil
            let target = resized(frame, handle: handle, to: point, aspect: aspect)
            return scaled(object, from: frame, to: target)
        default:
            guard let rect = rect(of: object.kind) else { return object }
            let aspect: Double? = constrained && rect.height > 0 ? rect.width / rect.height : nil
            copy.kind = withRect(object.kind, resized(rect, handle: handle, to: point, aspect: aspect))
        }
        return copy
    }

    /// `rect` with `handle` dragged to `point`. With an `aspect` (width ÷ height), a corner keeps it about the opposite
    /// corner, the larger pull winning, and an edge keeps it by growing the other side about the rect's middle. The result
    /// is standardized, so a drag past the opposite side flips cleanly.
    public static func resized(_ rect: CGRect, handle: Handle, to point: CGPoint, aspect: Double?) -> CGRect {
        let aspect = aspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .corner(let corner):
            let anchor: CGPoint = switch corner {
            case .topLeft: CGPoint(x: maxX, y: maxY)
            case .topRight: CGPoint(x: minX, y: maxY)
            case .bottomLeft: CGPoint(x: maxX, y: minY)
            case .bottomRight: CGPoint(x: minX, y: minY)
            }
            var dx = point.x - anchor.x
            var dy = point.y - anchor.y
            if let aspect {
                let width = max(abs(dx), abs(dy) * aspect)
                dx = (dx < 0 ? -1 : 1) * width
                dy = (dy < 0 ? -1 : 1) * width / aspect
            }
            return CGRect(x: anchor.x, y: anchor.y, width: dx, height: dy).standardized
        case .edge(let edge):
            switch edge {
            case .top: minY = point.y
            case .bottom: maxY = point.y
            case .left: minX = point.x
            case .right: maxX = point.x
            }
            if let aspect {
                switch edge {
                case .top, .bottom:
                    let width = abs(maxY - minY) * aspect
                    minX = rect.midX - width / 2
                    maxX = rect.midX + width / 2
                case .left, .right:
                    let height = abs(maxX - minX) / aspect
                    minY = rect.midY - height / 2
                    maxY = rect.midY + height / 2
                }
            }
        case .start, .end, .control:
            break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).standardized
    }

    // MARK: Helpers

    /// A freehand mark stretched so its painted bounds `frame` become `target`, its line width unchanged. Freehand points
    /// map between the two frames less half the width, so the mark's painted edges land on the target's. Snapped highlight
    /// rects map between the frames themselves.
    static func scaled(_ object: AnnotationObject, from frame: CGRect, to target: CGRect) -> AnnotationObject {
        var copy = object
        switch object.kind {
        case .stroke(var stroke):
            let margin = object.style.lineWidth / 2
            let from = inner(frame, by: margin), to = inner(target, by: margin)
            stroke.points = stroke.points.map { remap($0, from: from, to: to) }
            copy.kind = .stroke(stroke)
        case .highlight(var highlight):
            if highlight.rects.isEmpty {
                let margin = highlight.width / 2
                let from = inner(frame, by: margin), to = inner(target, by: margin)
                highlight.points = highlight.points.map { remap($0, from: from, to: to) }
            } else {
                highlight.rects = highlight.rects.map { rect in
                    let a = remap(CGPoint(x: rect.minX, y: rect.minY), from: frame, to: target)
                    let b = remap(CGPoint(x: rect.maxX, y: rect.maxY), from: frame, to: target)
                    return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                }
            }
            copy.kind = .highlight(highlight)
        default:
            break
        }
        return copy
    }

    /// `rect` less `margin` on every side, but never less than nothing: a side too short keeps only its middle.
    private static func inner(_ rect: CGRect, by margin: Double) -> CGRect {
        let dx = min(margin, rect.width / 2), dy = min(margin, rect.height / 2)
        return CGRect(x: rect.minX + dx, y: rect.minY + dy, width: rect.width - 2 * dx, height: rect.height - 2 * dy)
    }

    /// `point` at the same relative spot in `to` as it has in `from`. On an axis `from` has no extent on, the point keeps
    /// its offset from the start.
    private static func remap(_ point: CGPoint, from: CGRect, to: CGRect) -> CGPoint {
        func axis(_ value: Double, _ fromStart: Double, _ fromLength: Double, _ toStart: Double, _ toLength: Double) -> Double {
            fromLength > 0 ? toStart + (value - fromStart) * toLength / fromLength : toStart + (value - fromStart)
        }
        return CGPoint(x: axis(point.x, from.minX, from.width, to.minX, to.width),
                       y: axis(point.y, from.minY, from.height, to.minY, to.height))
    }

    private static func withRect(_ kind: ObjectKind, _ rect: CGRect) -> ObjectKind {
        switch kind {
        case .rectangle: return .rectangle(rect)
        case .filledRectangle: return .filledRectangle(rect)
        case .ellipse: return .ellipse(rect)
        case .redact(var redact):
            redact.rect = rect
            return .redact(redact)
        case .spotlight(var spotlight):
            spotlight.rect = rect
            return .spotlight(spotlight)
        case .image(var image):
            image.rect = rect
            return .image(image)
        default: return kind
        }
    }

    private static func box(around points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func ellipseContains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let nx = (point.x - rect.midX) / (rect.width / 2)
        let ny = (point.y - rect.midY) / (rect.height / 2)
        return nx * nx + ny * ny <= 1
    }

    static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        return zip(points, points.dropFirst()).map { distance(from: point, toSegment: $0, $1) }.min() ?? .infinity
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
