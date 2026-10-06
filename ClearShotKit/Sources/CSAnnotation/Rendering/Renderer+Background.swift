import CoreGraphics
import CSCapture
import Foundation

/// What the background takes from the content: auto-balance's trims (`.zero` when it is off) and the blurred screenshot
/// (nil unless the fill is Blurred screenshot).
struct ContentAnalysis {
    var trims: EdgeTrims
    var blurred: CGImage?
}

/// What a background draws under the objects (steps 1 and 2 of `Renderer.drawBackgrounded`), with what it is drawn from.
struct BackgroundLayer {
    var document: AnnotationDocument
    var background: DocumentBackground
    var layout: BackgroundLayout
    /// Auto-balance's trims, which `layout` was made with.
    var trims: EdgeTrims
    /// What the fill shows: the stored picture of an image-backed fill, or the blurred screenshot.
    var picture: CGImage?
    var base: CGImage
    /// The redactions drawn with the content, in drawing order.
    var redactions: [AnnotationObject]
}

extension Renderer {
    // MARK: The content

    /// The canvas as rendered without any objects, redactions included, and without the background: the base after its
    /// image operations, over the canvas fill, cut to the canvas. It is exactly the canvas (`canvasBounds`), so the trims
    /// auto-balance measures in its pixels apply from the canvas's origin. (The blurred screenshot is made from the content
    /// with its redactions instead, `redactedContent`, so it never shows what they hide.)
    public static func renderContent(_ document: AnnotationDocument, images: ImageStore) -> CGImage? {
        var content = document
        content.objects = []
        content.background = nil
        return render(content, images: images)
    }

    /// Auto-balance's trims for the document's background: `.zero` unless the background has auto-balance on. Measured on
    /// `renderContent` and kept in `cache` while the content is unchanged; measured every time without a cache.
    public static func balanceTrims(for document: AnnotationDocument, images: ImageStore, cache: RenderCache?) -> EdgeTrims {
        guard document.background?.style.autoBalance == true else { return .zero }
        return contentAnalysis(for: document, images: images, cache: cache, trims: true, blurred: false).trims
    }

    /// What the document renders, in output pixels: the background's frame, with auto-balance's trims when it has them, or
    /// the canvas without a background (`AnnotationDocument.outputBounds(trims:)`). Renders nothing unless auto-balance is
    /// on.
    public static func outputBounds(of document: AnnotationDocument, images: ImageStore, cache: RenderCache?) -> CGRect {
        document.outputBounds(trims: balanceTrims(for: document, images: images, cache: cache))
    }

    /// Everything the document's background takes from the content.
    static func contentAnalysis(for document: AnnotationDocument, images: ImageStore, cache: RenderCache?) -> ContentAnalysis {
        guard let style = document.background?.style else { return ContentAnalysis(trims: .zero) }
        let blurred = if case .blurredScreenshot = style.fill { true } else { false }
        return contentAnalysis(for: document, images: images, cache: cache, trims: style.autoBalance, blurred: blurred)
    }

    /// The trims and the blurred content asked for. The trims are measured on the content without its redactions
    /// (`renderContent`); the blur is made from the content with them (`redactedContent`), or from the same render when
    /// there are none. The cache's entry for this content supplies what it has (the blur only while the redactions and the
    /// pixel scale are the ones it was made with); what it lacks is made and kept in it. A content render that fails isn't
    /// remembered, so the next call tries again.
    private static func contentAnalysis(for document: AnnotationDocument, images: ImageStore, cache: RenderCache?,
                                        trims wantsTrims: Bool, blurred wantsBlurred: Bool) -> ContentAnalysis {
        guard wantsTrims || wantsBlurred, let base = images[document.base] else { return ContentAnalysis(trims: .zero) }
        var entry = cache?.contentAnalysis.flatMap { $0.isFor(document, base: base) ? $0 : nil }
            ?? CachedContentAnalysis(base: base, imageOps: document.imageOps, canvasBounds: document.canvasBounds,
                                     canvasFill: document.canvasFill)
        let redactions = RedactionKey.all(in: document.visualOrder)
        let blurIsCurrent = entry.blur.map { $0.redactions == redactions && $0.pixelScale == document.pixelScale } ?? false
        let needsTrims = wantsTrims && entry.trims == nil
        let needsBlurred = wantsBlurred && !blurIsCurrent
        // A blur made under other redactions is never shown, even when a new one can't be made.
        if needsBlurred { entry.blur = nil }
        let content = needsTrims || (needsBlurred && redactions.isEmpty) ? renderContent(document, images: images) : nil
        if needsTrims, let content { entry.trims = AutoBalance.trims(of: content) }
        if needsBlurred,
           let source = redactions.isEmpty ? content : redactedContent(document, base: base, redactions: redactions, cache: cache),
           let image = BackgroundBlur.blurred(source) {
            entry.blur = CachedBlur(redactions: redactions, pixelScale: document.pixelScale, image: image)
        }
        cache?.contentAnalysis = entry
        return ContentAnalysis(trims: wantsTrims ? entry.trims ?? .zero : .zero, blurred: wantsBlurred ? entry.blur?.image : nil)
    }

