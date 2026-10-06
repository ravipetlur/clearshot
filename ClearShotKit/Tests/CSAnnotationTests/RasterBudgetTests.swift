import AppKit
import CoreGraphics
import Testing
@testable import CSAnnotation

private func shadowedBox(_ rect: CGRect) -> AnnotationObject {
    AnnotationObject(kind: .filledRectangle(rect),
                     style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 4, shadow: true))
}

private func redaction(_ style: RedactStyle, _ rect: CGRect, intensity: Int = 5) -> AnnotationObject {
    AnnotationObject(kind: .redact(RedactObject(rect: rect, style: style, intensity: intensity)),
                     style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
}

/// Four coloured quarters, so a turn shows in the picture.
private func quarters(_ width: Int, _ height: Int) -> CGImage {
    TestBitmaps.quadrants(width, height, topLeft: TestBitmaps.red, topRight: TestBitmaps.green, bottomLeft: TestBitmaps.blue,
                          bottomRight: TestBitmaps.yellow)
}

/// A document over `base` with a background in `style` (the standard one: gradient, padding 64, shadow 50, corners 12).
private func backgrounded(_ base: CGImage, _ style: BackgroundStyle = .standard,
                          objects: [AnnotationObject] = []) -> (AnnotationDocument, ImageStore) {
    var (document, images) = TestBitmaps.document(base: base, objects: objects)
    document.background = DocumentBackground(style: style)
    return (document, images)
}

/// One canvas frame: `Renderer.draw` into a `size`-point context whose user space is points with y down, showing the
/// document from `origin` (output pixels) at `zoom`. A device scale of 2 is a Retina window's backing: twice the pixels, the
/// 2 in the context's base transform. With a cache, the canvas's rasters are used. `clip` (in the context's points) is the
/// part redrawn, as a canvas redraws a dirty rect.
private func canvasFrame(_ document: AnnotationDocument, _ images: ImageStore, cache: RenderCache?, size: CGSize,
                         origin: CGPoint, zoom: Double = 1, deviceScale: Double = 1, clip: CGRect? = nil) -> CGImage {
    func draw(in context: CGContext) {
        if let clip { context.clip(to: clip) }
        context.translateBy(x: -origin.x * zoom, y: -origin.y * zoom)
        context.scaleBy(x: zoom, y: zoom)
        Renderer.draw(document, images: images, in: context, cache: cache, deviceScale: deviceScale, useObjectCache: cache != nil)
    }
    if deviceScale == 1 {
        let context = TestBitmaps.flippedContext(Int(size.width), Int(size.height))
        draw(in: context)
        return context.makeImage()!
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * deviceScale),
                               pixelsHigh: Int(size.height * deviceScale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    draw(in: context)
    return rep.cgImage!
}

/// The document's whole output (the background's frame, or the canvas) as a canvas draws it at `zoom`.
private func wholeFrame(_ document: AnnotationDocument, _ images: ImageStore, cache: RenderCache?, zoom: Double = 1,
                        deviceScale: Double = 1) -> CGImage {
    let bounds = Renderer.outputBounds(of: document, images: images, cache: nil)
    let size = CGSize(width: (bounds.width * zoom).rounded(.up), height: (bounds.height * zoom).rounded(.up))
    return canvasFrame(document, images, cache: cache, size: size, origin: bounds.origin, zoom: zoom, deviceScale: deviceScale)
}

private func largestDifference(_ a: CGImage, _ b: CGImage) -> Int {
    zip(TestBitmaps.bytes(a), TestBitmaps.bytes(b)).map { abs(Int($0) - Int($1)) }.max() ?? 0
}

struct RasterBudgetTests {
    // MARK: Choosing what to drop

    @Test func evictionsTakeTheOldestFirst() {
        let entries: [(id: AnyHashable, bytes: Int, lastUsed: UInt64)] = [
            (id: AnyHashable("two"), bytes: 100, lastUsed: 2),
            (id: AnyHashable("one"), bytes: 100, lastUsed: 1),
            (id: AnyHashable("three"), bytes: 100, lastUsed: 3),
        ]
        // Room for two of them beside the new raster: only the one used longest ago goes.
        #expect(RasterBudget.evictions(of: entries, needed: 100, budget: 300, frame: 4) == [AnyHashable("one")])
        // Room for one of them: the two oldest, oldest first.
        #expect(RasterBudget.evictions(of: entries, needed: 100, budget: 200, frame: 4)
                    == [AnyHashable("one"), AnyHashable("two")])
        // Room for all of them: nothing goes.
        #expect(RasterBudget.evictions(of: entries, needed: 100, budget: 400, frame: 4) == [])
    }

    @Test func evictionsNeverTakeThisFramesRasters() {
        let entries: [(id: AnyHashable, bytes: Int, lastUsed: UInt64)] = [
            (id: AnyHashable("one"), bytes: 100, lastUsed: 4),
            (id: AnyHashable("two"), bytes: 100, lastUsed: 4),
        ]
        #expect(RasterBudget.evictions(of: entries, needed: 100, budget: 200, frame: 4) == nil)
        // An older one is taken, but dropping it alone isn't enough.
        let mixed = entries + [(id: AnyHashable("old"), bytes: 50, lastUsed: 3)]
        #expect(RasterBudget.evictions(of: mixed, needed: 100, budget: 200, frame: 4) == nil)
    }

    // MARK: The budget on the canvas

    @Test func aRasterThatWouldPassTheBudgetIsNotKept() {
        let base = TestBitmaps.solid(96, 64, TestBitmaps.white)
        let first = shadowedBox(CGRect(x: 8, y: 8, width: 30, height: 24))
        let second = shadowedBox(CGRect(x: 52, y: 30, width: 30, height: 24))
        // One object's raster, measured in a cache of its own.
        let (single, singleImages) = TestBitmaps.document(base: base, objects: [first])
        let probe = RenderCache()
        for _ in 0..<2 { _ = wholeFrame(single, singleImages, cache: probe) }
        let oneRaster = probe.rasterBytes
        #expect(oneRaster > 0)

        let (document, images) = TestBitmaps.document(base: base, objects: [first, second])
        let expected = wholeFrame(document, images, cache: nil)
        let cache = RenderCache()
        cache.rasterBudget = oneRaster * 3 / 2
        for index in 1...3 {
            #expect(largestDifference(wholeFrame(document, images, cache: cache), expected) <= 1, "frame \(index)")
        }
        #expect(cache.objectRasters.values.filter { $0.raster != nil }.count == 1)
        #expect(cache.rasterBytes <= cache.rasterBudget)
    }

    @Test func theBackgroundLayerIsKeptWhileItIsNotDrawnAndGoesFirstUnderPressure() throws {
        let box = shadowedBox(CGRect(x: 8, y: 8, width: 30, height: 24))
        var (document, images) = backgrounded(quarters(64, 48), objects: [box])
        let cache = RenderCache()
        for _ in 0..<2 { _ = wholeFrame(document, images, cache: cache) }
        let layer = try #require(cache.backgroundLayer?.raster?.image)
        let object = try #require(cache.objectRasters[box.id]?.raster?.image)
        // Without its background (as while cropping) the layer isn't drawn, but it stays.
        let background = document.background
        document.background = nil
        for _ in 0..<2 { _ = wholeFrame(document, images, cache: cache) }
        #expect(cache.backgroundLayer?.raster?.image === layer)
        #expect(cache.objectRasters[box.id]?.raster?.image === object)
        // A new raster that needs the room takes the layer's, not the object's that this frame drew.
        let other = shadowedBox(CGRect(x: 20, y: 20, width: 30, height: 24))
        document.objects = [box, other]
        cache.rasterBudget = cache.rasterBytes
        let expected = wholeFrame(document, images, cache: nil)
        for index in 1...2 {
            #expect(largestDifference(wholeFrame(document, images, cache: cache), expected) <= 1, "frame \(index)")
        }
        #expect(cache.backgroundLayer?.raster == nil)
        #expect(cache.backgroundLayer != nil)
        #expect(cache.objectRasters[box.id]?.raster?.image === object)
        #expect(cache.objectRasters[other.id]?.raster != nil)
        // With the background back and room in the budget, the layer's entry, still there and seen once, is made again at once.
        document.background = background
        cache.rasterBudget = 268_435_456
        _ = wholeFrame(document, images, cache: cache)
        #expect(cache.backgroundLayer?.raster != nil)
    }

    // MARK: The background layer

    @Test func theBackgroundLayerIsReusedWhileObjectsChange() throws {
        var box = shadowedBox(CGRect(x: 8, y: 8, width: 30, height: 24))
        var (document, images) = backgrounded(quarters(64, 48), objects: [box])
        let cache = RenderCache()
        _ = wholeFrame(document, images, cache: cache)
        // Seen once: drawn directly.
        #expect(cache.backgroundLayer != nil)
        #expect(cache.backgroundLayer?.raster == nil)
        _ = wholeFrame(document, images, cache: cache)
        let layer = try #require(cache.backgroundLayer?.raster?.image)
        box.kind = .filledRectangle(CGRect(x: 20, y: 14, width: 30, height: 24))
        document.objects = [box]
        let expected = wholeFrame(document, images, cache: nil)
        #expect(largestDifference(wholeFrame(document, images, cache: cache), expected) <= 1)
        #expect(cache.backgroundLayer?.raster?.image === layer)
    }

    @Test func theBackgroundLayerCoversTheWholeFrameWhateverTheCanvasRedraws() {
        let (document, images) = backgrounded(quarters(64, 48))
        let bounds = Renderer.outputBounds(of: document, images: images, cache: nil)
        let cache = RenderCache()
        // Two frames that redraw only the left half, as a canvas redraws a dirty rect: the second makes the layer.
        let left = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        for _ in 0..<2 { _ = canvasFrame(document, images, cache: cache, size: bounds.size, origin: bounds.origin, clip: left) }
        #expect(cache.backgroundLayer?.raster != nil)
        // The whole frame, the right half included, from that raster.
        let expected = wholeFrame(document, images, cache: nil)
        #expect(largestDifference(wholeFrame(document, images, cache: cache), expected) <= 1)
    }

    @Test func aStyleChangeRebuildsTheBackgroundLayer() throws {
        var (document, images) = backgrounded(quarters(64, 48))
        let cache = RenderCache()
        for _ in 0..<2 { _ = wholeFrame(document, images, cache: cache) }
        let layer = try #require(cache.backgroundLayer?.raster?.image)
        document.background?.style.padding = 65
        let expected = wholeFrame(document, images, cache: nil)
        for index in 1...3 {
            #expect(largestDifference(wholeFrame(document, images, cache: cache), expected) <= 1, "frame \(index)")
            #expect((cache.backgroundLayer?.raster != nil) == (index >= 2), "frame \(index)")
        }
        let rebuilt = try #require(cache.backgroundLayer?.raster?.image)
        #expect(rebuilt !== layer)
    }

    @Test func aNewPictureRebuildsIt() throws {
        let ref = ImageRef(name: "images/background.png")
        var style = BackgroundStyle.standard
        style.fill = .desktop
        var (document, images) = TestBitmaps.document(base: quarters(64, 48))
        document.background = DocumentBackground(style: style, image: ref)
        images.set(TestBitmaps.solid(40, 30, TestBitmaps.red), for: ref)
        let cache = RenderCache()
        for _ in 0..<2 { _ = wholeFrame(document, images, cache: cache) }
        let layer = try #require(cache.backgroundLayer?.raster?.image)
        // The same style, another stored picture (a desktop picture resolved again).
        images.set(TestBitmaps.solid(40, 30, TestBitmaps.blue), for: ref)
        let expected = wholeFrame(document, images, cache: nil)
        #expect(TestBitmaps.pixel(expected, 2, 2) == .init(r: 0, g: 0, b: 255, a: 255))
        for index in 1...3 {
            #expect(largestDifference(wholeFrame(document, images, cache: cache), expected) <= 1, "frame \(index)")
        }
        let rebuilt = try #require(cache.backgroundLayer?.raster?.image)
        #expect(rebuilt !== layer)
    }

    @Test func aRedactionChangeRebuildsTheBackgroundLayer() throws {
        var hidden = redaction(.pixelate, CGRect(x: 6, y: 6, width: 24, height: 18))
        var (document, images) = backgrounded(TestBitmaps.noise(64, 48), objects: [hidden])
        let cache = RenderCache()
        /// Three frames of the current document, each like an uncached one; the layer from the last.
        func layer(after change: String) throws -> CGImage {
            let expected = wholeFrame(document, images, cache: nil)
            for index in 1...3 {
                #expect(largestDifference(wholeFrame(document, images, cache: cache), expected) <= 1, "\(change), frame \(index)")
            }
            return try #require(cache.backgroundLayer?.raster?.image)
        }
        let first = try layer(after: "the first draw")
        hidden.kind = .redact(RedactObject(rect: CGRect(x: 20, y: 14, width: 24, height: 18), style: .pixelate, intensity: 5))
        document.objects = [hidden]
        let moved = try layer(after: "a move")
        #expect(moved !== first)
        hidden.kind = .redact(RedactObject(rect: CGRect(x: 20, y: 14, width: 24, height: 18), style: .pixelate, intensity: 9))
        document.objects = [hidden]
        let restyled = try layer(after: "a restyle")
        #expect(restyled !== moved)
    }

    @Test func aRedactionWhoseEffectFailedIsNotKeptInTheBackgroundLayer() {
        let hidden = redaction(.pixelate, CGRect(x: 6, y: 6, width: 24, height: 18))
        let (document, images) = backgrounded(TestBitmaps.noise(64, 48), objects: [hidden])
        let cache = RenderCache()
        // The effect can't be made: the redaction is black, and that isn't kept.
        cache.effect = { _, _, _, _, _ in nil }
        for _ in 0..<3 { _ = wholeFrame(document, images, cache: cache) }
        #expect(cache.backgroundLayer?.raster == nil)
        // Once it can, the next frame shows it.
        cache.effect = Redaction.image
        let expected = wholeFrame(document, images, cache: nil)
        #expect(largestDifference(wholeFrame(document, images, cache: cache), expected) <= 1)
        #expect(cache.backgroundLayer?.raster != nil)
    }

    @Test(arguments: [1.0, 2.0, 0.37], [[ImageOp](), [.rotateRight]])
    func aCachedBackgroundFrameMatchesAnUncachedOne(zoom: Double, ops: [ImageOp]) {
        let box = shadowedBox(CGRect(x: 8, y: 8, width: 30, height: 20))
        let hidden = redaction(.pixelate, CGRect(x: 30, y: 20, width: 20, height: 16))
        var (document, images) = backgrounded(quarters(56, 40), objects: [box, hidden])
        document.imageOps = ops
        let expected = wholeFrame(document, images, cache: nil, zoom: zoom, deviceScale: 2)
        let cache = RenderCache()
        // The direct frame, the one that makes the rasters, and one drawn from them.
        for index in 1...3 {
            let actual = wholeFrame(document, images, cache: cache, zoom: zoom, deviceScale: 2)
            #expect(largestDifference(actual, expected) <= 1, "frame \(index)")
        }
        #expect(cache.backgroundLayer?.raster != nil)
        #expect(cache.objectRasters[box.id]?.raster != nil)
    }

    @Test func theBackgroundLayerCountsInTheBudget() throws {
        let box = shadowedBox(CGRect(x: 8, y: 8, width: 30, height: 24))
        let (document, images) = backgrounded(quarters(64, 48), objects: [box])
        let cache = RenderCache()
        for _ in 0..<2 { _ = wholeFrame(document, images, cache: cache) }
        let layer = try #require(cache.backgroundLayer?.raster?.image)
        let object = try #require(cache.objectRasters[box.id]?.raster?.image)
        #expect(cache.rasterBytes == 4 * (layer.width * layer.height + object.width * object.height))
    }

    @Test func aLayerOverSixteenMegapixelsIsDrawnDirectly() {
        // A 192 × 192 frame at 25×: 4800 pixels a side, over the 16-megapixel cap. The context is small and shows the frame's
        // bottom-right corner.
        let (document, images) = backgrounded(quarters(64, 64))
        let size = CGSize(width: 64, height: 64), origin = CGPoint(x: 128 - 64.0 / 25, y: 128 - 64.0 / 25)
        let expected = canvasFrame(document, images, cache: nil, size: size, origin: origin, zoom: 25)
        let cache = RenderCache()
        for index in 1...3 {
            let actual = canvasFrame(document, images, cache: cache, size: size, origin: origin, zoom: 25)
            #expect(largestDifference(actual, expected) <= 1, "frame \(index)")
            #expect(cache.backgroundLayer?.raster == nil, "frame \(index)")
        }
        #expect(cache.rasterBytes == 0)
    }
}
