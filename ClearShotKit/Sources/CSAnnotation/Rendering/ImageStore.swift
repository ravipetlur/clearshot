import CoreGraphics
import CSCapture
import Foundation

/// The images a document refers to, by name. Immutable and Sendable, so rendering can run off the main actor.
public struct ImageStore: Sendable {
    public private(set) var images: [String: CGImage]

    public init(_ images: [String: CGImage] = [:]) {
        self.images = images
    }

    public subscript(ref: ImageRef) -> CGImage? {
        images[ref.name]
    }

    public mutating func set(_ image: CGImage, for ref: ImageRef) {
        images[ref.name] = image
    }

    /// Every image the document uses: its base, its image objects and its background's picture.
    public static func references(in document: AnnotationDocument) -> Set<ImageRef> {
        var refs: Set<ImageRef> = [document.base]
        for object in document.objects {
            if case .image(let image) = object.kind { refs.insert(image.image) }
        }
        if let picture = document.background?.image { refs.insert(picture) }
        return refs
    }

    /// Loads the document's images from `directory`. A missing file, or a name that leads outside the folder, is skipped
    /// and simply doesn't draw.
    public static func load(for document: AnnotationDocument, from directory: URL) -> ImageStore {
        var store = ImageStore()
        for ref in references(in: document) {
            // A name that leads outside the folder isn't read.
            guard let url = ref.url(in: directory), let image = ImageOps.load(url) else { continue }
            store.set(image, for: ref)
        }
        return store
    }
}

/// A redaction's effect image, with everything it was computed from: the object, its region, the base it read and the
/// pixel scale that sized its blocks. It is reused only while all of those are unchanged.
struct CachedRedaction {
    var object: RedactObject
    var region: CGRect
    var base: CGImage
    var pixelScale: Double
    var image: CGImage
}

/// What the background takes from the content (the canvas as rendered, without objects or background), with what the
/// content was rendered from: the base, compared by identity, the image operations, the canvas and its fill. Each value is
/// made the first time it is needed and kept while the content is unchanged; the blur also needs its redactions unchanged.
struct CachedContentAnalysis {
    var base: CGImage
    var imageOps: [ImageOp]
    var canvasBounds: CGRect
    var canvasFill: CanvasFill
    /// Auto-balance's trims (`AutoBalance.trims(of:)`), measured on the content without its redactions.
    var trims: EdgeTrims?
    /// The Blurred screenshot fill's picture.
    var blur: CachedBlur?

    /// Whether this was measured from `document`'s content over `base`.
    func isFor(_ document: AnnotationDocument, base: CGImage) -> Bool {
        self.base === base && imageOps == document.imageOps && canvasBounds == document.canvasBounds
            && canvasFill == document.canvasFill
    }
}

/// The blurred screenshot (`BackgroundBlur.blurred`) of the content with its redactions (`Renderer.redactedContent`), with
/// what the redactions were drawn from besides the content: each one, in drawing order, and the pixel scale that sized
/// their blocks.
struct CachedBlur {
    var redactions: [RedactionKey]
    var pixelScale: Double
    var image: CGImage
}

/// The base with its redactions drawn into it (`Renderer.redactedBase`), with what it was made from: the base, compared by
/// identity, each redaction in drawing order, and the pixel scale that sized their effects.
struct CachedRedactedBase {
    var base: CGImage
    var redactions: [RedactionKey]
    var pixelScale: Double
    var image: CGImage
}

/// A redaction as its effect depends on it: its id, which seeds the effect's noise, and its value.
struct RedactionKey: Equatable {
    var id: UUID
    var redact: RedactObject

    /// The redactions among `objects`, in their order.
    static func all(in objects: [AnnotationObject]) -> [RedactionKey] {
        objects.compactMap { object in
            if case .redact(let redact) = object.kind { RedactionKey(id: object.id, redact: redact) } else { nil }
        }
    }
}

/// What the canvas remembers between frames:
/// - redacted regions, by object, and the base with all the redactions in it;
/// - shadowed objects' rasters, by object (see `CachedObjectRaster`);
/// - the background's layer: everything a background draws under the objects, as one raster (see `CachedBackgroundLayer`);
/// - the base's edge color;
/// - what the background takes from the content: auto-balance's trims and the blurred screenshot.
///
/// The rasters (the objects' and the layer's) share one budget (`rasterBudget`, `RasterBudget`). Use one cache per canvas,
/// from one actor.
public final class RenderCache {
    var redactions: [UUID: CachedRedaction] = [:]
    var redactedBase: CachedRedactedBase?
    var objectRasters: [UUID: CachedObjectRaster] = [:]
    var backgroundLayer: CachedBackgroundLayer?
    /// How a redaction's image is made. Tests replace it to make the effect fail.
    var effect: Redaction.Effect = Redaction.image
    var edgeColor: (base: CGImage, color: RGBAColor)?
    var contentAnalysis: CachedContentAnalysis?
    /// The most the kept rasters may take together, in bytes at 4 a pixel (`rasterBytes`): 256 MB.
    var rasterBudget = 268_435_456
    /// The frame being drawn: `Renderer.draw` counts one at its start whenever it has a cache. A raster used in this frame
    /// is never dropped to make room for another.
    var frame: UInt64 = 0

    public init() {}
}
