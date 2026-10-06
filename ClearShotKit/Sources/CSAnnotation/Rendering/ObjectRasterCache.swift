import CoreGraphics
import Foundation

/// The canvas's picture of one shadowed object: the object and its shadow, drawn once at the canvas's device resolution
/// and then put back while nothing about it changes. Shadows are the slow part of a frame on a large Retina canvas, and
/// most objects don't change while another one is dragged. Exports never use it.
struct CachedObjectRaster {
    var object: AnnotationObject
    var pixelScale: Double
    var key: ObjectRasterKey
    /// The bitmap an image object showed, compared by identity: the same name can come to stand for another bitmap. Nil for
    /// every other kind.
    var picture: CGImage?
    /// Nil the first time the object is drawn this way. An object that changes every frame (the one being dragged) is
    /// never worth a raster, so one is made only when the object is drawn unchanged a second time. Also nil once the budget
    /// has dropped it (`RenderCache.makeRoom`): the entry stays, seen once.
    var raster: ObjectRaster?
    /// The frame (`RenderCache.frame`) the entry was last seen, drawn from or made in.
    var lastUsed: UInt64
}

/// The canvas's picture of everything a background draws under the objects (`BackgroundLayer`): the fill, the box with its
/// shadow, and the content with its redactions, drawn once over the whole frame at the canvas's device resolution and then
/// put back while nothing about it changes. Kept while a frame doesn't draw it (while cropping), so it is the first raster
/// the budget drops.
struct CachedBackgroundLayer {
    var key: BackgroundLayerKey
    /// Nil the first time the layer is drawn with this key, and once the budget has dropped it, as an object's.
    var raster: ObjectRaster?
    /// The frame (`RenderCache.frame`) the entry was last seen, drawn from or made in.
    var lastUsed: UInt64
}

/// Everything a background's layer is drawn from:
/// - the background (its style and the name of its picture), and the picture the fill shows, by identity: the stored one,
///   which a desktop picture resolved again replaces under the same name, or the blurred screenshot, which the content
///   analysis makes anew whenever the content or its redactions change;
/// - the content: the base, by identity, its size, the image operations, the canvas and its fill;
/// - auto-balance's trims, which move the box without changing the style;
/// - the redactions drawn with the content, each with its id (which seeds its effect's noise) and value, in drawing order,
///   and the pixel scale that sizes their blocks (it sizes the background's lengths too);
/// - the device geometry over the frame (`ObjectRasterKey`).
struct BackgroundLayerKey: Equatable {
    var background: DocumentBackground
    var picture: CGImage?
    var base: CGImage
    var baseSize: CGSize
    var imageOps: [ImageOp]
    var canvasBounds: CGRect
    var canvasFill: CanvasFill
    var trims: EdgeTrims
    var redactions: [RedactionKey]
    var pixelScale: Double
    var device: ObjectRasterKey

    init(_ layer: BackgroundLayer, device: ObjectRasterKey) {
        background = layer.background
        picture = layer.picture
        base = layer.base
        baseSize = layer.document.baseSize
        imageOps = layer.document.imageOps
        canvasBounds = layer.document.canvasBounds
        canvasFill = layer.document.canvasFill
        trims = layer.trims
        redactions = RedactionKey.all(in: layer.redactions)
        pixelScale = layer.document.pixelScale
        self.device = device
    }

    static func == (a: BackgroundLayerKey, b: BackgroundLayerKey) -> Bool {
        a.picture === b.picture && a.base === b.base && a.background == b.background && a.baseSize == b.baseSize
            && a.imageOps == b.imageOps && a.canvasBounds == b.canvasBounds && a.canvasFill == b.canvasFill && a.trims == b.trims
            && a.redactions == b.redactions && a.pixelScale == b.pixelScale && a.device == b.device
    }
}

