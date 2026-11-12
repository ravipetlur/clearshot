import CoreGraphics
import Foundation

/// What decides the pixels the pixel tools read (`PicturePixels`): the document's picture (`PictureIdentity`, the very thing
/// the secrets check rescans on) and the images placed on it. Two documents with the same identity have the same pixels
/// there, so a sampler made for one serves the other.
public struct PicturePixelsIdentity: Equatable, Sendable {
    /// The base, the image operations, the canvas and its fill, and the redactions.
    public let picture: PictureIdentity
    /// The image objects (pasted, dropped and combined pictures), in the document's order.
    public let images: [AnnotationObject]
}

extension AnnotationDocument {
    /// The document reduced to what the pixel tools read: its picture (`pictureOnly`: the base as the image operations and
    /// the canvas have left it, with the canvas fill and the redactions) and the images placed on it, without the other
    /// annotations and without the background.
    ///
    /// - **Included:** the base image; Rotate, Flip and Resize; the crop and the expanded canvas with its fill; the
    ///   redactions, so a tool never reads what one hides; and image objects, which is how pasted pictures and combined
    ///   screenshots (dropped beside the canvas) are held: they read as part of the picture.
    /// - **Left out:** shapes, arrows, text, counters, pen and highlighter strokes, spotlights (their dimming), and the
    ///   background frame around the canvas, which lies outside the base.
    public var pixelSource: AnnotationDocument {
        var copy = self
        copy.objects = objects.filter { object in
            switch object.kind {
            case .redact, .image: true
            default: false
            }
        }
        copy.background = nil
        return copy
    }

    /// The identity of the pixels the pixel tools read (`PicturePixelsIdentity`).
    public var picturePixelsIdentity: PicturePixelsIdentity {
        PicturePixelsIdentity(picture: pictureIdentity, images: objects.filter { if case .image = $0.kind { true } else { false } })
    }
}

/// A document's picture as it is shown, without the annotations (`AnnotationDocument.pixelSource`), as pixels to read: the
/// sampler, and where its pixels lie in the document's base.
///
/// **Two coordinate spaces.**
/// - The sampler's pixels (`sampler`) are the picture as shown, one per output pixel: x right, y down, from the canvas's
///   top-left corner (rounded out to a whole pixel), after the turns and flips. A direction on screen is the same direction
///   here, and a distance here is a distance in the exported picture's pixels.
/// - The base's pixels are where the document's objects live (`AnnotationObject`, "geometry is in base pixels"). The
///   methods here take and return base pixels, so a tool can pass a point from the canvas (as it already has it for drawing)
///   and put what it finds straight into an object.
///
/// Rotate, Flip and Resize keep rectangles axis-aligned, so a rect maps to a rect both ways.
public struct PicturePixels: Sendable {
    /// What these pixels are of. The editor compares it with the document's to know whether they are still current.
    public let identity: PicturePixelsIdentity
    /// The pixels, in the picture's own space (see above).
    public let sampler: PixelSampler
    /// Takes a point in the sampler's pixels to the base's pixels.
    public let toBase: CGAffineTransform
    /// Takes a point in the base's pixels to the sampler's pixels.
    public let fromBase: CGAffineTransform

    public init(identity: PicturePixelsIdentity, sampler: PixelSampler, toBase: CGAffineTransform) {
        self.identity = identity
        self.sampler = sampler
        self.toBase = toBase
        fromBase = toBase.inverted()
    }

    /// Renders `document`'s picture (`pixelSource`) once and copies its pixels into a sampler. Nil when the picture can't be
    /// rendered (no base image, an output that is empty or too big) or is too large for a sampler
    /// (`PixelSampler.maximumPixelCount`). Slow for a large picture: call it off the main actor, as the editor does
    /// (`AnnotationEditor.loadPicturePixels`).
    public static func make(of document: AnnotationDocument, images: ImageStore) -> PicturePixels? {
        guard let render = Renderer.renderReduced(document.pixelSource, images: images),
              let sampler = PixelSampler(image: render.image) else { return nil }
        return PicturePixels(identity: document.picturePixelsIdentity, sampler: sampler, toBase: render.mapping.toBase)
    }

    // MARK: Between the spaces

    /// A point in base pixels, in the sampler's pixels.
    public func pixelPoint(fromBase point: CGPoint) -> CGPoint { point.applying(fromBase) }

    /// A point in the sampler's pixels, in base pixels.
    public func basePoint(fromPixel point: CGPoint) -> CGPoint { point.applying(toBase) }

    /// A rect in base pixels, in the sampler's pixels.
    public func pixelRect(fromBase rect: CGRect) -> CGRect { rect.applying(fromBase) }

    /// A rect in the sampler's pixels, in base pixels.
    public func baseRect(fromPixel rect: CGRect) -> CGRect { rect.applying(toBase) }

    // MARK: Reading, in base pixels

