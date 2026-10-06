import AppKit
import CoreGraphics
import Testing
@testable import CSAnnotation

private let redColor = RGBAColor(red: 1, green: 0, blue: 0)
private let blueColor = RGBAColor(red: 0, green: 0, blue: 1)

private func shape(_ kind: ObjectKind, color: RGBAColor = redColor, width: Double = 4, shadow: Bool = false) -> AnnotationObject {
    AnnotationObject(kind: kind, style: ObjectStyle(color: color, lineWidth: width, shadow: shadow))
}

private func render(_ document: AnnotationDocument, _ images: ImageStore) throws -> CGImage {
    try #require(Renderer.render(document, images: images))
}

struct RendererBaseTests {
    @Test func rendersTheBaseUnchanged() throws {
        let (document, images) = TestBitmaps.document(base: TestBitmaps.solid(40, 30, TestBitmaps.blue))
        let image = try render(document, images)
        #expect(image.width == 40)
        #expect(image.height == 30)
        #expect(TestBitmaps.pixel(image, 5, 5) == .init(r: 0, g: 0, b: 255, a: 255))
    }

    @Test func rotateRightTurnsTheWholePicture() throws {
        var (document, images) = TestBitmaps.document(base: TestBitmaps.split(40, 20, left: TestBitmaps.red, right: TestBitmaps.blue))
        document.imageOps = [.rotateRight]
        let image = try render(document, images)
        #expect(image.width == 20)
        #expect(image.height == 40)
        #expect(TestBitmaps.pixel(image, 10, 5) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 10, 35) == .init(r: 0, g: 0, b: 255, a: 255))
    }

    @Test func anExpandedCanvasFillsWithTheEdgeColor() throws {
        var (document, images) = TestBitmaps.document(base: TestBitmaps.solid(40, 40, TestBitmaps.blue))
        document.canvasRect = CGRect(x: -10, y: -10, width: 60, height: 60)
        let auto = try render(document, images)
        #expect(auto.width == 60)
        #expect(TestBitmaps.pixel(auto, 2, 2) == .init(r: 0, g: 0, b: 255, a: 255))
        document.canvasFill = .transparent
        #expect(TestBitmaps.pixel(try render(document, images), 2, 2).a == 0)
        document.canvasFill = .color(redColor)
        #expect(TestBitmaps.pixel(try render(document, images), 2, 2) == .init(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func aBaseInAnExtendedColorSpaceStillRenders() throws {
        // HDR captures are float extended sRGB, which an 8-bit bitmap context can't be made in; the canvas falls back to sRGB.
        let hdr = TestBitmaps.extendedSRGB(20, 10, TestBitmaps.blue)
        #expect(hdr.colorSpace?.model == .rgb)
        let (document, images) = TestBitmaps.document(base: hdr)
        let image = try render(document, images)
        #expect(image.width == 20)
        #expect(TestBitmaps.pixel(image, 5, 5) == .init(r: 0, g: 0, b: 255, a: 255))
    }

    @Test func absurdCanvasSizesAreRefused() throws {
        var (document, images) = TestBitmaps.document(base: TestBitmaps.solid(40, 40, TestBitmaps.blue))
        for canvas in [CGRect(x: 0, y: 0, width: 40_000, height: 10), CGRect(x: 0, y: 0, width: 10, height: 32_769),
                       CGRect(x: 0, y: 0, width: Double.infinity, height: 10), CGRect(x: 0, y: 0, width: Double.nan, height: 10)] {
            document.canvasRect = canvas
            #expect(Renderer.render(document, images: images) == nil)
        }
        // The limit itself is fine.
        document.canvasRect = CGRect(x: -100, y: 0, width: 32_768, height: 4)
        let widest = try render(document, images)
        #expect(widest.width == 32_768)
    }

    @Test func edgeColorTiesGoToTheLowestBucket() {
        // Half the border is red and half blue, a tie. The answer is fixed (blue's bucket sorts lower), not whichever
        // the dictionary happens to list last.
        let image = TestBitmaps.split(64, 64, left: TestBitmaps.red, right: TestBitmaps.blue)
        let color = EdgeColor.dominant(in: image)
        #expect(color.blue > 0.9)
        #expect(color.red < 0.1)
    }

    @Test func edgeColorIsTheBordersMostCommonColor() {
        let image = TestBitmaps.bordered(100, border: 4, edge: TestBitmaps.blue, inside: TestBitmaps.red)
        let color = EdgeColor.dominant(in: image)
        #expect(color.blue > 0.9)
        #expect(color.red < 0.1)
    }
}

struct RendererShapeTests {
    let base = TestBitmaps.solid(60, 60, TestBitmaps.white)

    @Test func filledRectanglesFillTheirRect() throws {
        let (document, images) = TestBitmaps.document(base: base, objects: [shape(.filledRectangle(CGRect(x: 10, y: 10, width: 20, height: 20)))])
        #expect(TestBitmaps.pixel(try render(document, images), 20, 20) == .init(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func outlineRectanglesPaintOnlyTheirEdge() throws {
        let (document, images) = TestBitmaps.document(base: base, objects: [shape(.rectangle(CGRect(x: 10, y: 10, width: 40, height: 40)))])
        let image = try render(document, images)
        #expect(TestBitmaps.pixel(image, 30, 12) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 30, 30) == .init(r: 255, g: 255, b: 255, a: 255))
    }

    @Test func linesPaintAlongTheirPath() throws {
        let (document, images) = TestBitmaps.document(base: base, objects: [shape(.line(start: CGPoint(x: 5, y: 30), end: CGPoint(x: 55, y: 30)))])
        #expect(TestBitmaps.pixel(try render(document, images), 30, 30) == .init(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func arrowHeadsAreFilled() throws {
        let arrow = shape(.arrow(ArrowShape(start: CGPoint(x: 5, y: 30), end: CGPoint(x: 55, y: 30), style: .standard)))
        let (document, images) = TestBitmaps.document(base: base, objects: [arrow])
        // Inside the head: at width 4 the head is 14 long, so it spans x 41...55, and the shaft with its round cap stops
        // at x = 41.
        #expect(TestBitmaps.pixel(try render(document, images), 49, 30) == .init(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func countersAreCirclesThatStayOnTop() throws {
        let counter = shape(.counter(CounterObject(center: CGPoint(x: 30, y: 30), value: 1, style: .numbers, diameter: 40)), color: blueColor)
        let cover = shape(.filledRectangle(CGRect(x: 0, y: 0, width: 60, height: 60)))
        let (document, images) = TestBitmaps.document(base: base, objects: [counter, cover])
        // Inside the circle, left of the label.
        #expect(TestBitmaps.pixel(try render(document, images), 14, 30) == .init(r: 0, g: 0, b: 255, a: 255))
    }

    @Test func imageObjectsDrawTheirImage() throws {
        var (document, images) = TestBitmaps.document(base: base,
                                                      objects: [shape(.image(ImageObject(rect: CGRect(x: 20, y: 20, width: 10, height: 10),
                                                                                         image: ImageRef(name: "images/a.png"))))])
        images.set(TestBitmaps.solid(4, 4, TestBitmaps.blue), for: ImageRef(name: "images/a.png"))
        #expect(TestBitmaps.pixel(try render(document, images), 25, 25) == .init(r: 0, g: 0, b: 255, a: 255))
        #expect(document.objects.count == 1)
    }

    @Test func imageObjectsDrawUpright() throws {
        let ref = ImageRef(name: "images/a.png")
        var (document, images) = TestBitmaps.document(
            base: base, objects: [shape(.image(ImageObject(rect: CGRect(x: 20, y: 20, width: 20, height: 20), image: ref)))])
        images.set(TestBitmaps.stacked(8, 8, top: TestBitmaps.red, bottom: TestBitmaps.blue), for: ref)
        let image = try render(document, images)
        #expect(TestBitmaps.pixel(image, 30, 22) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 30, 38) == .init(r: 0, g: 0, b: 255, a: 255))
        #expect(document.objects.count == 1)
    }