/// The device geometry a raster was made for:
/// - each axis's user-to-device scale, to a millionth (relative), so the same zoom lands in the same bucket whatever
///   floating-point noise a frame's transform carries, and a zoom that differs by even a visible fraction of a pixel across
///   the object doesn't reuse a stretched raster;
/// - the axes' directions (rotation and flips);
/// - the window's backing scale;
/// - where the raster's first pixel falls between device pixels, in sixteenths: a raster is rounded to whole device pixels,
///   so one made at another fraction would sit up to half a pixel from where a direct draw puts the object.
struct ObjectRasterKey: Equatable {
    var xScale: Int
    var yScale: Int
    var a: Int, b: Int, c: Int, d: Int
    var deviceScale: Double
    var phaseX: Int
    var phaseY: Int

    /// Nil when the geometry can't be keyed (not finite, or no scale): such an object is drawn directly, never cached.
    /// `area` is the object's raster area in base pixels.
    init?(ctm: CGAffineTransform, deviceScale: Double, area: CGRect) {
        let sx = hypot(ctm.a, ctm.b)
        let sy = hypot(ctm.c, ctm.d)
        let device = area.applying(ctm)
        guard !area.isNull, !area.isInfinite, deviceScale.isFinite,
              [ctm.a, ctm.b, ctm.c, ctm.d, ctm.tx, ctm.ty, sx, sy, device.minX, device.minY, device.width, device.height]
                  .allSatisfy(\.isFinite),
              sx > 1e-9, sy > 1e-9
        else { return nil }
        xScale = Int((log(sx) * 1_000_000).rounded())
        yScale = Int((log(sy) * 1_000_000).rounded())
        a = Int((ctm.a / sx).rounded())
        b = Int((ctm.b / sx).rounded())
        c = Int((ctm.c / sy).rounded())
        d = Int((ctm.d / sy).rounded())
        self.deviceScale = deviceScale
        phaseX = Self.phase(of: device.minX)
        phaseY = Self.phase(of: device.minY)
    }

    /// How far `edge` lies past a whole device pixel, in sixteenths of a pixel. A fraction that rounds up to a whole pixel
    /// wraps to 0.
    private static func phase(of edge: Double) -> Int {
        Int(((edge - edge.rounded(.down)) * 16).rounded()) % 16
    }
}

/// An object's pixels and what is needed to put them back:
/// - the area they cover, in base pixels;
/// - how far their first pixel sat from where that area began in the context's pixel space (its `ctm` space);
/// - how big the area was there, when they were made.
struct ObjectRaster {
    var image: CGImage
    var area: CGRect
    var offset: CGVector
    var deviceSize: CGSize

    /// What the raster takes as the budget counts it: 4 bytes a pixel.
    var bytes: Int {
        image.width * image.height * 4
    }
}

/// Which rasters to drop so a new one fits the canvas's budget.
enum RasterBudget {
    /// Which rasters to drop, oldest first, so `needed` more bytes fit; nil when they can't without dropping one used in `frame`.
    /// Empty when they fit already. Rasters last used in the same frame go in the order given.
    ///
    /// Every frame draws every object, so a raster a frame has used is one it needs: dropping it would only make it again
    /// the next frame (and drop another). So only rasters not used in this frame can go, the background layer while
    /// cropping, say; without enough of them, the new raster isn't made.
    static func evictions(of entries: [(id: AnyHashable, bytes: Int, lastUsed: UInt64)], needed: Int, budget: Int,
                          frame: UInt64) -> [AnyHashable]? {
        var total = entries.reduce(needed) { $0 + $1.bytes }
        guard total > budget else { return [] }
        let candidates = entries.enumerated().filter { $0.element.lastUsed < frame }
            .sorted { ($0.element.lastUsed, $0.offset) < ($1.element.lastUsed, $1.offset) }
        var dropped: [AnyHashable] = []
        for (_, entry) in candidates {
            total -= entry.bytes
            dropped.append(entry.id)
            if total <= budget { return dropped }
        }
        return nil
    }
}

/// A kept raster, as the budget names it.
private enum RasterID: Hashable {
    case object(UUID)
    case backgroundLayer
}

