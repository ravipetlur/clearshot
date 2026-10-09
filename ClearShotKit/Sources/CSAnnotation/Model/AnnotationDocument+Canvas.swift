import CoreGraphics
import Foundation

/// The canvas and the picture in output pixels: limits, bounds, the background's frame, Revert to Original and the
/// auto-expanding canvas.
extension AnnotationDocument {
    /// The longest side, in pixels, the editor gives a picture or canvas (resize, crop, auto-expand, combining), an
    /// inserted bitmap or a background's frame: what every format ClearShot writes can hold, WebP's limit (the encoder's
    /// 16 383, which is what macOS can decode) being the lowest.
    public static let maximumOutputSide = 16_383.0

    /// How far past an object the auto-expanding canvas reaches, in output pixels.
    public static let autoExpandMargin = 16.0

    /// How far a bound may sit past the canvas edge before it counts as outside, in output pixels. Arithmetic on uneven
    /// numbers (a paste moved into the canvas, a zoomed drag) leaves bounds a few ULP over an edge they were put on; that
    /// isn't an object past the canvas, and growing the canvas for it would add a margin's worth of fill.
    static let edgeTolerance = 1e-6

    /// The picture after image operations, in output pixels, from the origin.
    public var pictureBounds: CGRect {
        CGRect(origin: .zero, size: transform.outputSize)
    }

    /// Output pixels per point of a background's lengths: the capture's pixels per point through the image operations,
    /// so a resize to half halves the padding in pixels too.
    public var backgroundScale: Double {
        pixelScale * transform.scale
    }

    /// The background's frame around the canvas (`BackgroundLayout`), or nil without a background. `trims` are
    /// auto-balance's (`AutoBalance.trims(of:)` on the rendered content), and count only when the style has auto-balance
    /// on.
    public func backgroundLayout(trims: EdgeTrims = .zero) -> BackgroundLayout? {
        guard let style = background?.style else { return nil }
        return BackgroundLayout.make(canvas: canvasBounds, style: style, scale: backgroundScale,
                                     trims: style.autoBalance ? trims : .zero)
    }

    /// What the document renders, in output pixels: the background's frame, or the canvas without a background. Whatever
    /// sizes the output (the render, the canvas view, the Resize sheet) should use this rather than `canvasBounds`.
    public func outputBounds(trims: EdgeTrims = .zero) -> CGRect {
        backgroundLayout(trims: trims)?.frame ?? canvasBounds
    }

    /// An object's painted bounds in output pixels: its base-pixel bounds through the image operations. Null for an
    /// object that paints nothing.
    public func outputBounds(of object: AnnotationObject) -> CGRect {
        let bounds = ObjectGeometry.bounds(of: object)
        guard !bounds.isNull else { return .null }
        return bounds.applying(transform.transform)
    }

    /// `objects` moved together, as little as needed, so their output bounds lie inside the canvas: a group bigger than the
    /// canvas lines up with its top-left. Objects that paint nothing don't count. The bounds end inside the canvas, never
    /// a rounding error past an edge: the move goes through base pixels and back, so when it leaves a bound a few ULP over,
    /// a nudge puts that bound a hair (1e-9) inside.
    public func clampedIntoCanvas(_ objects: [AnnotationObject]) -> [AnnotationObject] {
        let canvas = canvasBounds
        func union(of objects: [AnnotationObject]) -> CGRect? {
            let bounds = objects.map(outputBounds(of:)).filter { !$0.isNull }.reduce(CGRect.null) { $0.union($1) }
            let numbers = [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]
            return bounds.isNull || !numbers.allSatisfy(\.isFinite) ? nil : bounds
        }
        /// The move, along one axis, that puts the group inside; `slack` is how much further in than the edge to aim.
        func shift(_ low: Double, _ high: Double, _ canvasLow: Double, _ canvasHigh: Double, slack: Double = 0) -> Double {
            if high - low >= canvasHigh - canvasLow || low < canvasLow { return canvasLow - low + (low < canvasLow ? slack : 0) }
            if high > canvasHigh { return canvasHigh - high - slack }
            return 0
        }
        /// `objects` moved by a vector in output pixels, which goes into base pixels as a vector.
        func moved(_ objects: [AnnotationObject], dx: Double, dy: Double) -> [AnnotationObject] {
            let target = transform.toBase(CGPoint(x: dx, y: dy))
            let origin = transform.toBase(.zero)
            let delta = CGVector(dx: target.x - origin.x, dy: target.y - origin.y)
            return objects.map { ObjectGeometry.translated($0, by: delta) }
        }
        guard let bounds = union(of: objects) else { return objects }
        let dx = shift(bounds.minX, bounds.maxX, canvas.minX, canvas.maxX)
        let dy = shift(bounds.minY, bounds.maxY, canvas.minY, canvas.maxY)
        guard dx != 0 || dy != 0 else { return objects }
        var result = moved(objects, dx: dx, dy: dy)
        // What rounding left over an edge (a group that doesn't fit a side is meant to run past its far edge, so only its
        // near edge counts there).
        for _ in 0..<3 {
            guard let now = union(of: result) else { break }
            let fitsAcross = now.width < canvas.width, fitsDown = now.height < canvas.height
            let overX = now.minX < canvas.minX || (fitsAcross && now.maxX > canvas.maxX)
            let overY = now.minY < canvas.minY || (fitsDown && now.maxY > canvas.maxY)
            guard overX || overY else { break }
            result = moved(result, dx: overX ? shift(now.minX, now.maxX, canvas.minX, canvas.maxX, slack: 1e-9) : 0,
                           dy: overY ? shift(now.minY, now.maxY, canvas.minY, canvas.maxY, slack: 1e-9) : 0)
        }
        return result
    }