    @Test func imageObjectsWithAFlippedRectDrawWhereTheRectIs() throws {
        // A rect dragged up and left has a negative size; the image still lands inside it, upright.
        let ref = ImageRef(name: "images/a.png")
        var (document, images) = TestBitmaps.document(
            base: base, objects: [shape(.image(ImageObject(rect: CGRect(x: 40, y: 40, width: -20, height: -20), image: ref)))])
        images.set(TestBitmaps.stacked(8, 8, top: TestBitmaps.red, bottom: TestBitmaps.blue), for: ref)
        let image = try render(document, images)
        #expect(TestBitmaps.pixel(image, 30, 22) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 30, 38) == .init(r: 0, g: 0, b: 255, a: 255))
        #expect(TestBitmaps.pixel(image, 45, 45) == .init(r: 255, g: 255, b: 255, a: 255))
        #expect(document.objects.count == 1)
    }

    @Test func shadowsAreTheSameSizeInARetinaContext() throws {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let (document, images) = TestBitmaps.document(base: base, objects: [shape(.filledRectangle(rect), shadow: true)])
        let oneX = try render(document, images)
        // A 60 pt window at 2×: 120 device pixels, with the backing scale as the context's base transform.
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 120, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 60, height: 60)
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let context = graphics.cgContext
        context.translateBy(x: 0, y: 60)
        context.scaleBy(x: 1, y: -1)
        Renderer.draw(document, images: images, in: context, deviceScale: 2)
        let twoX = try #require(rep.cgImage)
        #expect(twoX.width == 120)
        // How far below the rect the shadow reaches (the first row that is back to white), in points.
        func reach(_ image: CGImage, scale: Int) -> Double {
            let bytes = TestBitmaps.bytes(image)
            let bottom = 30 * scale
            for y in bottom..<image.height where bytes[(y * image.width + 20 * scale) * 4 + 1] >= 250 {
                return Double(y - bottom) / Double(scale)
            }
            return Double(image.height - bottom) / Double(scale)
        }
        let expected = reach(oneX, scale: 1)
        #expect(expected > 3) // there is a shadow to compare
        #expect(abs(reach(twoX, scale: 2) - expected) <= 1)
    }

    @Test func shadowsFallBelowObjectsOnlyWhenOn() throws {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let (withShadow, images) = TestBitmaps.document(base: base, objects: [shape(.filledRectangle(rect), shadow: true)])
        let (without, _) = TestBitmaps.document(base: base, objects: [shape(.filledRectangle(rect), shadow: false)])
        #expect(TestBitmaps.pixel(try render(withShadow, images), 20, 32).r < 250)
        #expect(TestBitmaps.pixel(try render(without, images), 20, 32) == .init(r: 255, g: 255, b: 255, a: 255))
    }

    @Test func highlighterMultipliesOverTheBase() throws {
        let yellow = RGBAColor(red: 1, green: 1, blue: 0)
        let mark = shape(.highlight(HighlightObject(points: [], rects: [CGRect(x: 10, y: 10, width: 30, height: 10)], width: 10, opacity: 1)),
                         color: yellow)
        let (document, images) = TestBitmaps.document(base: base, objects: [mark])
        let pixel = TestBitmaps.pixel(try render(document, images), 20, 15)
        #expect(pixel.r > 250)
        #expect(pixel.b < 10)
    }
}

struct RendererTranslucencyTests {
    let base = TestBitmaps.solid(60, 60, TestBitmaps.white)
    private let half = redColor.withAlpha(0.5)

    @Test func aTranslucentArrowIsOneEvenTint() throws {
        let arrow = shape(.arrow(ArrowShape(start: CGPoint(x: 5, y: 30), end: CGPoint(x: 55, y: 30), style: .standard)),
                          color: half, width: 6)
        let (document, images) = TestBitmaps.document(base: base, objects: [arrow])
        let image = try render(document, images)
        // The head spans x 34...55 (21 long), the shaft ends where the head begins.
        let inHead = TestBitmaps.pixel(image, 45, 30)
        let onShaft = TestBitmaps.pixel(image, 20, 30)
        #expect(onShaft == inHead)
        // 50% red over white is (255, 128, 128).
        #expect(onShaft.r == 255)
        #expect(abs(Int(onShaft.g) - 128) <= 2)
    }

    @Test func overlappingPartsOfATranslucentArrowDontDoubleDarken() throws {
        // A curved arrow whose control point sits just behind the tip, so the shaft runs into the head (x 34...48 is
        // covered by both). Drawn part by part, that overlap would be 75% red instead of 50%.
        let arrow = shape(.arrow(ArrowShape(start: CGPoint(x: 5, y: 30), end: CGPoint(x: 55, y: 30), control: CGPoint(x: 45, y: 30),
                                            style: .curved)), color: half, width: 6)
        let (document, images) = TestBitmaps.document(base: base, objects: [arrow])
        let image = try render(document, images)
        let overlap = TestBitmaps.pixel(image, 40, 30)
        let shaftOnly = TestBitmaps.pixel(image, 20, 30)
        #expect(overlap == shaftOnly)
        #expect(abs(Int(overlap.g) - 128) <= 2)
    }

    @Test func aTranslucentObjectKeepsItsShadow() throws {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let (shadowed, images) = TestBitmaps.document(base: base, objects: [shape(.filledRectangle(rect), color: half, shadow: true)])
        let (plain, _) = TestBitmaps.document(base: base, objects: [shape(.filledRectangle(rect), color: half, shadow: false)])
        // Just below the rectangle, where the shadow falls and nothing else paints.
        #expect(TestBitmaps.pixel(try render(shadowed, images), 20, 32).g < 250)
        #expect(TestBitmaps.pixel(try render(plain, images), 20, 32) == .init(r: 255, g: 255, b: 255, a: 255))
        // And the rectangle itself is still the translucent tint.
        let inside = TestBitmaps.pixel(try render(plain, images), 20, 20)
        #expect(abs(Int(inside.g) - 128) <= 2)
    }

    @Test func highlightsKeepTheirOwnOpacity() throws {
        // The highlighter has its own opacity; the color's alpha doesn't apply a second time.
        let yellow = RGBAColor(red: 1, green: 1, blue: 0, alpha: 0.5)
        let mark = shape(.highlight(HighlightObject(points: [], rects: [CGRect(x: 10, y: 10, width: 30, height: 10)], width: 10, opacity: 1)),
                         color: yellow)
        let (document, images) = TestBitmaps.document(base: base, objects: [mark])
        let pixel = TestBitmaps.pixel(try render(document, images), 20, 15)
        #expect(pixel.b < 10)
    }
}

struct RendererTextTests {
    let base = TestBitmaps.solid(240, 80, TestBitmaps.white)