extension RenderCache {
    /// What the kept rasters take together, in bytes at 4 a pixel: the objects' and the background layer's.
    var rasterBytes: Int {
        keptRasters.reduce(0) { $0 + $1.bytes }
    }

    private var keptRasters: [(id: AnyHashable, bytes: Int, lastUsed: UInt64)] {
        var kept = objectRasters.compactMap { id, entry in
            entry.raster.map { (id: AnyHashable(RasterID.object(id)), bytes: $0.bytes, lastUsed: entry.lastUsed) }
        }
        if let layer = backgroundLayer, let raster = layer.raster {
            kept.append((id: AnyHashable(RasterID.backgroundLayer), bytes: raster.bytes, lastUsed: layer.lastUsed))
        }
        return kept
    }

    /// Makes room in the budget for a new raster of `bytes`, dropping the rasters `RasterBudget.evictions` picks (their
    /// entries stay, seen once). False, dropping nothing, when it can't.
    func makeRoom(for bytes: Int) -> Bool {
        guard let evictions = RasterBudget.evictions(of: keptRasters, needed: bytes, budget: rasterBudget, frame: frame)
        else { return false }
        for id in evictions {
            switch id.base as? RasterID {
            case .object(let object): objectRasters[object]?.raster = nil
            case .backgroundLayer: backgroundLayer?.raster = nil
            case nil: break
            }
        }
        return true
    }
}

extension Renderer {
    /// The most device pixels one raster may have (64 MB); a bigger object, or background layer, is drawn directly.
    static let maximumRasterPixels = 16_777_216.0

    /// Draws a shadowed object (the context already in base pixels) from the cache, making its raster on the second
    /// unchanged draw.
    static func drawCached(_ object: AnnotationObject, pixelScale: Double, base: CGImage?, images: ImageStore, in context: CGContext,
                           cache: RenderCache, deviceScale: Double) {
        // The same area `draw` gives the object's shadow layer.
        let reach = 10 * pixelScale
        let area = ObjectGeometry.bounds(of: object).insetBy(dx: -reach, dy: -reach)
        guard !area.isEmpty, let key = ObjectRasterKey(ctm: context.ctm, deviceScale: deviceScale, area: area) else {
            // Nothing to key a raster by (an empty area, or numbers that aren't finite): drawn directly, and not remembered.
            cache.objectRasters[object.id] = nil
            draw(object, pixelScale: pixelScale, base: base, images: images, in: context, cache: cache, deviceScale: deviceScale)
            return
        }
        let picture = shownPicture(of: object, images: images)
        if let entry = cache.objectRasters[object.id], entry.object == object, entry.pixelScale == pixelScale, entry.key == key,
           entry.picture === picture {
            cache.objectRasters[object.id]?.lastUsed = cache.frame
            if let raster = entry.raster {
                put(raster, in: context)
                return
            }
            // A bitmap's base space is its own pixels, so its shadow is sized with a device scale of 1 (see `draw`): it
            // comes out the same number of device pixels as on the canvas.
            if let raster = makeRaster(of: area, in: context, cache: cache, drawing: { bitmap in
                draw(object, pixelScale: pixelScale, base: base, images: images, in: bitmap, deviceScale: 1)
            }) {
                cache.objectRasters[object.id]?.raster = raster
                put(raster, in: context)
                return
            }
        } else {
            cache.objectRasters[object.id] = CachedObjectRaster(object: object, pixelScale: pixelScale, key: key, picture: picture,
                                                                raster: nil, lastUsed: cache.frame)
        }
        draw(object, pixelScale: pixelScale, base: base, images: images, in: context, cache: cache, deviceScale: deviceScale)
    }

