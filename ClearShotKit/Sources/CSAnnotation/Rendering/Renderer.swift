import AppKit
import CoreGraphics
import CoreText
import CSCapture
import Foundation

/// The one renderer. The canvas, exports, the clipboard, history copies and thumbnails all use it, so the result is
/// exactly what the editor shows.
public enum Renderer {
    /// The finished document at output pixel size: the background's frame, or the canvas without a background
    /// (`outputBounds(of:images:cache:)`). Nil when the base image is missing, the output is empty or too big, or a bitmap
    /// can't be made. Uses no cache.
    public static func render(_ document: AnnotationDocument, images: ImageStore) -> CGImage? {
        guard let base = images[document.base] else { return nil }
        // With a background, the content is measured once, for the frame and for the drawing alike.
        let analysis = document.background.map { _ in contentAnalysis(for: document, images: images, cache: nil) }
        let bounds = document.outputBounds(trims: analysis?.trims ?? .zero)
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) else { return nil }
        let output = bounds.integral
        guard output.width >= 1, output.height >= 1, output.width <= AnnotationDocument.maximumSide,
              output.height <= AnnotationDocument.maximumSide,
              let context = ImageOps.bitmapContext(width: Int(output.width), height: Int(output.height), preferring: base.colorSpace)
        else { return nil }
        context.translateBy(x: 0, y: output.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -output.minX, y: -output.minY)
        if let background = document.background {
            drawBackgrounded(document, background: background, analysis: analysis, images: images, in: context, cache: nil,
                             hiding: [], deviceScale: 1, useObjectCache: false)
        } else {
            draw(document, images: images, in: context)
        }
        return context.makeImage()
    }

    /// Draws the document into `context`, whose user space is output pixels with y down. A document with a background
    /// draws it around the canvas, over the output bounds (`drawBackgrounded`).
    /// - `hiding` skips objects (the text being edited inline).
    /// - `deviceScale` is the context's own backing scale (2 for a Retina window, 1 for a bitmap). Core Graphics shadow
    ///   sizes are in that scaled space, so they are divided by it to look the same size as in an export.
    /// - `useObjectCache` draws shadowed objects, and a background under the objects, from rasters kept in `cache`, within
    ///   its budget (the canvas only; exports draw everything afresh).
    public static func draw(_ document: AnnotationDocument, images: ImageStore, in context: CGContext, cache: RenderCache? = nil,
                            hiding hidden: Set<UUID> = [], deviceScale: Double = 1, useObjectCache: Bool = false) {
        cache?.frame += 1
        if let background = document.background {
            drawBackgrounded(document, background: background, images: images, in: context, cache: cache, hiding: hidden,
                             deviceScale: deviceScale, useObjectCache: useObjectCache)
            return
        }
        guard let base = images[document.base] else { return }
        let canvas = document.canvasBounds
        // The document's visual order, which hit testing reverses: what is drawn on top is what a click picks.
        let objects = document.visualOrder.filter { !hidden.contains($0.id) }
        fillCanvas(document, base: base, canvas: canvas, in: context, cache: cache)
        // The base with the redactions in it, so nothing beside one samples what it hides. Each is drawn over it again
        // below, on whole device pixels.
        drawBase(document, base: base, redactions: RedactionKey.all(in: objects), in: context, cache: cache)
        context.saveGState()
        context.concatenate(document.transform.transform)
        var spotlightsDrawn = false
        for object in objects {
            if case .spotlight = object.kind {
                // All the spotlights dim together, in one fill, where the first of them comes in the order.
                if !spotlightsDrawn { drawSpotlights(objects, covering: canvas.applying(document.transform.inverse), in: context) }
                spotlightsDrawn = true
                continue
            }
            if useObjectCache, let cache, object.style.shadow, castsShadow(object.kind) {
                drawCached(object, pixelScale: document.pixelScale, base: base, images: images, in: context, cache: cache,
                           deviceScale: deviceScale)
            } else {
                draw(object, pixelScale: document.pixelScale, base: base, images: images, in: context, cache: cache,
                     deviceScale: deviceScale)
            }
        }
        context.restoreGState()
        if let cache {
            // Deleted and undone redactions don't keep their images.
            let live = Set(document.objects.map(\.id))
            if cache.redactions.keys.contains(where: { !live.contains($0) }) {
                cache.redactions = cache.redactions.filter { live.contains($0.key) }
            }
            // An object's raster goes when the object does, when its shadow is switched off, and while it is hidden. (The
            // kinds that cast no shadow never get one, whatever their flag says: `castsShadow` gates `drawCached` above.)
            if !cache.objectRasters.isEmpty {
                let shadowed = Set(objects.lazy.filter(\.style.shadow).map(\.id))
                if cache.objectRasters.keys.contains(where: { !shadowed.contains($0) }) {
                    cache.objectRasters = cache.objectRasters.filter { shadowed.contains($0.key) }
                }
            }
        }
    }

    /// One object in base pixels; the context must already be in base pixels (as `draw(_:images:in:)` sets it up). The
    /// canvas uses this for the object being drawn.
    public static func draw(_ object: AnnotationObject, pixelScale: Double, base: CGImage?, images: ImageStore, in context: CGContext,
                            cache: RenderCache? = nil, deviceScale: Double = 1) {
        context.saveGState()
        defer { context.restoreGState() }
        let width = object.style.lineWidth
        let shadowed = object.style.shadow && castsShadow(object.kind)
        if shadowed {
            let unit = pixelScale * hypot(context.ctm.a, context.ctm.b) / (deviceScale > 0 ? deviceScale : 1)
            context.setShadow(offset: CGSize(width: 0, height: -2 * unit), blur: 6 * unit, color: CGColor(gray: 0, alpha: 0.4))
            let reach = 10 * pixelScale
            context.beginTransparencyLayer(in: ObjectGeometry.bounds(of: object).insetBy(dx: -reach, dy: -reach), auxiliaryInfo: nil)
        }
        defer { if shadowed { context.endTransparencyLayer() } }
        // A translucent color is applied to the finished object as a whole, not to each of its parts, so parts that
        // overlap (an arrow's shaft and head) don't darken each other. The shadow stays outermost.
        let translucent = object.style.color.alpha < 1 && usesColorAlpha(object.kind)
        if translucent {
            context.saveGState()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setAlpha(object.style.color.alpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer {
            if translucent {
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
        let color = translucent ? object.style.color.withAlpha(1) : object.style.color
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch object.kind {
        case .rectangle(let rect):
            let inner = rect.insetBy(dx: width / 2, dy: width / 2)
            if inner.width > 0, inner.height > 0 {
                context.addPath(roundedRect(inner, radius: width))
                context.strokePath()
            } else {
                context.fill(rect)
            }
        case .filledRectangle(let rect):
            context.addPath(roundedRect(rect, radius: width))
            context.fillPath()
        case .ellipse(let rect):
            let inner = rect.insetBy(dx: width / 2, dy: width / 2)
            if inner.width > 0, inner.height > 0 {
                context.strokeEllipse(in: inner)
            } else {
                context.fillEllipse(in: rect)
            }
        case .line(let start, let end):
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        case .arrow(let arrow):
            let parts = ArrowGeometry.parts(for: arrow, width: width)
            context.addPath(parts.shaft)
            context.strokePath()
            for fill in parts.fills {
                context.addPath(fill)
                context.fillPath()
            }
        case .text(let text):
            drawText(text, color: color, in: context)
        case .redact(let redact):
            drawRedaction(redact, id: object.id, base: base, pixelScale: pixelScale, in: context, cache: cache)
        case .spotlight:
            break // Drawn together with the other spotlights.
        case .counter(let counter):
            drawCounter(counter, color: color, in: context)
        case .stroke(let stroke):
            context.addPath(StrokeSmoothing.path(through: stroke.points, smoothed: stroke.smoothed))
            context.strokePath()
        case .highlight(let highlight):
            context.setBlendMode(.multiply)
            let tint = color.withAlpha(highlight.opacity).cgColor
            if highlight.rects.isEmpty {
                context.setStrokeColor(tint)
                context.setLineWidth(highlight.width)
                context.addPath(StrokeSmoothing.path(through: highlight.points, smoothed: true))
                context.strokePath()
            } else {
                context.setFillColor(tint)
                for rect in highlight.rects {
                    context.addPath(roundedRect(rect, radius: min(4, rect.height / 4)))
                }
                context.fillPath()
            }
        case .image(let image):
            if let picture = images[image.image] {
                drawImage(picture, in: image.rect, context: context)
            }
        }
    }

    /// Only `objects`, on transparency, cropped to their bounds plus room for shadows ("Copy Object to Clipboard"). In
    /// base pixels, unaffected by image operations. Drawn in the canvas's order, so they stack as they do there.
    public static func renderObjects(_ objects: [AnnotationObject], document: AnnotationDocument, images: ImageStore) -> CGImage? {
        guard let first = objects.first else { return nil }
        let margin = 8 * document.pixelScale
        let bounds = objects.dropFirst().reduce(ObjectGeometry.bounds(of: first)) { $0.union(ObjectGeometry.bounds(of: $1)) }
            .insetBy(dx: -margin, dy: -margin).integral
        guard bounds.width > 0, bounds.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        let ids = Set(objects.map(\.id))
        let base = images[document.base]
        // The canvas's order (`AnnotationDocument.visualOrder`): redactions first, then everything else, counters last.
        // A spotlight draws nothing on its own.
        for object in document.visualOrder where ids.contains(object.id) {
            draw(object, pixelScale: document.pixelScale, base: base, images: images, in: context)
        }
        return context.makeImage()
    }

    /// Draws a CGImage right side up in a y-down context.
    public static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let rect = rect.standardized
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    // MARK: Pieces

    static func castsShadow(_ kind: ObjectKind) -> Bool {
        switch kind {
        case .redact, .spotlight, .highlight: false
        default: true
        }
    }

    /// Whether the style color's alpha is the object's opacity. The highlighter has its own opacity (and multiplies),
    /// redactions and spotlights have no color, and an image is drawn as it is.
    private static func usesColorAlpha(_ kind: ObjectKind) -> Bool {
        switch kind {
        case .highlight, .redact, .spotlight, .image: false
        default: true
        }
    }

    static func fillCanvas(_ document: AnnotationDocument, base: CGImage, canvas: CGRect, in context: CGContext, cache: RenderCache?) {
        let imageBounds = CGRect(origin: .zero, size: document.transform.outputSize)
        let expanded = !imageBounds.contains(canvas.insetBy(dx: 0.5, dy: 0.5))
        let fill: RGBAColor?
        switch document.canvasFill {
        case .transparent:
            fill = nil
        case .color(let color):
            fill = color
        case .auto:
            guard expanded else { return }
            if let cached = cache?.edgeColor, cached.base === base {
                fill = cached.color
            } else {
                let color = EdgeColor.dominant(in: base)
                cache?.edgeColor = (base, color)
                fill = color
            }
        }
        guard let fill else { return }
        context.setFillColor(fill.cgColor)
        context.fill(canvas)
    }

    /// Dims everything outside the spotlights, in one fill: the canvas and the union of the lit shapes make one path,
    /// and the even-odd rule leaves the lit shapes out, so overlapping spotlights light their union. The deepest
    /// dimming wins.
    static func drawSpotlights(_ objects: [AnnotationObject], covering coverage: CGRect, in context: CGContext) {
        let spotlights = objects.compactMap { object -> SpotlightObject? in
            if case .spotlight(let spotlight) = object.kind { spotlight } else { nil }
        }
        guard let first = spotlights.first, let opacity = spotlights.map(\.opacity).max() else { return }
        let lit = spotlights.dropFirst().reduce(ObjectGeometry.shapePath(of: first)) {
            $0.union(ObjectGeometry.shapePath(of: $1), using: .winding)
        }
        let path = CGMutablePath()
        path.addRect(coverage.insetBy(dx: -1, dy: -1))
        path.addPath(lit)
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: min(max(opacity, 0), 1)))
        context.addPath(path)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    static func roundedRect(_ rect: CGRect, radius: Double) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private static func drawText(_ text: TextObject, color: RGBAColor, in context: CGContext) {
        let frame = TextLayout.frame(of: text)
        if text.style.hasBox {
            let radius = text.style == .roundedBox ? frame.height / 2 : text.fontSize * 0.2
            context.setFillColor(color.cgColor)
            context.addPath(roundedRect(frame, radius: radius))
            context.fillPath()
        }
        guard !text.string.isEmpty else { return }
        let padding = TextLayout.padding(for: text.style, fontSize: text.fontSize)
        let textRect = frame.insetBy(dx: padding.width, dy: padding.height)
        let attributed = NSAttributedString(string: text.string, attributes: TextLayout.attributes(for: text, color: color))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        context.saveGState()
        // Core Text draws y-up: flip around the text box.
        context.translateBy(x: textRect.minX, y: textRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        // Exactly the measured width, so text wraps as `TextLayout` measured it. Core Text puts the first line at the top
        // of the path, so the extra point of height goes below (y is up here), keeping the last line from being clipped.
        let path = CGPath(rect: CGRect(x: 0, y: -1, width: textRect.width, height: textRect.height + 1), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
        context.restoreGState()
    }

    private static func drawCounter(_ counter: CounterObject, color: RGBAColor, in context: CGContext) {
        let rect = CGRect(x: counter.center.x - counter.diameter / 2, y: counter.center.y - counter.diameter / 2,
                          width: counter.diameter, height: counter.diameter)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)
        let label = CounterLabel.text(for: counter.value, style: counter.style)
        let font = NSFont.systemFont(ofSize: counter.diameter * (label.count > 2 ? 0.36 : 0.5), weight: .bold)
        let attributed = NSAttributedString(string: label, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.contrastingTextColor.cgColor,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.saveGState()
        context.translateBy(x: counter.center.x, y: counter.center.y)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// A redaction replaces what is under it. It never shows the original: if its effect can't be made, the region goes
    /// black instead (and the failure isn't cached, so the next frame tries again). It covers whole device pixels, drawn
    /// without antialiasing: after a resize op (or at a zoom) its edges fall between output pixels, and a blended edge
    /// pixel would mix in the picture beside it. The pixels beside it come from the redacted base (`drawBase`), so they
    /// mix in nothing of the original under it either. (With a background, redactions are drawn with the content instead:
    /// `drawRedactedContent`.)
    static func drawRedaction(_ redact: RedactObject, id: UUID, base: CGImage?, pixelScale: Double, in context: CGContext,
                              cache: RenderCache?) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(false)
        let black = CGColor(gray: 0, alpha: 1)
        guard redact.style != .blackOut, let base else {
            // Black out; or no base image to compute from, which is the same safe answer.
            context.setFillColor(black)
            context.fill(deviceAligned(redact.rect.standardized.integral, in: context))
            return
        }
        guard let (region, image) = redactionEffect(redact, id: id, base: base, pixelScale: pixelScale, cache: cache) else { return }
        let target = deviceAligned(region, in: context)
        if let image {
            // Replace, don't blend: wherever the effect is partly transparent, the original must not show through it.
            context.setBlendMode(.copy)
            drawImage(image, in: target, context: context)
        } else {
            context.setFillColor(black)
            context.fill(target)
        }
    }

    /// A redaction's region (its rect on the base, in whole base pixels) and its effect, from `cache` while nothing it is
    /// made from has changed: the object, the region, the base and the pixel scale. Nil when the redaction covers no base
    /// pixel. The image is nil when the effect can't be made; that isn't cached, so the next frame tries again.
    static func redactionEffect(_ redact: RedactObject, id: UUID, base: CGImage, pixelScale: Double,
                                cache: RenderCache?) -> (region: CGRect, image: CGImage?)? {
        let region = redact.rect.standardized.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height)).integral
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        let image: CGImage?
        if let cached = cache?.redactions[id], cached.object == redact, cached.region == region, cached.base === base,
           cached.pixelScale == pixelScale {
            image = cached.image
        } else {
            image = (cache?.effect ?? Redaction.image)(redact, region, base, pixelScale, id)
            cache?.redactions[id] = image.map {
                CachedRedaction(object: redact, region: region, base: base, pixelScale: pixelScale, image: $0)
            }
        }
        return (region, image)
    }

    /// The base with `redactions` drawn into a copy of it, at the base's own resolution, in drawing order: over each
    /// one's area in whole base pixels, its effect replaces the pixels, or black does (Black Out, or an effect that
    /// can't be made). So the original pixels under the redactions are in no bitmap that is drawn: wherever the base is
    /// drawn at a scale other than 1:1 (a resize op, a zoomed or Retina canvas), a pixel beside a redaction can only
    /// blend its effect with what lies beside it. The base itself when there are no redactions.
    ///
    /// Kept in `cache` while the base (by identity), the redactions (each with its id, which seeds its noise, and its value,
    /// in order) and the pixel scale are the ones it was made with. `complete` is false when an effect couldn't be made;
    /// such a copy isn't kept, so the next frame tries again. Nil when a bitmap can't be made: nothing of the base may then
    /// be drawn.
    static func redactedBase(_ base: CGImage, redactions: [RedactionKey], pixelScale: Double,
                             cache: RenderCache?) -> (image: CGImage, complete: Bool)? {
        guard !redactions.isEmpty else {
            cache?.redactedBase = nil
            return (base, true)
        }
        if let cached = cache?.redactedBase, cached.base === base, cached.redactions == redactions, cached.pixelScale == pixelScale {
            return (cached.image, true)
        }
        cache?.redactedBase = nil
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        guard let context = ImageOps.bitmapContext(width: base.width, height: base.height, preferring: base.colorSpace)
        else { return nil }
        context.draw(base, in: bounds)
        // Base pixels with y down, as the effects' regions are.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(false)
        // Replace, don't blend: wherever an effect is partly transparent, the original must not show through it.
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        var complete = true
        for redaction in redactions {
            if redaction.redact.style == .blackOut {
                let area = redaction.redact.rect.standardized.integral.intersection(bounds)
                if !area.isNull, !area.isEmpty { context.fill(area) }
                continue
            }
            guard let (region, image) = redactionEffect(redaction.redact, id: redaction.id, base: base, pixelScale: pixelScale,
                                                        cache: cache)
            else { continue }
            if let image {
                drawImage(image, in: region, context: context)
            } else {
                complete = false
                context.fill(region)
            }
        }
        // Drawn as the base is: interpolated or not, with its rendering intent.
        guard let drawn = context.makeImage(), let provider = drawn.dataProvider, let space = drawn.colorSpace,
              let image = CGImage(width: drawn.width, height: drawn.height, bitsPerComponent: drawn.bitsPerComponent,
                                  bitsPerPixel: drawn.bitsPerPixel, bytesPerRow: drawn.bytesPerRow, space: space,
                                  bitmapInfo: drawn.bitmapInfo, provider: provider, decode: nil,
                                  shouldInterpolate: base.shouldInterpolate, intent: base.renderingIntent)
        else { return nil }
        if complete {
            cache?.redactedBase = CachedRedactedBase(base: base, redactions: redactions, pixelScale: pixelScale, image: image)
        }
        return (image, complete)
    }

    /// The redacted base (`redactedBase`) where the base goes, through the image operations; the context in output
    /// pixels. Returns whether every effect was made; when the copy can't be made at all, nothing is drawn and it is
    /// false.
    @discardableResult
    static func drawBase(_ document: AnnotationDocument, base: CGImage, redactions: [RedactionKey], in context: CGContext,
                         cache: RenderCache?) -> Bool {
        guard let redacted = redactedBase(base, redactions: redactions, pixelScale: document.pixelScale, cache: cache)
        else { return false }
        context.saveGState()
        context.concatenate(document.transform.transform)
        drawImage(redacted.image, in: CGRect(origin: .zero, size: document.baseSize), context: context)
        context.restoreGState()
        return redacted.complete
    }

    /// `rect` grown outward to whole device pixels (the output's pixels in a bitmap, the backing's in a window).
    static func deviceAligned(_ rect: CGRect, in context: CGContext) -> CGRect {
        context.convertToUserSpace(context.convertToDeviceSpace(rect).integral)
    }
}
