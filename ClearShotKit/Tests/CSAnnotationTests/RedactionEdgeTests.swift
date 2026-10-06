import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// No original pixel under a redaction may reach any output. Wherever the picture is drawn at a scale other than 1:1 (a
/// resize op in an export, a zoomed or Retina canvas), each output pixel is resampled from a footprint of base pixels,
/// and one just outside a redaction must take nothing of that footprint from the original pixels under it.
struct RedactionEdgeTests {
    enum Path: String, Sendable {
        case export, canvas
    }

    /// Where the document is drawn, and whether it has a background.
    struct Setup: Sendable, CustomTestStringConvertible {
        var path: Path
        var background: Bool

        var testDescription: String {
            "\(path.rawValue) \(background ? "with" : "without") a background"
        }

        static let all = [Setup(path: .export, background: false), Setup(path: .export, background: true),
                          Setup(path: .canvas, background: false), Setup(path: .canvas, background: true)]
    }

    /// Down, up by a fraction, and up by whole factors.
    static let scales = [0.5, 1.5, 2, 4]
    static let side = 120
    /// The redacted region, in base pixels, away from the picture's edges.
    static let region = CGRect(x: 40, y: 40, width: 40, height: 40)
    static let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

    /// A blue frame around the picture: nothing red or green in it, its shadow included.
    static let blueFrame: BackgroundStyle = {
        var style = BackgroundStyle.standard
        style.fill = .color(RGBAColor(red: 0, green: 0, blue: 1))
        return style
    }()

    /// Blue all round; under the redaction, green inside a 4-pixel red rim. So the region's outermost pixels, the ones a
    /// neighbour's footprint reaches, are red: no colour Black Out or the picture beside the region shows.
    static func picture() -> CGImage {
        let context = TestBitmaps.context(side, side)
        context.setFillColor(TestBitmaps.blue)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let flipped = CGRect(x: region.minX, y: CGFloat(side) - region.maxY, width: region.width, height: region.height)
        context.setFillColor(TestBitmaps.red)
        context.fill(flipped)
        context.setFillColor(TestBitmaps.green)
        context.fill(flipped.insetBy(dx: 4, dy: 4))
        return context.makeImage()!
    }

    static func redaction(_ style: RedactStyle, _ rect: CGRect = region) -> AnnotationObject {
        AnnotationObject(id: id, kind: .redact(RedactObject(rect: rect, style: style, intensity: 5)),
                         style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
    }

    /// The picture with the region already replaced by what the redaction shows there, black or its effect: what the
    /// pixels beside the redaction may be made of, besides the picture around it.
    static func redactedPicture(_ style: RedactStyle) throws -> CGImage {
        let original = picture()
        let context = TestBitmaps.context(side, side)
        context.draw(original, in: CGRect(x: 0, y: 0, width: side, height: side))
        let flipped = CGRect(x: region.minX, y: CGFloat(side) - region.maxY, width: region.width, height: region.height)
        if style == .blackOut {
            context.setFillColor(TestBitmaps.black)
            context.fill(flipped)
        } else {
            // `redaction(style)`'s effect, from the same id and value.
            let redact = RedactObject(rect: region, style: style, intensity: 5)
            let effect = try #require(Redaction.image(for: redact, region: region, base: original, pixelScale: 1, seed: id))
            context.setBlendMode(.copy)
            context.draw(effect, in: flipped)
        }
        return try #require(context.makeImage())
    }

    /// A document over `base`, resized by `resize` when given (an export's scale), framed when `background`.
    static func document(base: CGImage, objects: [AnnotationObject], background: Bool, resize: Double?)
        -> (AnnotationDocument, ImageStore) {
        var (document, images) = TestBitmaps.document(base: base, objects: objects)
        if let resize {
            let resized = Int((Double(base.width) * resize).rounded())
            document.imageOps = [.resize(width: resized, height: resized)]
        }
        if background { document.background = DocumentBackground(style: blueFrame) }
        return (document, images)
    }

    /// The document as `path` draws it at `scale`, with the device pixels the redaction's region covers there. An export
    /// is `Renderer.render` of the document (which the caller has resized); the canvas is `Renderer.draw`, with its cache,
    /// into a bitmap `scale` times the output's size.
    static func drawn(_ document: AnnotationDocument, _ images: ImageStore, path: Path, scale: Double) throws
        -> (image: CGImage, covered: (x: Range<Int>, y: Range<Int>)) {
        let output = Renderer.outputBounds(of: document, images: images, cache: nil).integral
        let image: CGImage
        let device: Double
        switch path {
        case .export:
            image = try #require(Renderer.render(document, images: images))
            device = 1
        case .canvas:
            let context = TestBitmaps.flippedContext(Int(output.width * scale), Int(output.height * scale))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -output.minX, y: -output.minY)
            Renderer.draw(document, images: images, in: context, cache: RenderCache(), useObjectCache: true)
            image = try #require(context.makeImage())
            device = scale
        }
        let mapped = region.applying(document.transform.transform)
        let covered = CGRect(x: (mapped.minX - output.minX) * device, y: (mapped.minY - output.minY) * device,
                             width: mapped.width * device, height: mapped.height * device)
        return (image, (Int(covered.minX.rounded(.down))..<Int(covered.maxX.rounded(.up)),
                        Int(covered.minY.rounded(.down))..<Int(covered.maxY.rounded(.up))))
    }