    @Test func textPaintsGlyphs() throws {
        let text = shape(.text(TextObject(origin: CGPoint(x: 10, y: 10), string: "WWW", style: .standard, fontSize: 40)),
                         color: RGBAColor.black)
        let (document, images) = TestBitmaps.document(base: base, objects: [text])
        let bytes = TestBitmaps.bytes(try render(document, images))
        let dark = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] < 100 }.count
        #expect(dark > 50)
    }

    /// The number of dark pixels in each row of `image`.
    private func inkPerRow(_ image: CGImage) -> [Int] {
        let bytes = TestBitmaps.bytes(image)
        return (0..<image.height).map { y in
            (0..<image.width).filter { bytes[(y * image.width + $0) * 4] < 128 }.count
        }
    }

    @Test func textDrawsUpright() throws {
        let text = shape(.text(TextObject(origin: CGPoint(x: 10, y: 10), string: "T", style: .standard, fontSize: 40)),
                         color: RGBAColor.black)
        let (document, images) = TestBitmaps.document(base: base, objects: [text])
        let rows = inkPerRow(try render(document, images))
        let first = try #require(rows.firstIndex { $0 > 0 })
        let last = try #require(rows.lastIndex { $0 > 0 })
        // A T has its bar on top and a stem below.
        #expect(rows[first] > rows[last])
    }

    @Test func textStartsAtItsMeasuredFrame() throws {
        let object = TextObject(origin: CGPoint(x: 10, y: 20), string: "H", style: .standard, fontSize: 40)
        let (document, images) = TestBitmaps.document(base: base, objects: [shape(.text(object), color: RGBAColor.black)])
        let rows = inkPerRow(try render(document, images))
        let first = try #require(rows.firstIndex { $0 > 0 })
        let frame = TextLayout.frame(of: object)
        let padding = TextLayout.padding(for: object.style, fontSize: object.fontSize)
        #expect(Double(first) >= frame.minY + padding.height)
        // The capital's top sits below the line's top by the font's ascender minus its cap height.
        let font = TextLayout.font(for: object.style, size: object.fontSize)
        let expected = frame.minY + padding.height + font.ascender - font.capHeight
        #expect(abs(Double(first) - expected) < 0.75)
    }

    @Test func boxTextFillsItsBox() throws {
        let text = TextObject(origin: CGPoint(x: 10, y: 10), string: "Box", style: .box, fontSize: 30)
        let (document, images) = TestBitmaps.document(base: base, objects: [shape(.text(text), color: blueColor)])
        let frame = TextLayout.frame(of: text)
        let pixel = TestBitmaps.pixel(try render(document, images), Int(frame.minX) + 4, Int(frame.midY))
        #expect(pixel == .init(r: 0, g: 0, b: 255, a: 255))
    }

    /// White (box text's color on a black box) pixel count in the text area of a rendered box: `rows` counted from the
    /// top of the text, inside the padding, so the box's rounded corners (white base) don't count.
    private func whitePixels(in image: CGImage, frame: CGRect, padding: CGSize, rows: Range<Int>) -> Int {
        let bytes = TestBitmaps.bytes(image)
        let top = Int(frame.minY + padding.height)
        var count = 0
        for y in (top + rows.lowerBound)..<(top + rows.upperBound) {
            for x in Int(frame.minX + padding.width)..<Int(frame.maxX - padding.width) where bytes[(y * image.width + x) * 4] > 128 {
                count += 1
            }
        }
        return count
    }

    @Test func textThatJustFitsItsMeasuredWidthStaysOnOneLine() throws {
        let probe = TextObject(origin: CGPoint(x: 10, y: 10), string: "Wrap me please", style: .box, fontSize: 24)
        let measured = TextLayout.textSize(of: probe)
        let padding = TextLayout.padding(for: .box, fontSize: 24)
        let fittedWidth = measured.width + 2 * padding.width
        var fitted = probe
        fitted.width = fittedWidth
        var roomy = probe
        roomy.width = fittedWidth + 30
        let frame = TextLayout.frame(of: fitted)
        #expect(frame.height == TextLayout.frame(of: roomy).height) // both measured as one line
        let (tightDocument, images) = TestBitmaps.document(base: base, objects: [shape(.text(fitted), color: RGBAColor.black)])
        let (looseDocument, _) = TestBitmaps.document(base: base, objects: [shape(.text(roomy), color: RGBAColor.black)])
        let tight = try render(tightDocument, images)
        let loose = try render(looseDocument, images)
        // The text area renders the same with no spare room as with plenty: nothing wrapped away.
        let tightBytes = TestBitmaps.bytes(tight)
        let looseBytes = TestBitmaps.bytes(loose)
        var different = 0
        for y in Int(frame.minY + padding.height)..<Int(frame.maxY - padding.height) {
            for x in Int(frame.minX + padding.width)..<Int(frame.maxX - padding.width) {
                let index = (y * tight.width + x) * 4
                if tightBytes[index..<index + 4] != looseBytes[index..<index + 4] { different += 1 }
            }
        }
        #expect(different == 0)
        #expect(whitePixels(in: tight, frame: frame, padding: padding, rows: 0..<Int(measured.height)) > 0)
    }

    @Test func textThatIsMeasuredAsWrappedRendersEveryLine() throws {
        // One point narrower than the one-line width wraps when measured, so it must wrap when drawn.
        let probe = TextObject(origin: CGPoint(x: 10, y: 10), string: "Wrap me please", style: .box, fontSize: 24)
        let measured = TextLayout.textSize(of: probe)
        let padding = TextLayout.padding(for: .box, fontSize: 24)
        var narrow = probe
        narrow.width = measured.width - 1 + 2 * padding.width
        let frame = TextLayout.frame(of: narrow)
        #expect(frame.height > TextLayout.frame(of: probe).height) // measured as more than one line
        let (document, images) = TestBitmaps.document(base: base, objects: [shape(.text(narrow), color: RGBAColor.black)])
        let image = try render(document, images)
        let line = Int(measured.height)
        let total = Int(frame.height - 2 * padding.height)
        #expect(whitePixels(in: image, frame: frame, padding: padding, rows: 0..<line) > 0)
        #expect(whitePixels(in: image, frame: frame, padding: padding, rows: line..<total) > 0)
    }
}

struct RendererRedactionTests {
    let noise = TestBitmaps.noise(64, 64)

    private func redact(_ style: RedactStyle, rect: CGRect = CGRect(x: 0, y: 0, width: 64, height: 64), intensity: Int = 5) -> AnnotationObject {
        shape(.redact(RedactObject(rect: rect, style: style, intensity: intensity)))
    }

    @Test func redactionReplacesPartlyTransparentPixels() throws {
        // A transparent image with one opaque black 2×2 block. Pixelated, that block averages to almost nothing, and the
        // original pixel must not show through the nearly transparent result.
        let base = TestBitmaps.transparent(64, 64, blocks: [CGRect(x: 30, y: 32, width: 2, height: 2)])
        let (document, images) = TestBitmaps.document(base: base, objects: [redact(.pixelate)])
        let pixel = TestBitmaps.pixel(try render(document, images), 30, 32)
        #expect(pixel != .init(r: 0, g: 0, b: 0, a: 255))
        #expect(pixel.a < 64)
    }

    @Test func aFailedRedactionFillsBlackAndIsNotCached() throws {
        let rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        var object = redact(.pixelate, rect: rect)
        let (document, images) = TestBitmaps.document(base: noise, objects: [object])
        let cache = RenderCache()
        Renderer.draw(document, images: images, in: TestBitmaps.flippedContext(64, 64), cache: cache)
        #expect(cache.redactions[object.id] != nil)
        // The effect now fails (an image or Core Image error): the region goes black rather than showing the original,
        // and the failure isn't remembered, so the next frame tries again.
        cache.effect = { _, _, _, _, _ in nil }
        object.kind = .redact(RedactObject(rect: rect, style: .pixelate, intensity: 9))
        var failing = document
        failing.objects = [object]
        let context = TestBitmaps.flippedContext(64, 64)
        Renderer.draw(failing, images: images, in: context, cache: cache)
        let image = try #require(context.makeImage())
        #expect(TestBitmaps.pixel(image, 16, 16) == .init(r: 0, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 0, 0) == .init(r: 0, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 31, 31) == .init(r: 0, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 48, 48) == TestBitmaps.pixel(noise, 48, 48))
        #expect(cache.redactions[object.id] == nil)
    }

    @Test func redactionsIgnoreOtherAnnotations() throws {
        // A red rect made before the redaction, overlapping it in part. Redactions come from the base pixels only, so
        // the redaction looks the same with or without the rect, and the rect stays on top of it.
        let redaction = redact(.pixelate, rect: CGRect(x: 16, y: 16, width: 40, height: 40))
        let cover = shape(.filledRectangle(CGRect(x: 0, y: 0, width: 32, height: 32)))
        let (covered, images) = TestBitmaps.document(base: noise, objects: [cover, redaction])
        let (alone, _) = TestBitmaps.document(base: noise, objects: [redaction])
        let withRect = try render(covered, images)
        let without = try render(alone, images)
        #expect(TestBitmaps.pixel(withRect, 20, 20) == .init(r: 255, g: 0, b: 0, a: 255))
        let a = TestBitmaps.bytes(withRect)
        let b = TestBitmaps.bytes(without)
        var different = 0
        for y in 0..<64 {
            for x in 0..<64 where !(x < 32 && y < 32) {
                let index = (y * 64 + x) * 4
                if a[index..<index + 4] != b[index..<index + 4] { different += 1 }
            }
        }
        #expect(different == 0)
        // Inside the redaction, outside the rect: pixelated noise, not red.
        let probe = TestBitmaps.pixel(withRect, 50, 50)
        #expect(probe.g > 0 && probe.b > 0)
    }