    /// The color shown at `point` (base pixels), or nil off the picture. See `PixelSampler.color(at:)`.
    public func color(at point: CGPoint) -> RGBAColor? {
        sampler.color(at: pixelPoint(fromBase: point))
    }

    /// The average color of `rect` (base pixels) as shown, or nil when it covers none of the picture. See
    /// `PixelSampler.average(in:)`.
    public func average(in rect: CGRect) -> RGBAColor? {
        sampler.average(in: pixelRect(fromBase: rect))
    }

    /// The darkest color shown in `rect` (base pixels), or nil when it covers none of the picture. See
    /// `PixelSampler.darkest(in:)`.
    public func darkest(in rect: CGRect) -> RGBAColor? {
        sampler.darkest(in: pixelRect(fromBase: rect))
    }

    /// The darkest color shown in a square `side` pixels of the picture across (as shown, not base pixels), centred on
    /// `point` (base pixels): the color of the text under a cursor, at the same reach whatever the zoom or resize.
    public func darkest(around point: CGPoint, side: Int) -> RGBAColor? {
        let center = pixelPoint(fromBase: point)
        let half = Double(max(side, 1)) / 2
        return sampler.darkest(in: CGRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2))
    }

    /// Where a run of matching color ends, measured from `point` (base pixels) in `direction` as shown on screen.
    public struct Edge: Equatable, Sendable {
        /// The distance in the picture's pixels as shown (`PixelSampler.edge`): the run of matching pixels, the start
        /// included, is this long.
        public let distance: Int
        /// The boundary between the last matching pixel and the first that differs (or the picture's border), on the line
        /// through the middle of the start pixel, in base pixels: where a ruler's end goes.
        public let boundary: CGPoint
        /// Whether the run reached the picture's border rather than a different color.
        public let reachedBorder: Bool
    }

    /// The edge from the pixel under `point` (base pixels) in `direction` as shown, with colors within `tolerance` (0...255,
    /// any channel) counting as the same. Nil off the picture. See `PixelSampler.edge(from:direction:tolerance:)`.
    public func edge(from point: CGPoint, direction: PixelDirection, tolerance: Int) -> Edge? {
        let start = pixelPoint(fromBase: point)
        guard let distance = sampler.edge(from: start, direction: direction, tolerance: tolerance),
              let (x, y) = PixelSampler.index(of: start) else { return nil }
        let middle = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
        let boundary: CGPoint
        let reachedBorder: Bool
        switch direction {
        case .left:
            boundary = CGPoint(x: Double(x - distance + 1), y: middle.y)
            reachedBorder = x - distance < 0
        case .right:
            boundary = CGPoint(x: Double(x + distance), y: middle.y)
            reachedBorder = x + distance >= sampler.width
        case .up:
            boundary = CGPoint(x: middle.x, y: Double(y - distance + 1))
            reachedBorder = y - distance < 0
        case .down:
            boundary = CGPoint(x: middle.x, y: Double(y + distance))
            reachedBorder = y + distance >= sampler.height
        }
        return Edge(distance: distance, boundary: basePoint(fromPixel: boundary), reachedBorder: reachedBorder)
    }

    /// The bounds, in base pixels, of the flat-colored region shown under `point` (base pixels), or nil off the picture or
    /// when the region is larger than `maxPixels` pixels of the picture. See `PixelSampler.floodFillBounds`.
    public func floodFillBounds(from point: CGPoint, tolerance: Int, maxPixels: Int) -> CGRect? {
        sampler.floodFillBounds(from: pixelPoint(fromBase: point), tolerance: tolerance, maxPixels: maxPixels)
            .map(baseRect(fromPixel:))
    }

    /// `rect` (base pixels) with each of `edges` moved in over the flat margin around its content, in base pixels. Edges are
    /// named as they are on the base: after Rotate or Flip they are other sides of the sampled pixels. See `PixelFit`.
    public func fitBounds(of rect: CGRect, tolerance: Int, edges: Set<RectEdge> = Set(RectEdge.allCases)) -> CGRect {
        let area = pixelRect(fromBase: rect)
        let fitted = PixelFit.fitted(area, in: sampler, tolerance: tolerance, edges: Set(edges.map(pixelEdge(forBase:))))
        return baseRect(fromPixel: fitted)
    }

    /// The side of the sampled pixels that shows as `edge` of the base: the one the base side's outward direction maps to.
    private func pixelEdge(forBase edge: RectEdge) -> RectEdge {
        let outward: CGVector = switch edge {
        case .top: CGVector(dx: 0, dy: -1)
        case .bottom: CGVector(dx: 0, dy: 1)
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        }
        let dx = fromBase.a * outward.dx + fromBase.c * outward.dy
        let dy = fromBase.b * outward.dx + fromBase.d * outward.dy
        if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
        return dy < 0 ? .top : .bottom
    }
}