    /// The largest red or green value of any pixel: the original's colours, which nothing else in these documents has.
    static func largestOriginalColor(_ image: CGImage) -> Int {
        let bytes = TestBitmaps.bytes(image)
        return stride(from: 0, to: bytes.count, by: 4).map { max(Int(bytes[$0]), Int(bytes[$0 + 1])) }.max() ?? 0
    }

    /// How many pixels outside `covered` differ by more than 1 in any channel, and the largest difference.
    static func differences(_ a: CGImage, _ b: CGImage, outside covered: (x: Range<Int>, y: Range<Int>)) -> (count: Int, largest: Int) {
        let first = TestBitmaps.bytes(a), second = TestBitmaps.bytes(b)
        var count = 0, largest = 0
        for y in 0..<a.height {
            for x in 0..<a.width where !(covered.x.contains(x) && covered.y.contains(y)) {
                let index = (y * a.width + x) * 4
                let difference = (0..<4).map { abs(Int(first[index + $0]) - Int(second[index + $0])) }.max() ?? 0
                if difference > 1 { count += 1 }
                largest = max(largest, difference)
            }
        }
        return (count, largest)
    }

    @Test(arguments: [RedactStyle.blackOut, .pixelate], Setup.all)
    func nothingBesideARedactionShowsWhatItHides(style: RedactStyle, setup: Setup) throws {
        let reference = try Self.redactedPicture(style)
        for scale in Self.scales {
            let resize = setup.path == .export ? scale : nil
            let (document, images) = Self.document(base: Self.picture(), objects: [Self.redaction(style)],
                                                   background: setup.background, resize: resize)
            // The same output from a picture whose region already shows the redaction, with no original under it.
            let (expected, expectedImages) = Self.document(base: reference, objects: [], background: setup.background,
                                                           resize: resize)
            let actual = try Self.drawn(document, images, path: setup.path, scale: scale)
            let wanted = try Self.drawn(expected, expectedImages, path: setup.path, scale: scale)
            #expect(actual.image.width == wanted.image.width && actual.image.height == wanted.image.height)
            let found = Self.differences(actual.image, wanted.image, outside: actual.covered)
            #expect(found.count == 0, "at \(scale)×, \(found.count) pixels beside the redaction differ, by up to \(found.largest)")
            if style == .blackOut {
                let original = Self.largestOriginalColor(actual.image)
                #expect(original <= 1, "at \(scale)×, the original's colour shows at \(original)/255")
            }
        }
    }