    @Test func aRedactionOverlappingTheImageEdgeOnlyTouchesTheImage() throws {
        let object = redact(.pixelate, rect: CGRect(x: -20, y: -20, width: 40, height: 40))
        let (document, images) = TestBitmaps.document(base: noise, objects: [object])
        let rendered = TestBitmaps.bytes(try render(document, images))
        let original = TestBitmaps.bytes(noise)
        var outsideChanged = 0
        var insideSame = 0
        for y in 0..<64 {
            for x in 0..<64 {
                let index = (y * 64 + x) * 4
                let same = rendered[index..<index + 4] == original[index..<index + 4]
                if x < 20, y < 20 {
                    if same { insideSame += 1 }
                } else if !same {
                    outsideChanged += 1
                }
            }
        }
        #expect(outsideChanged == 0)
        #expect(insideSame < 400 / 20)
    }

    @Test func pixelateBlocksCoverExactlyTheirOwnPixels() throws {
        // Intensity 10 is 30-pixel blocks, counted from the region's top-left. The image is black left of x = 30 and white
        // from there, so block 0 is all black and block 1 all white; the last block (x 60...63) is only 4 pixels wide, and
        // a block cut short by the edge must still be opaque.
        let split = TestBitmaps.split(64, 64, left: TestBitmaps.black, right: TestBitmaps.white, at: 30)
        let (document, images) = TestBitmaps.document(base: split, objects: [redact(.pixelate, intensity: 10)])
        let image = try render(document, images)
        // Per-block noise is ±24, kept inside the pixel's alpha.
        let black = TestBitmaps.pixel(image, 10, 10)
        #expect(black.r <= 24 && black.a == 255)
        for (x, y) in [(40, 10), (62, 10), (40, 62), (62, 62)] {
            let pixel = TestBitmaps.pixel(image, x, y)
            #expect(pixel.r >= 231 && pixel.a == 255, "pixel (\(x), \(y)) is \(pixel)")
        }
    }

    @Test func blackOutCoversWholePixels() throws {
        // A fractional rect still blacks out every pixel it touches, none left partly showing.
        let object = redact(.blackOut, rect: CGRect(x: 10.4, y: 10.4, width: 20.2, height: 20.2))
        let (document, images) = TestBitmaps.document(base: noise, objects: [object])
        let image = try render(document, images)
        #expect(TestBitmaps.pixel(image, 10, 10) == .init(r: 0, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 30, 30) == .init(r: 0, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 9, 9) == TestBitmaps.pixel(noise, 9, 9))
        #expect(TestBitmaps.pixel(image, 31, 31) == TestBitmaps.pixel(noise, 31, 31))
    }

    @Test func pixelateHidesTheOriginalAndIsStable() throws {
        let object = redact(.pixelate)
        let (document, images) = TestBitmaps.document(base: noise, objects: [object])
        let first = TestBitmaps.bytes(try render(document, images))
        let second = TestBitmaps.bytes(try render(document, images))
        #expect(first == second)
        let original = TestBitmaps.bytes(noise)
        let same = stride(from: 0, to: original.count, by: 4).filter { first[$0..<$0 + 3] == original[$0..<$0 + 3] }.count
        #expect(same < original.count / 4 / 20)
        let image = try render(document, images)
        // Neighbouring pixels inside one block are identical.
        #expect(TestBitmaps.pixel(image, 1, 1) == TestBitmaps.pixel(image, 2, 2))
    }

    /// After a resize op the redaction's edges fall between output pixels. Every output pixel whose centre is inside the
    /// redaction must show the redaction alone: nothing of the picture under or beside it may blend into its edge.
    @Test(arguments: RedactStyle.allCases)
    func aRedactionAfterAResizeLeavesNoOriginalPixelsAtItsEdge(style: RedactStyle) throws {
        // 101 px resized to 67: the rect's edges, at 20 and 60 base pixels, land at 13.27 and 39.80 output pixels.
        let size = 101
        let rect = CGRect(x: 20, y: 20, width: 40, height: 40)
        let noise = TestBitmaps.noise(size, size)
        // The same picture inside the redaction (so the redaction itself is the same), and a different one around it.
        var bytes = TestBitmaps.bytes(noise)
        for y in 0..<size {
            for x in 0..<size where !rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                for channel in 0..<3 { bytes[(y * size + x) * 4 + channel] = 255 - bytes[(y * size + x) * 4 + channel] }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let other = try #require(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                         space: TestBitmaps.srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        var (document, images) = TestBitmaps.document(base: noise, objects: [redact(style, rect: rect)])
        document.imageOps = [.resize(width: 67, height: 67)]
        var plain = document
        plain.objects = []
        let (_, otherImages) = TestBitmaps.document(base: other)
        let redacted = TestBitmaps.bytes(try render(document, images))
        let redactedOverOther = TestBitmaps.bytes(try render(document, otherImages))
        let resampled = TestBitmaps.bytes(try render(plain, images))
        let mapped = rect.applying(document.transform.transform)
        var inside = 0, dependsOnThePicture = 0, showsThePicture = 0
        for y in 0..<67 {
            for x in 0..<67 where mapped.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                inside += 1
                let index = (y * 67 + x) * 4
                if redacted[index..<index + 4] != redactedOverOther[index..<index + 4] { dependsOnThePicture += 1 }
                if redacted[index..<index + 4] == resampled[index..<index + 4] { showsThePicture += 1 }
            }
        }
        #expect(inside == 27 * 27)
        #expect(dependsOnThePicture == 0, "\(dependsOnThePicture) of \(inside) pixels mix in the picture")
        #expect(showsThePicture == 0, "\(showsThePicture) of \(inside) pixels show the picture")
    }

    @Test func pixelateAddsNoiseToASolidRegion() throws {
        // Every block of a solid region averages to the same color; the per-block noise is what sets them apart.
        let base = TestBitmaps.solid(64, 64, TestBitmaps.blue)
        let (document, images) = TestBitmaps.document(base: base, objects: [redact(.pixelate, intensity: 1)])
        let image = try render(document, images)
        let solid = TestBitmaps.RGBA(r: 0, g: 0, b: 255, a: 255)
        // Intensity 1 is 3 px blocks: sample one pixel of each.
        let blocks = stride(from: 1, to: 64, by: 3).flatMap { y in stride(from: 1, to: 64, by: 3).map { x in (x, y) } }
        let bytes = TestBitmaps.bytes(image)
        let noisy = blocks.filter { x, y in
            let index = (y * 64 + x) * 4
            return TestBitmaps.RGBA(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2], a: bytes[index + 3]) != solid
        }
        #expect(noisy.count > blocks.count / 2)
    }

    @Test func redactionsStayBelowAnnotations() throws {
        let cover = shape(.filledRectangle(CGRect(x: 0, y: 0, width: 64, height: 64)))
        let (document, images) = TestBitmaps.document(base: noise, objects: [cover, redact(.blackOut)])
        #expect(TestBitmaps.pixel(try render(document, images), 30, 30) == .init(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func blackOutIsSolidBlack() throws {
        let (document, images) = TestBitmaps.document(base: noise, objects: [redact(.blackOut)])
        #expect(TestBitmaps.pixel(try render(document, images), 30, 30) == .init(r: 0, g: 0, b: 0, a: 255))
    }

    @Test func smoothBlurSoftensEdges() throws {
        let split = TestBitmaps.split(64, 64, left: TestBitmaps.black, right: TestBitmaps.white)
        let (document, images) = TestBitmaps.document(base: split, objects: [redact(.smoothBlur)])
        let pixel = TestBitmaps.pixel(try render(document, images), 32, 32)
        #expect(pixel.r > 30)
        #expect(pixel.r < 225)
    }

    @Test func secureBlurAlsoHidesTheOriginal() throws {
        let (document, images) = TestBitmaps.document(base: noise, objects: [redact(.secureBlur)])
        let rendered = TestBitmaps.bytes(try render(document, images))
        let original = TestBitmaps.bytes(noise)
        let same = stride(from: 0, to: original.count, by: 4).filter { rendered[$0..<$0 + 3] == original[$0..<$0 + 3] }.count
        #expect(same < original.count / 4 / 20)
    }

    @Test func theCacheReusesARedactionUntilItChanges() throws {
        var object = redact(.pixelate, rect: CGRect(x: 0, y: 0, width: 32, height: 32))
        let (document, images) = TestBitmaps.document(base: noise, objects: [object])
        let cache = RenderCache()
        let context = TestBitmaps.context(64, 64)
        Renderer.draw(document, images: images, in: context, cache: cache)
        let first = try #require(cache.redactions[object.id]?.image)
        Renderer.draw(document, images: images, in: context, cache: cache)
        #expect(cache.redactions[object.id]?.image === first)
        object.kind = .redact(RedactObject(rect: CGRect(x: 0, y: 0, width: 32, height: 32), style: .pixelate, intensity: 9))
        var changed = document
        changed.objects = [object]
        Renderer.draw(changed, images: images, in: context, cache: cache)
        #expect(cache.redactions[object.id]?.image !== first)
    }
}