    /// Whether Revert to Original has anything to undo: image operations, a crop or expansion, or a fill other than Auto.
    public var canRevertToOriginal: Bool {
        !imageOps.isEmpty || canvasRect != nil || canvasFill != .auto
    }

    /// Revert to Original: no image operations, the whole picture, Auto fill. Objects stay where they are in the base
    /// image.
    public func revertedToOriginal() -> AnnotationDocument {
        var copy = self
        copy.imageOps = []
        copy.canvasRect = nil
        copy.canvasFill = .auto
        return copy
    }

    /// Auto-expand canvas: the canvas grown, never shrunk, so each object that is new or changed since `previous`
    /// (every object when `previous` is nil) fits. Each side an object passes grows to that object's edge plus
    /// `autoExpandMargin`; sides it doesn't cross (by more than `edgeTolerance`) stay. Whole output pixels. An axis
    /// that would pass `maximumOutputSide` keeps its extent. When nothing passes the canvas, the document comes back
    /// unchanged, `canvasRect` nil included.
    ///
    /// Comparing with `previous` is what lets a crop stand: an object a crop cut through stays cut until a change touches
    /// that object.
    public func expandedToFit(since previous: AnnotationDocument? = nil) -> AnnotationDocument {
        let before = previous.map { document in
            Dictionary(document.objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let canvas = canvasBounds
        var minX = canvas.minX, minY = canvas.minY, maxX = canvas.maxX, maxY = canvas.maxY
        let margin = Self.autoExpandMargin
        for object in objects where before.map({ $0[object.id] != object }) ?? true {
            let bounds = outputBounds(of: object)
            guard bounds.isFiniteRect else { continue }
            if bounds.minX < canvas.minX - Self.edgeTolerance { minX = min(minX, (bounds.minX - margin).rounded(.down)) }
            if bounds.maxX > canvas.maxX + Self.edgeTolerance { maxX = max(maxX, (bounds.maxX + margin).rounded(.up)) }
            if bounds.minY < canvas.minY - Self.edgeTolerance { minY = min(minY, (bounds.minY - margin).rounded(.down)) }
            if bounds.maxY > canvas.maxY + Self.edgeTolerance { maxY = max(maxY, (bounds.maxY + margin).rounded(.up)) }
        }
        if maxX - minX > Self.maximumOutputSide {
            minX = canvas.minX
            maxX = canvas.maxX
        }
        if maxY - minY > Self.maximumOutputSide {
            minY = canvas.minY
            maxY = canvas.maxY
        }
        let grown = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard grown != canvas else { return self }
        var copy = self
        copy.canvasRect = grown
        return copy
    }
}

/// The Resize sheet's arithmetic: sizes in output pixels, 1 to 16 383 per side. None of it traps, whatever the numbers:
/// what can't be a size is clamped to the nearest one, and what isn't a number leaves the size as it was.
public enum ImageResize {
    public static func clamped(_ value: Int) -> Int {
        min(max(value, 1), Int(AnnotationDocument.maximumOutputSide))
    }

    /// `size` at `percent` (25 for 25%), each side rounded and clamped. A percentage that isn't a number is 100%.
    public static func scaled(_ size: CGSize, percent: Double) -> (width: Int, height: Int) {
        let percent = percent.isFinite ? percent : 100
        return (pixels(size.width * percent / 100), pixels(size.height * percent / 100))
    }

    /// The height that keeps `size`'s proportions at `width`.
    public static func height(forWidth width: Int, keeping size: CGSize) -> Int {
        guard size.width > 0, size.width.isFinite, size.height.isFinite else { return clamped(width) }
        return pixels(Double(width) * size.height / size.width)
    }

    /// The width that keeps `size`'s proportions at `height`.
    public static func width(forHeight height: Int, keeping size: CGSize) -> Int {
        guard size.height > 0, size.height.isFinite, size.width.isFinite else { return clamped(height) }
        return pixels(Double(height) * size.width / size.height)
    }

    /// `value` rounded to a whole number of pixels within the limits; 1 for what isn't a number. The limits are applied
    /// before the conversion, which would otherwise trap on a number too big for an `Int`.
    private static func pixels(_ value: Double) -> Int {
        guard !value.isNaN else { return 1 }
        return Int(min(max(value.rounded(), 1), AnnotationDocument.maximumOutputSide))
    }
}