    /// Draws a background's layer (`draw(_:in:cache:deviceScale:)`; the context in output pixels) from the cache, making its
    /// raster on the second unchanged draw, as an object's. The raster covers the whole frame, not just the part the
    /// context's clip lets through (the canvas's dirty rect), so a later scroll finds all of it. A layer with a redaction
    /// whose effect couldn't be made shows it black, as a direct draw does, but isn't kept: the next frame tries again.
    static func drawCached(_ layer: BackgroundLayer, in context: CGContext, cache: RenderCache, deviceScale: Double) {
        let frame = layer.layout.frame
        guard let device = ObjectRasterKey(ctm: context.ctm, deviceScale: deviceScale, area: frame) else {
            // Numbers that aren't finite: drawn directly, and not remembered.
            cache.backgroundLayer = nil
            draw(layer, in: context, cache: cache, deviceScale: deviceScale)
            return
        }
        let key = BackgroundLayerKey(layer, device: device)
        if let entry = cache.backgroundLayer, entry.key == key {
            cache.backgroundLayer?.lastUsed = cache.frame
            if let raster = entry.raster {
                put(raster, in: context)
                return
            }
            var complete = true
            // Device scale 1 against the bitmap's own pixels, as for an object, so the box's shadow keeps its size.
            if let raster = makeRaster(of: frame, in: context, cache: cache, drawing: { bitmap in
                complete = draw(layer, in: bitmap, cache: cache, deviceScale: 1)
            }) {
                if complete { cache.backgroundLayer?.raster = raster }
                put(raster, in: context)
                return
            }
        } else {
            cache.backgroundLayer = CachedBackgroundLayer(key: key, raster: nil, lastUsed: cache.frame)
        }
        draw(layer, in: context, cache: cache, deviceScale: deviceScale)
    }

    /// The bitmap an image object draws, if it is one and the store has it.
    private static func shownPicture(of object: AnnotationObject, images: ImageStore) -> CGImage? {
        guard case .image(let image) = object.kind else { return nil }
        return images[image.image]
    }

    /// `drawing` done alone into a bitmap whose pixels are the context's own pixels over `area`, starting at its first whole
    /// one, with the context's user space. Nil when the area is empty or too big, the budget has no room for it
    /// (`RenderCache.makeRoom`), or a bitmap can't be made.
    private static func makeRaster(of area: CGRect, in context: CGContext, cache: RenderCache,
                                   drawing: (CGContext) -> Void) -> ObjectRaster? {
        // `ctm` maps user space to the context's pixel space: a bitmap's pixels (y up) or a window's backing pixels. (Not
        // `convertToDeviceSpace`, whose device space for a bitmap runs top-down.)
        let device = area.applying(context.ctm)
        let pixels = device.integral
        guard pixels.width >= 1, pixels.height >= 1, pixels.width * pixels.height <= maximumRasterPixels,
              cache.makeRoom(for: Int(pixels.width) * Int(pixels.height) * 4),
              let space = context.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                     bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        bitmap.translateBy(x: -pixels.minX, y: -pixels.minY)
        bitmap.concatenate(context.ctm)
        drawing(bitmap)
        guard let image = bitmap.makeImage() else { return nil }
        return ObjectRaster(image: image, area: area, offset: CGVector(dx: pixels.minX - device.minX, dy: pixels.minY - device.minY),
                            deviceSize: device.size)
    }

    /// Draws a raster in the context's pixel space, where its area now lands, on whole pixels. At the zoom it was made for,
    /// that is pixel for pixel.
    static func put(_ raster: ObjectRaster, in context: CGContext) {
        let device = raster.area.applying(context.ctm)
        let scaleX = raster.deviceSize.width > 0 ? device.width / raster.deviceSize.width : 1
        let scaleY = raster.deviceSize.height > 0 ? device.height / raster.deviceSize.height : 1
        let target = CGRect(x: (device.minX + raster.offset.dx * scaleX).rounded(), y: (device.minY + raster.offset.dy * scaleY).rounded(),
                            width: Double(raster.image.width) * scaleX, height: Double(raster.image.height) * scaleY)
        context.saveGState()
        context.concatenate(context.ctm.inverted())
        context.draw(raster.image, in: target)
        context.restoreGState()
    }
}