struct RenderCacheTests {
    let noise = TestBitmaps.noise(64, 64)
    let rect = CGRect(x: 0, y: 0, width: 32, height: 32)

    private func pixelate(_ rect: CGRect) -> AnnotationObject {
        shape(.redact(RedactObject(rect: rect, style: .pixelate, intensity: 5)))
    }

    @Test func aCachedRedactionIsRedoneWhenTheBaseChanges() throws {
        let object = pixelate(rect)
        let (document, images) = TestBitmaps.document(base: noise, objects: [object])
        let cache = RenderCache()
        let context = TestBitmaps.context(64, 64)
        Renderer.draw(document, images: images, in: context, cache: cache)
        let first = try #require(cache.redactions[object.id]?.image)
        // The same object over a different image of the same size (an undone paste, a swapped base).
        let (_, other) = TestBitmaps.document(base: TestBitmaps.solid(64, 64, TestBitmaps.blue))
        Renderer.draw(document, images: other, in: context, cache: cache)
        let second = try #require(cache.redactions[object.id]?.image)
        #expect(second !== first)
    }

    @Test func aCachedRedactionIsRedoneWhenItsRegionChanges() throws {
        let object = pixelate(rect)
        let (document, images) = TestBitmaps.document(base: noise, objects: [object])
        let cache = RenderCache()
        let context = TestBitmaps.context(64, 64)
        Renderer.draw(document, images: images, in: context, cache: cache)
        let first = try #require(cache.redactions[object.id]?.image)
        var moved = object
        moved.kind = .redact(RedactObject(rect: CGRect(x: 16, y: 16, width: 32, height: 32), style: .pixelate, intensity: 5))
        var changed = document
        changed.objects = [moved]
        Renderer.draw(changed, images: images, in: context, cache: cache)
        #expect(cache.redactions[object.id]?.region == CGRect(x: 16, y: 16, width: 32, height: 32))
        #expect(cache.redactions[object.id]?.image !== first)
    }

    @Test func aCachedRedactionIsRedoneWhenThePixelScaleChanges() throws {
        let object = pixelate(rect)
        var (document, images) = TestBitmaps.document(base: noise, objects: [object])
        let cache = RenderCache()
        let context = TestBitmaps.context(64, 64)
        Renderer.draw(document, images: images, in: context, cache: cache)
        let first = try #require(cache.redactions[object.id]?.image)
        document.pixelScale = 2 // bigger blocks
        Renderer.draw(document, images: images, in: context, cache: cache)
        #expect(cache.redactions[object.id]?.image !== first)
    }

    @Test func deletedRedactionsLeaveTheCache() throws {
        let kept = pixelate(CGRect(x: 32, y: 32, width: 16, height: 16))
        let deleted = pixelate(rect)
        var (document, images) = TestBitmaps.document(base: noise, objects: [kept, deleted])
        let cache = RenderCache()
        let context = TestBitmaps.context(64, 64)
        Renderer.draw(document, images: images, in: context, cache: cache)
        #expect(cache.redactions[deleted.id] != nil)
        #expect(cache.redactions[kept.id] != nil)
        document.objects = [kept]
        Renderer.draw(document, images: images, in: context, cache: cache)
        #expect(cache.redactions[deleted.id] == nil)
        #expect(cache.redactions[kept.id] != nil)
    }
}

struct RendererSpotlightTests {
    let base = TestBitmaps.solid(60, 60, TestBitmaps.white)

    @Test func spotlightsDimEverythingOutsideThem() throws {
        let light = shape(.spotlight(SpotlightObject(rect: CGRect(x: 10, y: 10, width: 20, height: 20), shape: .rectangle, opacity: 0.5)))
        let (document, images) = TestBitmaps.document(base: base, objects: [light])
        let image = try render(document, images)
        let outside = TestBitmaps.pixel(image, 50, 50)
        #expect(outside.r > 110 && outside.r < 145)
        #expect(TestBitmaps.pixel(image, 20, 20) == .init(r: 255, g: 255, b: 255, a: 255))
    }

    @Test func anEllipseSpotlightDimsItsRectsCorners() throws {
        let light = shape(.spotlight(SpotlightObject(rect: CGRect(x: 10, y: 10, width: 40, height: 40), shape: .ellipse, opacity: 0.5)))
        let (document, images) = TestBitmaps.document(base: base, objects: [light])
        let image = try render(document, images)
        #expect(TestBitmaps.pixel(image, 30, 30) == .init(r: 255, g: 255, b: 255, a: 255))
        let corner = TestBitmaps.pixel(image, 12, 12)
        #expect(corner.r > 110 && corner.r < 145)
    }

    @Test func overlappingSpotlightsLightTheirUnion() throws {
        let a = shape(.spotlight(SpotlightObject(rect: CGRect(x: 10, y: 10, width: 30, height: 30), shape: .rectangle, opacity: 0.5)))
        let b = shape(.spotlight(SpotlightObject(rect: CGRect(x: 20, y: 20, width: 30, height: 30), shape: .rectangle, opacity: 0.5)))
        let (document, images) = TestBitmaps.document(base: base, objects: [a, b])
        #expect(TestBitmaps.pixel(try render(document, images), 30, 30) == .init(r: 255, g: 255, b: 255, a: 255))
    }
}

struct RenderObjectsTests {
    @Test func copiesJustTheObjectsOnTransparency() throws {
        let rect = shape(.filledRectangle(CGRect(x: 10, y: 10, width: 20, height: 20)))
        let (document, images) = TestBitmaps.document(base: TestBitmaps.solid(60, 60, TestBitmaps.white), objects: [rect])
        let image = try #require(Renderer.renderObjects([rect], document: document, images: images))
        #expect(image.width == 36)
        #expect(image.height == 36)
        #expect(TestBitmaps.pixel(image, 18, 18) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 1, 1).a == 0)
    }

    @Test func copiedObjectsKeepTheCanvasOrderWithRedactionsUnderneath() throws {
        // A filled rect made before an overlapping pixelate redaction. The canvas draws redactions first, so the rect
        // shows on top of the redaction; the copy must show the same.
        let rect = shape(.filledRectangle(CGRect(x: 10, y: 10, width: 30, height: 30)))
        let redaction = shape(.redact(RedactObject(rect: CGRect(x: 20, y: 20, width: 30, height: 30), style: .pixelate, intensity: 5)))
        let (document, images) = TestBitmaps.document(base: TestBitmaps.noise(64, 64), objects: [rect, redaction])
        let canvas = try render(document, images)
        let copy = try #require(Renderer.renderObjects([rect, redaction], document: document, images: images))
        // The copy is cropped to the objects' bounds plus the 8 pixel margin: its origin is (2, 2) in the document.
        let origin = 2
        // Inside the overlap (document 25, 25) the rect's color shows, as on the canvas.
        #expect(TestBitmaps.pixel(canvas, 25, 25) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(copy, 25 - origin, 25 - origin) == .init(r: 255, g: 0, b: 0, a: 255))
        // Inside the redaction, outside the rect (document 45, 45): the redaction's pixels, not transparent or red.
        let redacted = TestBitmaps.pixel(copy, 45 - origin, 45 - origin)
        #expect(redacted.a == 255)
        #expect(redacted.g > 0 && redacted.b > 0)
    }
}

struct ObjectRasterCacheTests {
    let base = TestBitmaps.solid(64, 64, TestBitmaps.white)

    private func shadowedBox() -> AnnotationObject {
        shape(.filledRectangle(CGRect(x: 12, y: 12, width: 24, height: 20)), shadow: true)
    }