    /// The content (`renderContent`) with `redactions`, as `draw` draws it without a background: the canvas fill, the base
    /// with the redactions in it (`drawBase`), and each redaction over that, replacing whole output pixels. So no pixel of
    /// it samples what a redaction hides. Nil if the canvas can't be drawn or a bitmap can't be made.
    private static func redactedContent(_ document: AnnotationDocument, base: CGImage, redactions: [RedactionKey],
                                        cache: RenderCache?) -> CGImage? {
        let bounds = document.canvasBounds
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) else { return nil }
        let canvas = bounds.integral
        guard canvas.width >= 1, canvas.height >= 1, canvas.width <= AnnotationDocument.maximumSide,
              canvas.height <= AnnotationDocument.maximumSide,
              let context = ImageOps.bitmapContext(width: Int(canvas.width), height: Int(canvas.height), preferring: base.colorSpace)
        else { return nil }
        // As `render` sets it up: output pixels with y down, from the canvas's origin.
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -canvas.minX, y: -canvas.minY)
        fillCanvas(document, base: base, canvas: bounds, in: context, cache: cache)
        drawBase(document, base: base, redactions: redactions, in: context, cache: cache)
        context.concatenate(document.transform.transform)
        for redaction in redactions {
            drawRedaction(redaction.redact, id: redaction.id, base: base, pixelScale: document.pixelScale, in: context, cache: cache)
        }
        return context.makeImage()
    }

    // MARK: Drawing

    /// `draw(_:images:in:…)` for a document with a background, in the context's output pixels:
    /// 1. the fill over the frame;
    /// 2. the box in a transparency layer, cut to its rounded corners: the inset colour, then the content with its
    ///    redactions (`drawRedactedContent`). The shadow is the layer's, so it follows the layer's alpha: a transparent
    ///    window shot casts its own shape, and a redaction casts its own;
    /// 3. the other objects on top, as without a background, cut to the frame. Spotlights dim the whole frame.
    ///
    /// Steps 1 and 2 are the background's layer (`BackgroundLayer`), which the canvas (`useObjectCache`) draws from a
    /// raster kept in `cache`. `analysis` is the content's, when the caller has measured it already.
    static func drawBackgrounded(_ document: AnnotationDocument, background: DocumentBackground, analysis: ContentAnalysis? = nil,
                                 images: ImageStore, in context: CGContext, cache: RenderCache?, hiding hidden: Set<UUID>,
                                 deviceScale: Double, useObjectCache: Bool) {
        guard let base = images[document.base] else { return }
        let analysis = analysis ?? contentAnalysis(for: document, images: images, cache: cache)
        guard let layout = document.backgroundLayout(trims: analysis.trims) else { return }
        let fill = background.style.fill
        let picture: CGImage? = if case .blurredScreenshot = fill {
            analysis.blurred
        } else if fill.isImageBacked {
            background.image.flatMap { images[$0] }
        } else {
            nil
        }
        // The document's visual order: redactions first, which are drawn with the content.
        let objects = document.visualOrder.filter { !hidden.contains($0.id) }
        let layer = BackgroundLayer(document: document, background: background, layout: layout, trims: analysis.trims,
                                    picture: picture, base: base,
                                    redactions: objects.filter { if case .redact = $0.kind { true } else { false } })

        context.saveGState()
        if useObjectCache, let cache {
            drawCached(layer, in: context, cache: cache, deviceScale: deviceScale)
        } else {
            draw(layer, in: context, cache: cache, deviceScale: deviceScale)
        }
        // Only now cut to the frame: the layer cuts itself, and its raster, already cut, would be cut twice where the
        // frame's edge falls between device pixels.
        context.clip(to: layout.frame)
        context.concatenate(document.transform.transform)
        var spotlightsDrawn = false
        for object in objects {
            switch object.kind {
            case .redact:
                continue // Drawn with the content.
            case .spotlight:
                // All the spotlights dim together, over the whole frame, where the first of them comes in the order.
                if !spotlightsDrawn { drawSpotlights(objects, covering: layout.frame.applying(document.transform.inverse), in: context) }
                spotlightsDrawn = true
            default:
                if useObjectCache, let cache, object.style.shadow, castsShadow(object.kind) {
                    drawCached(object, pixelScale: document.pixelScale, base: base, images: images, in: context, cache: cache,
                               deviceScale: deviceScale)
                } else {
                    draw(object, pixelScale: document.pixelScale, base: base, images: images, in: context, cache: cache,
                         deviceScale: deviceScale)
                }
            }
        }
        context.restoreGState()
        if let cache { prune(cache, document: document, drawn: objects) }
    }

    /// Steps 1 and 2 of `drawBackgrounded`, cut to the frame, in the context's output pixels: the fill, then the box in
    /// its shadowed transparency layer with the inset colour and the content with its redactions. The context's state
    /// is as it was afterwards, so the objects never cast the box's shadow. `deviceScale` is the context's, as for
    /// `draw`. Returns whether every redaction's effect was made (`drawRedactedContent`).
    @discardableResult
    static func draw(_ layer: BackgroundLayer, in context: CGContext, cache: RenderCache?, deviceScale: Double) -> Bool {
        let style = layer.background.style
        let layout = layer.layout
        let shadow = style.shadow.isFinite ? min(style.shadow, BackgroundStyle.shadowRange.upperBound) : 0
        // The object shadows' unit (`draw(_:pixelScale:…)`), taken here in output pixels: a point of the style is
        // `backgroundScale` of them.
        let unit = layer.document.backgroundScale * hypot(context.ctm.a, context.ctm.b) / (deviceScale > 0 ? deviceScale : 1)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: layout.frame)
        drawFill(style.fill, picture: layer.picture, in: layout.frame, context: context)
        if shadow > 0 {
            context.setShadow(offset: CGSize(width: 0, height: -0.2 * shadow * unit), blur: 0.5 * shadow * unit,
                              color: CGColor(gray: 0, alpha: 0.25 + 0.003 * shadow))
        }
        context.beginTransparencyLayer(in: layout.frame, auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(roundedRect(layout.box, radius: layout.cornerRadius))
        context.clip()
        if layout.inset > 0 {
            context.setFillColor(insetColor(style.insetColor, base: layer.base, cache: cache).cgColor)
            context.fill(layout.box)
        }
        context.clip(to: layout.content)
        return drawRedactedContent(layer.document, base: layer.base, redactions: layer.redactions, in: context, cache: cache)
    }

    /// The content with its redactions, in the box's layer: the context is in output pixels, already cut to the box and
    /// the content. No original pixel is ever drawn under a redaction: the canvas fill and the base are kept off each
    /// redaction's whole device pixels, and its effect, or black (Black Out, or an effect that can't be made), is drawn
    /// there with the normal blend over what lies under the content, the inset colour or nothing. So the antialiased
    /// edges of the box's corners, and of a canvas that falls between output pixels, blend a redaction only with the
    /// backdrop. The base drawn around them is the redacted one (`drawBase`), so the pixels beside a redaction sample
    /// nothing of what it hides at any scale either. Returns false when an effect couldn't be made (and was drawn
    /// black).
    private static func drawRedactedContent(_ document: AnnotationDocument, base: CGImage, redactions: [AnnotationObject],
                                            in context: CGContext, cache: RenderCache?) -> Bool {
        let baseToOutput = document.transform.transform
        // Each redaction's area on whole device pixels, in base pixels where it is drawn, and its effect (nil for black).
        context.saveGState()
        context.concatenate(baseToOutput)
        var complete = true
        let covers = redactions.compactMap { object -> (target: CGRect, effect: CGImage?)? in
            guard case .redact(let redact) = object.kind else { return nil }
            guard redact.style != .blackOut else { return (deviceAligned(redact.rect.standardized.integral, in: context), nil) }
            guard let effect = redactionEffect(redact, id: object.id, base: base, pixelScale: document.pixelScale, cache: cache)
            else { return nil }
            if effect.image == nil { complete = false }
            return (deviceAligned(effect.region, in: context), effect.image)
        }
        context.restoreGState()

        context.saveGState()
        // One clip per redaction, each leaving its area out (even-odd between it and a rect around everything drawn), on
        // whole device pixels.
        let everything = context.boundingBoxOfClipPath.insetBy(dx: -1, dy: -1)
        context.setShouldAntialias(false)
        for cover in covers {
            context.addRect(everything)
            context.addRect(cover.target.applying(baseToOutput))
            context.clip(using: .evenOdd)
        }
        context.setShouldAntialias(true)
        fillCanvas(document, base: base, canvas: document.canvasBounds, in: context, cache: cache)
        if !drawBase(document, base: base, redactions: RedactionKey.all(in: redactions), in: context, cache: cache) {
            complete = false
        }
        context.restoreGState()

        guard !covers.isEmpty else { return true }
        context.saveGState()
        context.concatenate(baseToOutput)
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for cover in covers {
            if let effect = cover.effect {
                drawImage(effect, in: cover.target, context: context)
            } else {
                context.fill(cover.target)
            }
        }
        context.restoreGState()
        return complete
    }

    /// The cache after a frame, as `draw` keeps it without a background: removed redactions lose their images, and objects
    /// that are gone, hidden or no longer shadowed lose their rasters.
    private static func prune(_ cache: RenderCache, document: AnnotationDocument, drawn objects: [AnnotationObject]) {
        let live = Set(document.objects.map(\.id))
        if cache.redactions.keys.contains(where: { !live.contains($0) }) {
            cache.redactions = cache.redactions.filter { live.contains($0.key) }
        }
        if !cache.objectRasters.isEmpty {
            let shadowed = Set(objects.lazy.filter(\.style.shadow).map(\.id))
            if cache.objectRasters.keys.contains(where: { !shadowed.contains($0) }) {
                cache.objectRasters = cache.objectRasters.filter { shadowed.contains($0.key) }
            }
        }
    }

    /// The inset's colour: the picture's edge colour (`EdgeColor`, kept in `cache`) for Auto.
    private static func insetColor(_ color: InsetColor, base: CGImage, cache: RenderCache?) -> RGBAColor {
        switch color {
        case .color(let color):
            return color
        case .auto:
            if let cached = cache?.edgeColor, cached.base === base { return cached.color }
            let color = EdgeColor.dominant(in: base)
            cache?.edgeColor = (base, color)
            return color
        }
    }

    // MARK: Fills

    /// `fill` over `frame`. `picture` is what an image-backed fill or the blurred screenshot shows: aspect-filled over the
    /// frame. `.none`, and a fill whose picture is missing, draw nothing.
    static func drawFill(_ fill: BackgroundFill, picture: CGImage?, in frame: CGRect, context: CGContext) {
        switch fill {
        case .none:
            break
        case .color(let color):
            context.setFillColor(color.cgColor)
            context.fill(frame)
        case .gradient(let gradient):
            drawGradient(gradient, in: frame, context: context)
        case .desktop, .blurredDesktop, .systemWallpaper, .custom, .windowWallpaper, .blurredScreenshot:
            guard let picture else { return }
            context.saveGState()
            context.interpolationQuality = .high
            drawImage(picture, in: aspectFill(CGSize(width: picture.width, height: picture.height), in: frame), context: context)
            context.restoreGState()
        }
    }

    /// A gradient over `frame`, in sRGB (colour-managed into the context's space). Linear runs at its angle across the
    /// whole frame: from the centre, half the frame's extent along that direction each way, and on past both ends. Radial
    /// runs from the centre to the corners, and on past them. A gradient without stops draws nothing.
    static func drawGradient(_ gradient: BackgroundGradient, in frame: CGRect, context: CGContext) {
        guard !gradient.stops.isEmpty, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let components = gradient.stops.flatMap { [$0.color.red, $0.color.green, $0.color.blue, $0.color.alpha].map { CGFloat($0) } }
        let locations = gradient.stops.map { CGFloat($0.location) }
        guard let cgGradient = CGGradient(colorSpace: space, colorComponents: components, locations: locations,
                                          count: locations.count)
        else { return }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        switch gradient.kind {
        case .linear(let angle):
            let radians = angle * .pi / 180
            let direction = (x: cos(radians), y: sin(radians))
            let half = (abs(frame.width * direction.x) + abs(frame.height * direction.y)) / 2
            context.drawLinearGradient(cgGradient, start: CGPoint(x: centre.x - half * direction.x, y: centre.y - half * direction.y),
                                       end: CGPoint(x: centre.x + half * direction.x, y: centre.y + half * direction.y),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial:
            context.drawRadialGradient(cgGradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                       endRadius: hypot(frame.width, frame.height) / 2, options: .drawsAfterEndLocation)
        }
    }

    /// The rect `size` takes to cover `target`, centred, keeping its proportions (as `PostProcessor.compositingWindow`
    /// places a window's wallpaper).
    static func aspectFill(_ size: CGSize, in target: CGRect) -> CGRect {
        let factor = max(target.width / size.width, target.height / size.height)
        let fitted = CGSize(width: size.width * factor, height: size.height * factor)
        return CGRect(x: target.midX - fitted.width / 2, y: target.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}