    @Test(arguments: scales)
    func theBlurredScreenshotCarriesNoTrace(scale: Double) throws {
        // Red bands 8 pixels wide, each blacked out, between blue ones 2 pixels wide: every blue pixel lies beside a
        // redaction, so whatever of the red they took would be a large share of what the blur averages.
        let context = TestBitmaps.context(Self.side, Self.side)
        context.setFillColor(TestBitmaps.blue)
        context.fill(CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        context.setFillColor(TestBitmaps.red)
        let bands = stride(from: 0, to: Self.side, by: 10).map { CGRect(x: $0, y: 0, width: 8, height: Self.side) }
        bands.forEach { context.fill($0) }
        let redactions = bands.map { band in
            AnnotationObject(kind: .redact(RedactObject(rect: band, style: .blackOut, intensity: 5)),
                             style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
        }
        var (document, images) = Self.document(base: try #require(context.makeImage()), objects: redactions, background: true,
                                               resize: scale)
        document.background?.style.fill = .blurredScreenshot
        let blurred = try #require(Renderer.contentAnalysis(for: document, images: images, cache: nil).blurred)
        let inBlur = Self.largestOriginalColor(blurred)
        #expect(inBlur <= 1, "at \(scale)×, the blur shows the original's colour at \(inBlur)/255")
        let rendered = try #require(Renderer.render(document, images: images))
        let inRender = Self.largestOriginalColor(rendered)
        #expect(inRender <= 1, "at \(scale)×, the render shows the original's colour at \(inRender)/255")
    }

    @Test(arguments: [false, true])
    func theCanvasKeepsTheRedactedBaseWhileItsRedactionsAreUnchanged(background: Bool) throws {
        let rectangle = AnnotationObject(kind: .filledRectangle(CGRect(x: 4, y: 4, width: 10, height: 10)),
                                         style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
        var (document, images) = Self.document(base: Self.picture(), objects: [Self.redaction(.pixelate), rectangle],
                                               background: background, resize: nil)
        let cache = RenderCache()
        func frame() -> CGImage? {
            let context = TestBitmaps.flippedContext(400, 400)
            context.scaleBy(x: 1.5, y: 1.5)
            context.translateBy(x: 64, y: 64)
            Renderer.draw(document, images: images, in: context, cache: cache, useObjectCache: true)
            return cache.redactedBase?.image
        }
        let first = try #require(frame())
        #expect(first !== images[document.base])
        #expect(first.width == Self.side && first.height == Self.side)
        #expect(frame() === first)
        // Another object changing doesn't make it again.
        document.objects[1] = ObjectGeometry.translated(rectangle, by: CGVector(dx: 2, dy: 0))
        #expect(frame() === first)

        // A redaction moved, restyled, or at another pixel scale (bigger blocks) does.
        document.objects[0].kind = .redact(RedactObject(rect: Self.region.offsetBy(dx: 1, dy: 0), style: .pixelate, intensity: 5))
        let moved = try #require(frame())
        #expect(moved !== first)
        document.objects[0].kind = .redact(RedactObject(rect: Self.region.offsetBy(dx: 1, dy: 0), style: .blackOut, intensity: 5))
        let restyled = try #require(frame())
        #expect(restyled !== moved)
        document.pixelScale = 2
        let rescaled = try #require(frame())
        #expect(rescaled !== restyled)

        // Over another base it is made again; an effect that fails isn't kept, so the next frame tries again; and without
        // redactions there is none to keep.
        document.objects[0] = Self.redaction(.pixelate)
        let before = try #require(frame())
        images.set(Self.picture(), for: document.base)
        let rebased = try #require(frame())
        #expect(rebased !== before)
        cache.effect = { _, _, _, _, _ in nil }
        document.objects[0].kind = .redact(RedactObject(rect: Self.region, style: .pixelate, intensity: 9))
        #expect(frame() == nil)
        document.objects.removeFirst()
        #expect(frame() == nil)
    }
}