    /// One frame the way the canvas draws one: a fresh context whose user space is output pixels with y down, zoomed by
    /// `zoom`.
    private func frame(_ document: AnnotationDocument, _ images: ImageStore, cache: RenderCache?, useObjectCache: Bool,
                       zoom: Int = 1) -> CGImage {
        let context = TestBitmaps.flippedContext(64 * zoom, 64 * zoom)
        context.scaleBy(x: CGFloat(zoom), y: CGFloat(zoom))
        Renderer.draw(document, images: images, in: context, cache: cache, useObjectCache: useObjectCache)
        return context.makeImage()!
    }

    private func largestDifference(_ a: CGImage, _ b: CGImage) -> Int {
        zip(TestBitmaps.bytes(a), TestBitmaps.bytes(b)).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    @Test func anUnchangedObjectIsRasterizedOnItsSecondDrawThenReused() throws {
        let object = shadowedBox()
        let (document, images) = TestBitmaps.document(base: base, objects: [object])
        let cache = RenderCache()
        _ = frame(document, images, cache: cache, useObjectCache: true)
        // Seen once: drawn directly, as an object that changes every frame always is.
        #expect(cache.objectRasters[object.id] != nil)
        #expect(cache.objectRasters[object.id]?.raster == nil)
        _ = frame(document, images, cache: cache, useObjectCache: true)
        let raster = try #require(cache.objectRasters[object.id]?.raster?.image)
        _ = frame(document, images, cache: cache, useObjectCache: true)
        #expect(cache.objectRasters[object.id]?.raster?.image === raster)
    }

    @Test func aStyleChangeMissesTheCache() {
        var object = shadowedBox()
        var (document, images) = TestBitmaps.document(base: base, objects: [object])
        let cache = RenderCache()
        _ = frame(document, images, cache: cache, useObjectCache: true)
        _ = frame(document, images, cache: cache, useObjectCache: true)
        #expect(cache.objectRasters[object.id]?.raster != nil)
        object.style.color = blueColor
        document.objects = [object]
        _ = frame(document, images, cache: cache, useObjectCache: true)
        #expect(cache.objectRasters[object.id]?.raster == nil)
        #expect(cache.objectRasters[object.id]?.object == object)
    }

    @Test(arguments: [[ImageOp](), [.rotateRight], [.flipHorizontal]])
    func aCachedFrameMatchesAnUncachedOne(ops: [ImageOp]) {
        let arrow = shape(.arrow(ArrowShape(start: CGPoint(x: 8, y: 50), end: CGPoint(x: 56, y: 40), style: .standard)),
                          color: blueColor, width: 4, shadow: true)
        var (document, images) = TestBitmaps.document(base: base, objects: [shadowedBox(), arrow])
        document.imageOps = ops
        let expected = frame(document, images, cache: nil, useObjectCache: false)
        let cache = RenderCache()
        for _ in 0..<3 {
            #expect(largestDifference(frame(document, images, cache: cache, useObjectCache: true), expected) <= 1)
        }
        #expect(cache.objectRasters.values.allSatisfy { $0.raster != nil })
    }

    @Test func aZoomedCachedFrameMatchesAnUncachedOne() {
        let (document, images) = TestBitmaps.document(base: base, objects: [shadowedBox()])
        let expected = frame(document, images, cache: nil, useObjectCache: false, zoom: 2)
        let cache = RenderCache()
        for _ in 0..<3 {
            #expect(largestDifference(frame(document, images, cache: cache, useObjectCache: true, zoom: 2), expected) <= 1)
        }
    }

    @Test func aRetinaCachedFrameMatchesAnUncachedOne() throws {
        let arrow = shape(.arrow(ArrowShape(start: CGPoint(x: 8, y: 50), end: CGPoint(x: 56, y: 40), style: .standard)),
                          color: blueColor, width: 4, shadow: true)
        let (document, images) = TestBitmaps.document(base: base, objects: [shadowedBox(), arrow])
        // A 64-point view at 2×, as in a Retina window: the backing scale is the context's base transform.
        func retinaFrame(cache: RenderCache?, useObjectCache: Bool) throws -> CGImage {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = NSSize(width: 64, height: 64)
            let graphics = try #require(NSGraphicsContext(bitmapImageRep: rep))
            let context = graphics.cgContext
            context.translateBy(x: 0, y: 64)
            context.scaleBy(x: 1, y: -1)
            Renderer.draw(document, images: images, in: context, cache: cache, deviceScale: 2, useObjectCache: useObjectCache)
            return try #require(rep.cgImage)
        }
        let expected = try retinaFrame(cache: nil, useObjectCache: false)
        let cache = RenderCache()
        for _ in 0..<3 {
            #expect(largestDifference(try retinaFrame(cache: cache, useObjectCache: true), expected) <= 1)
        }
        #expect(cache.objectRasters.values.allSatisfy { $0.raster?.image.width ?? 0 > 0 })
    }

    @Test func objectsWithoutShadowsAreNeverCached() {
        let plain = shape(.filledRectangle(CGRect(x: 12, y: 12, width: 24, height: 20)), shadow: false)
        let (document, images) = TestBitmaps.document(base: base, objects: [plain])
        let cache = RenderCache()
        _ = frame(document, images, cache: cache, useObjectCache: true)
        _ = frame(document, images, cache: cache, useObjectCache: true)
        #expect(cache.objectRasters.isEmpty)
    }

    @Test func withoutTheFlagNothingIsCached() {
        let (document, images) = TestBitmaps.document(base: base, objects: [shadowedBox()])
        let cache = RenderCache()
        _ = frame(document, images, cache: cache, useObjectCache: false)
        _ = frame(document, images, cache: cache, useObjectCache: false)
        #expect(cache.objectRasters.isEmpty)
    }

    @Test func deletedObjectsLeaveTheObjectCache() {
        let kept = shadowedBox()
        let deleted = shape(.filledRectangle(CGRect(x: 40, y: 40, width: 10, height: 10)), shadow: true)
        var (document, images) = TestBitmaps.document(base: base, objects: [kept, deleted])
        let cache = RenderCache()
        _ = frame(document, images, cache: cache, useObjectCache: true)
        #expect(cache.objectRasters[deleted.id] != nil)
        document.objects = [kept]
        _ = frame(document, images, cache: cache, useObjectCache: true)
        #expect(cache.objectRasters[deleted.id] == nil)
        #expect(cache.objectRasters[kept.id] != nil)
    }

    // MARK: Tests that pin the key, the placement, the gate and the cap, with one live cache

    /// A frame at any magnification and translation, into a `size`-point context whose user space is points with y down.
    /// `deviceScale` is the context's real backing scale, as a window's: a 2× frame is `2 × size` pixels and its base
    /// transform carries the 2. The translation is applied before the zoom, so it is in the context's own points.
    private func liveFrame(_ document: AnnotationDocument, _ images: ImageStore, cache: RenderCache?, useObjectCache: Bool = true,
                           size: Int = 64, zoom: Double = 1, translation: CGSize = .zero, deviceScale: Double = 1,
                           hiding: Set<UUID> = []) -> CGImage {
        func draw(in context: CGContext) {
            context.translateBy(x: translation.width, y: translation.height)
            context.scaleBy(x: zoom, y: zoom)
            Renderer.draw(document, images: images, in: context, cache: cache, hiding: hiding, deviceScale: deviceScale,
                          useObjectCache: useObjectCache)
        }
        if deviceScale == 1 {
            let context = TestBitmaps.flippedContext(size, size)
            draw(in: context)
            return context.makeImage()!
        }
        let pixels = Int(Double(size) * deviceScale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size, height: size)
        let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        draw(in: context)
        return rep.cgImage!
    }

    @Test func everyChangeToWhatARasterWasMadeForMissesTheCache() {
        let box = shadowedBox()
        let (document, images) = TestBitmaps.document(base: base, objects: [box])
        let cache = RenderCache()
        var current = (document: document, zoom: 1.0, deviceScale: 1.0)
        // One live cache, a change at a time. After each change the first frame is drawn directly (the entry starts over
        // with no raster), the second builds the raster, and every frame looks like an uncached one.
        func check(_ change: String) {
            let expected = liveFrame(current.document, images, cache: nil, useObjectCache: false, size: 160, zoom: current.zoom,
                                     deviceScale: current.deviceScale)
            for index in 1...3 {
                let actual = liveFrame(current.document, images, cache: cache, size: 160, zoom: current.zoom,
                                       deviceScale: current.deviceScale)
                #expect(largestDifference(actual, expected) <= 1, "\(change), frame \(index)")
                #expect((cache.objectRasters[box.id]?.raster != nil) == (index >= 2), "\(change), frame \(index)")
            }
        }
        check("the first draw")
        current.document.imageOps = [.rotateRight]
        check("rotate right")
        current.document.imageOps = [.rotateRight, .flipHorizontal]
        check("flip horizontal")
        current.document.imageOps = [.rotateRight, .flipHorizontal, .resize(width: 96, height: 48)]
        check("resize")
        current.deviceScale = 2
        check("the device scale")
        current.document.pixelScale = 2
        check("the pixel scale")
        current.zoom = 1.5
        check("the magnification")
    }

    @Test func aFractionalZoomAndOffsetPlaceCachedFramesWhereDirectOnesGo() {
        let bigBase = TestBitmaps.solid(200, 200, TestBitmaps.white)
        let box = shape(.filledRectangle(CGRect(x: 41, y: 37, width: 83, height: 61)), shadow: true)
        let arrow = shape(.arrow(ArrowShape(start: CGPoint(x: 20, y: 170), end: CGPoint(x: 180, y: 130), style: .standard)),
                          color: blueColor, width: 4, shadow: true)
        let (document, images) = TestBitmaps.document(base: bigBase, objects: [box, arrow])
        // 0.37× puts every edge between device pixels, and the offset moves them off the pixel grid by a further fraction.
        let placement = (size: 80, zoom: 0.37, translation: CGSize(width: 0.3, height: 0.6))
        let expected = liveFrame(document, images, cache: nil, useObjectCache: false, size: placement.size, zoom: placement.zoom,
                                 translation: placement.translation)
        let cache = RenderCache()
        // The direct frame, the one that builds the rasters, and one drawn from them.
        for index in 1...3 {
            let actual = liveFrame(document, images, cache: cache, size: placement.size, zoom: placement.zoom,
                                   translation: placement.translation)
            #expect(largestDifference(actual, expected) <= 1, "frame \(index)")
        }
        #expect(cache.objectRasters.count == 2)
        #expect(cache.objectRasters.values.allSatisfy { $0.raster != nil })
    }

    @Test func aPanByAFractionOfAPixelRebuildsTheRaster() {
        let box = shadowedBox()
        let (document, images) = TestBitmaps.document(base: base, objects: [box])
        let cache = RenderCache()
        for _ in 0..<2 { _ = liveFrame(document, images, cache: cache) }
        #expect(cache.objectRasters[box.id]?.raster != nil)
        // The same zoom, half a device pixel over: a raster rounded to whole pixels would sit half a pixel off.
        let panned = CGSize(width: 0.5, height: 0.5)
        let expected = liveFrame(document, images, cache: nil, useObjectCache: false, translation: panned)
        for index in 1...3 {
            let actual = liveFrame(document, images, cache: cache, translation: panned)
            #expect(largestDifference(actual, expected) <= 1, "frame \(index)")
            #expect((cache.objectRasters[box.id]?.raster != nil) == (index >= 2), "frame \(index)")
        }
    }

    @Test func aZoomChangeTooSmallToSeeStillRebuildsTheRaster() {
        // Big enough that a 0.03% stretch moves an edge by a quarter of a pixel.
        let size = 1002
        let bigBase = TestBitmaps.solid(1000, 1000, TestBitmaps.white)
        let box = shape(.filledRectangle(CGRect(x: 100, y: 100, width: 700, height: 600)), shadow: true)
        let (document, images) = TestBitmaps.document(base: bigBase, objects: [box])
        // A zoom about the raster area's device corner (90, 710 in base pixels, 100 and 300 in the context's), the way a
        // zoom keeps one point still: the corner doesn't move, so only the scale tells the zooms apart.
        func frame(_ cache: RenderCache?, zoom: Double) -> CGImage {
            liveFrame(document, images, cache: cache, useObjectCache: cache != nil, size: size, zoom: zoom,
                      translation: CGSize(width: 100 - 90 * zoom, height: Double(size) - 300 - 710 * zoom))
        }
        let cache = RenderCache()
        for _ in 0..<2 { _ = frame(cache, zoom: 1) }
        let built = cache.objectRasters[box.id]?.raster?.image
        #expect(built != nil)
        // Floating-point noise in the zoom is not a change.
        _ = frame(cache, zoom: 1 + 1e-9)
        #expect(cache.objectRasters[box.id]?.raster?.image === built)
        let expected = frame(nil, zoom: 1.0003)
        for index in 1...3 {
            #expect(largestDifference(frame(cache, zoom: 1.0003), expected) <= 1, "frame \(index)")
            #expect((cache.objectRasters[box.id]?.raster != nil) == (index >= 2), "frame \(index)")
        }
    }

    @Test func aPanSmallerThanTheKeysResolutionReusesTheRaster() {
        let box = shadowedBox()
        let (document, images) = TestBitmaps.document(base: base, objects: [box])
        let cache = RenderCache()
        for _ in 0..<2 { _ = liveFrame(document, images, cache: cache) }
        let built = cache.objectRasters[box.id]?.raster?.image
        #expect(built != nil)
        // A sixty-fourth of a pixel is inside the key's sixteenths: nothing is rebuilt. The raster stays within half a
        // sixteenth of a pixel of where a direct draw puts the object: at a hard edge, 255 / 32 = 8 levels at most.
        let nudge = CGSize(width: 1.0 / 64, height: 1.0 / 64)
        let expected = liveFrame(document, images, cache: nil, useObjectCache: false, translation: nudge)
        #expect(largestDifference(liveFrame(document, images, cache: cache, translation: nudge), expected) <= 8)
        #expect(cache.objectRasters[box.id]?.raster?.image === built)
    }

    @Test func redactionsAndHighlightersNeverGetARasterEvenWithTheShadowFlagOn() {
        // New objects carry shadow == true by default, whatever their kind.
        let redaction = shape(.redact(RedactObject(rect: CGRect(x: 10, y: 10, width: 20, height: 20), style: .pixelate, intensity: 5)),
                              shadow: true)
        let highlight = shape(.highlight(HighlightObject(points: [CGPoint(x: 8, y: 50), CGPoint(x: 56, y: 50)], rects: [], width: 10,
                                                         opacity: 0.5)), shadow: true)
        let (document, images) = TestBitmaps.document(base: TestBitmaps.noise(64, 64), objects: [redaction, highlight])
        let cache = RenderCache()
        for _ in 0..<4 { _ = liveFrame(document, images, cache: cache) }
        #expect(cache.objectRasters.isEmpty)
    }

    @Test func anObjectTooBigForARasterIsDrawnDirectlyAndNeverStored() {
        // 84 × 84 base pixels of object and shadow reach, at 50×: 4200 pixels a side, over the 16-megapixel cap. The context
        // is small and shows the object's bottom-right corner.
        let box = shape(.filledRectangle(CGRect(x: 0, y: 0, width: 64, height: 64)), shadow: true)
        let (document, images) = TestBitmaps.document(base: base, objects: [box])
        let corner = CGSize(width: -63 * 50, height: -63 * 50)
        let expected = liveFrame(document, images, cache: nil, useObjectCache: false, zoom: 50, translation: corner)
        let cache = RenderCache()
        for index in 1...3 {
            let actual = liveFrame(document, images, cache: cache, zoom: 50, translation: corner)
            #expect(largestDifference(actual, expected) <= 1, "frame \(index)")
            #expect(cache.objectRasters[box.id]?.raster == nil, "frame \(index)")
        }
    }

    @Test func anObjectWhoseShadowIsSwitchedOffLeavesTheObjectCache() {
        var box = shadowedBox()
        var (document, images) = TestBitmaps.document(base: base, objects: [box])
        let cache = RenderCache()
        for _ in 0..<2 { _ = liveFrame(document, images, cache: cache) }
        #expect(cache.objectRasters[box.id]?.raster != nil)
        box.style.shadow = false
        document.objects = [box]
        _ = liveFrame(document, images, cache: cache)
        #expect(cache.objectRasters[box.id] == nil)
    }

    @Test func aHiddenObjectLeavesTheObjectCacheAndComesBackBuiltAgain() {
        let box = shadowedBox()
        let (document, images) = TestBitmaps.document(base: base, objects: [box])
        let cache = RenderCache()
        for _ in 0..<2 { _ = liveFrame(document, images, cache: cache) }
        #expect(cache.objectRasters[box.id]?.raster != nil)
        // The text being edited inline is hidden from the canvas: its picture isn't kept while it is.
        _ = liveFrame(document, images, cache: cache, hiding: [box.id])
        #expect(cache.objectRasters[box.id] == nil)
        _ = liveFrame(document, images, cache: cache)
        #expect(cache.objectRasters[box.id]?.raster == nil)
        _ = liveFrame(document, images, cache: cache)
        #expect(cache.objectRasters[box.id]?.raster != nil)
    }

    @Test func anImageObjectIsRebuiltWhenItsPictureIsReplacedUnderTheSameName() {
        let ref = ImageRef(name: "images/sticker.png")
        let sticker = shape(.image(ImageObject(rect: CGRect(x: 12, y: 12, width: 30, height: 30), image: ref)), shadow: true)
        let (document, baseImages) = TestBitmaps.document(base: base, objects: [sticker])
        var redImages = baseImages
        redImages.set(TestBitmaps.solid(30, 30, TestBitmaps.red), for: ref)
        var blueImages = baseImages
        blueImages.set(TestBitmaps.solid(30, 30, TestBitmaps.blue), for: ref)
        let cache = RenderCache()
        for _ in 0..<2 { _ = liveFrame(document, redImages, cache: cache) }
        #expect(cache.objectRasters[sticker.id]?.raster != nil)
        // The object is unchanged, but the bitmap its name stands for is another one.
        let expected = liveFrame(document, blueImages, cache: nil, useObjectCache: false)
        for index in 1...3 {
            let actual = liveFrame(document, blueImages, cache: cache)
            #expect(largestDifference(actual, expected) <= 1, "frame \(index)")
            #expect((cache.objectRasters[sticker.id]?.raster != nil) == (index >= 2), "frame \(index)")
        }
    }

    @Test func aNonFiniteTransformIsDrawnDirectlyAndNeverCached() {
        let (document, images) = TestBitmaps.document(base: base, objects: [shadowedBox()])
        let context = TestBitmaps.flippedContext(64, 64)
        // Core Graphics keeps what it is given: a = infinity, b = NaN.
        context.scaleBy(x: .infinity, y: 1)
        let cache = RenderCache()
        for _ in 0..<3 { Renderer.draw(document, images: images, in: context, cache: cache, useObjectCache: true) }
        #expect(cache.objectRasters.isEmpty)
    }
}

struct ObjectRasterPutTests {
    /// A 10 × 10 red raster of an area that is 10 × 10 in the context's pixel space when it was made (`deviceSize`).
    private func raster(offset: CGVector = .zero, deviceSize: CGSize = CGSize(width: 10, height: 10)) -> ObjectRaster {
        ObjectRaster(image: TestBitmaps.solid(10, 10, TestBitmaps.red), area: CGRect(x: 0, y: 0, width: 10, height: 10), offset: offset,
                     deviceSize: deviceSize)
    }

    /// Whether the bitmap's pixel at device (x, y), counted from the bottom as a bitmap's own pixels are, is fully red.
    private func isRed(_ image: CGImage, _ x: Int, _ y: Int) -> Bool {
        TestBitmaps.pixel(image, x, image.height - 1 - y) == .init(r: 255, g: 0, b: 0, a: 255)
    }

    private func isUntouched(_ image: CGImage, _ x: Int, _ y: Int) -> Bool {
        TestBitmaps.pixel(image, x, image.height - 1 - y).a == 0
    }

    @Test func aRasterIsPutOnWholePixelsWhereItsAreaLandsBetweenThem() throws {
        // The area starts at 5.3 and the raster's first pixel sat 0.4 past that: 5.7, which is pixel 6. A raster drawn at
        // 5.7 itself would leave pixel 5 partly covered.
        let context = TestBitmaps.context(30, 30)
        context.translateBy(x: 5.3, y: 5.3)
        Renderer.put(raster(offset: CGVector(dx: 0.4, dy: 0.4)), in: context)
        let image = try #require(context.makeImage())
        #expect(isUntouched(image, 5, 10))
        #expect(isRed(image, 6, 10))
        #expect(isRed(image, 15, 10))
        #expect(isUntouched(image, 16, 10))
        #expect(isUntouched(image, 10, 5))
        #expect(isRed(image, 10, 6))
        #expect(isRed(image, 10, 15))
        #expect(isUntouched(image, 10, 16))
    }

    @Test func aRasterIsStretchedToTheSizeItsAreaHasNow() throws {
        // Made for an area 5 pixels across, put where the area is 10 across: twice the size.
        let context = TestBitmaps.context(40, 40)
        context.translateBy(x: 5, y: 5)
        Renderer.put(raster(deviceSize: CGSize(width: 5, height: 5)), in: context)
        let image = try #require(context.makeImage())
        #expect(isRed(image, 24, 24))
        #expect(isUntouched(image, 25, 24))
        #expect(isUntouched(image, 24, 25))
    }
}

struct ObjectRasterKeyTests {
    private let area = CGRect(x: 2, y: 2, width: 44, height: 40)

    private func key(_ ctm: CGAffineTransform = .identity, deviceScale: Double = 1, area: CGRect? = nil) -> ObjectRasterKey? {
        ObjectRasterKey(ctm: ctm, deviceScale: deviceScale, area: area ?? self.area)
    }

    @Test(arguments: [
        CGAffineTransform(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0),
        CGAffineTransform(a: 1, b: .nan, c: 0, d: 1, tx: 0, ty: 0),
        CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: .infinity, ty: 0),
        CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: .nan),
        // Finite numbers whose scale overflows.
        CGAffineTransform(a: 1.7e308, b: 1.7e308, c: 0, d: 1, tx: 0, ty: 0),
        // No scale at all.
        CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 5, ty: 5),
        CGAffineTransform(a: 1, b: 0, c: 0, d: 0, tx: 0, ty: 0),
    ])
    func aTransformThatCannotBeKeyedMakesNoKey(ctm: CGAffineTransform) {
        #expect(key(ctm) == nil)
    }

    @Test(arguments: [CGRect.null, CGRect.infinite, CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
                      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)])
    func anAreaThatIsNotFiniteMakesNoKey(area: CGRect) {
        #expect(key(area: area) == nil)
    }

    @Test(arguments: [Double.nan, .infinity]) func aBackingScaleThatIsNotFiniteMakesNoKey(deviceScale: Double) {
        #expect(key(deviceScale: deviceScale) == nil)
    }

    @Test func theKeyTellsApartWhatARasterIsMadeFor() {
        let plain = key()
        #expect(plain != nil)
        #expect(key(CGAffineTransform(scaleX: 1.0003, y: 1)) != plain)
        #expect(key(CGAffineTransform(scaleX: 1, y: 1.0003)) != plain)
        #expect(key(CGAffineTransform(scaleX: -1, y: 1)) != plain)
        #expect(key(CGAffineTransform(rotationAngle: .pi / 2)) != plain)
        #expect(key(deviceScale: 2) != plain)
        #expect(key(CGAffineTransform(translationX: 0.5, y: 0)) != plain)
        #expect(key(CGAffineTransform(translationX: 0, y: 0.5)) != plain)
    }

    @Test func theKeyIgnoresNoiseWholePixelPansAndTheSmallestFractions() {
        let plain = key()
        #expect(key(CGAffineTransform(scaleX: 1 + 1e-9, y: 1 - 1e-9)) == plain)
        #expect(key(CGAffineTransform(translationX: 7, y: -3)) == plain)
        #expect(key(CGAffineTransform(translationX: 1.0 / 64, y: -1.0 / 64)) == plain)
        // Almost a whole pixel is almost none.
        #expect(key(CGAffineTransform(translationX: 0.99, y: 0.99)) == plain)
        // A scale of 2 whose frame lands in the same fraction, however it got there.
        #expect(key(CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 3, ty: 3)) == key(CGAffineTransform(scaleX: 2, y: 2)))
    }
}
