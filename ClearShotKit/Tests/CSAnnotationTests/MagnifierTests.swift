import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// The magnifier: its document form, its geometry, and above all that its callout never shows what a redaction hides.
struct MagnifierTests {
    private static let style = ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 2, shadow: false)

    private func magnifierObject(_ magnifier: MagnifierObject, id: UUID = UUID()) -> AnnotationObject {
        AnnotationObject(id: id, kind: .magnifier(magnifier), style: Self.style)
    }

    // MARK: Document

    /// A document from before magnifiers existed decodes as it always did, and one with a magnifier written without its
    /// optional keys takes the defaults.
    @Test func decodesDocumentsWithoutMagnifiers() throws {
        let json = #"""
        {"base":{"name":"original.png"},"baseSize":[100,50],"objects":[{"id":"00000000-0000-0000-0000-000000000001","kind":{"rectangle":{"_0":[[1,2],[3,4]]}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}}],"pixelScale":2,"version":1}
        """#
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: Data(json.utf8))
        #expect(decoded.objects.count == 1)
        #expect(decoded.objects[0].kind == .rectangle(CGRect(x: 1, y: 2, width: 3, height: 4)))

        let bare = #"{"source":[[0,0],[10,10]],"callout":[[20,0],[30,30]]}"#
        let magnifier = try JSONDecoder().decode(MagnifierObject.self, from: Data(bare.utf8))
        #expect(magnifier.shape == .circle)
        #expect(magnifier.border)
        #expect(magnifier.zoom == 3)
    }

    @Test func roundTrips() throws {
        var (document, _) = TestBitmaps.document(base: TestBitmaps.solid(100, 50, TestBitmaps.white))
        let magnifier = MagnifierObject(source: CGRect(x: 5, y: 6, width: 10, height: 8),
                                        callout: CGRect(x: 40, y: 2, width: 40, height: 32), shape: .roundedSquare, border: false)
        document.objects = [magnifierObject(magnifier)]
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded == document)
        #expect(decoded.isWellFormed)
        guard case .magnifier(let read) = decoded.objects[0].kind else { Issue.record("not a magnifier"); return }
        #expect(read.zoom == 4)
    }

    /// Settings saved before the magnifier existed keep their values and take its defaults.
    @Test func toolSettingsDefaultTheMagnifier() throws {
        let decoded = try JSONDecoder().decode(AnnotateToolSettings.self, from: Data(#"{"sizeLevel":4}"#.utf8))
        #expect(decoded.sizeLevel == 4)
        #expect(decoded.magnifierShape == .circle)
        #expect(decoded.magnifierBorder)
    }

    @Test func magnifierLetterIsFreeByDefault() {
        let keys = AnnotateToolKeys()
        #expect(keys.tool(for: "m") == .magnifier)
        #expect(keys.tool(for: "M") == .magnifier)
    }

    // MARK: Geometry

    @Test func zoomIsClamped() {
        let source = CGRect(x: 0, y: 0, width: 10, height: 10)
        let magnifier = MagnifierObject(source: source, callout: CGRect(x: 50, y: 50, width: 30, height: 30))
        #expect(MagnifierGeometry.withZoom(magnifier, 20).zoom == 8)
        #expect(MagnifierGeometry.withZoom(magnifier, 1).zoom == 2)
        #expect(MagnifierGeometry.withZoom(magnifier, 5).zoom == 5)
        #expect(MagnifierGeometry.withZoom(magnifier, .nan).zoom == MagnifierObject.defaultZoom)
        // Resized about the callout's middle.
        let zoomed = MagnifierGeometry.withZoom(magnifier, 5).callout
        #expect(zoomed.midX == 65 && zoomed.midY == 65)
    }

    /// Dragging a callout corner far out or in stops at 8× and 2×; the corner opposite stays put.
    @Test func resizingTheCalloutKeepsTheZoomInRange() {
        let magnifier = MagnifierObject(source: CGRect(x: 0, y: 0, width: 10, height: 5),
                                        callout: CGRect(x: 50, y: 50, width: 30, height: 15))
        let huge = MagnifierGeometry.dragging(.corner(.bottomRight), of: magnifier, to: CGPoint(x: 1000, y: 1000))
        #expect(huge.zoom == 8)
        #expect(huge.callout == CGRect(x: 50, y: 50, width: 80, height: 40))
        let tiny = MagnifierGeometry.dragging(.corner(.topLeft), of: magnifier, to: CGPoint(x: 79, y: 64))
        #expect(tiny.zoom == 2)
        #expect(tiny.callout.maxX == 80 && tiny.callout.maxY == 65)
        #expect(tiny.source == magnifier.source)
    }

    /// The source's corner handle changes the zoom from the other side, also within range; its middle handle moves it.
    @Test func resizingAndMovingTheSource() {
        let magnifier = MagnifierObject(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                                        callout: CGRect(x: 50, y: 0, width: 40, height: 40))
        let grown = MagnifierGeometry.dragging(.end, of: magnifier, to: CGPoint(x: 100, y: 100))
        #expect(grown.zoom == 2)
        #expect(grown.callout == magnifier.callout)
        let shrunk = MagnifierGeometry.dragging(.end, of: magnifier, to: CGPoint(x: 1, y: 1))
        #expect(shrunk.zoom == 8)
        let moved = MagnifierGeometry.dragging(.start, of: magnifier, to: CGPoint(x: 30, y: 30))
        #expect(moved.source == CGRect(x: 25, y: 25, width: 10, height: 10))
        #expect(moved.callout == magnifier.callout)
    }

    /// Moving the object moves its callout; the source stays on its pixels.
    @Test func movingMovesTheCallout() {
        let magnifier = MagnifierObject(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                                        callout: CGRect(x: 50, y: 0, width: 30, height: 30))
        let moved = ObjectGeometry.translated(magnifierObject(magnifier), by: CGVector(dx: 5, dy: 7))
        guard case .magnifier(let after) = moved.kind else { Issue.record("not a magnifier"); return }
        #expect(after.source == magnifier.source)
        #expect(after.callout == CGRect(x: 55, y: 7, width: 30, height: 30))
    }

    /// A new callout goes to the right at 3×, or to another side when that doesn't fit, inside the canvas.
    @Test func placesTheCalloutBesideTheSource() {
        let area = CGRect(x: 0, y: 0, width: 200, height: 100)
        let right = MagnifierGeometry.make(source: CGRect(x: 10, y: 40, width: 10, height: 10), within: area, gap: 5,
                                           shape: .circle, border: true)
        #expect(right.zoom == 3)
        #expect(right.callout == CGRect(x: 25, y: 30, width: 30, height: 30))
        let left = MagnifierGeometry.make(source: CGRect(x: 180, y: 40, width: 10, height: 10), within: area, gap: 5,
                                          shape: .circle, border: true)
        #expect(left.callout.maxX == 175)
        #expect(area.contains(left.callout))
        // Too big for any side: pushed inside as far as it goes.
        let big = MagnifierGeometry.make(source: CGRect(x: 80, y: 30, width: 30, height: 30), within: area, gap: 5,
                                         shape: .circle, border: true)
        #expect(big.callout.width == 90)
        #expect(area.contains(big.callout))
    }

    @Test func connectorRunsBetweenTheOutlines() throws {
        let magnifier = MagnifierObject(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                                        callout: CGRect(x: 40, y: -10, width: 30, height: 30), shape: .roundedSquare)
        let connector = try #require(MagnifierGeometry.connector(of: magnifier))
        #expect(connector.start == CGPoint(x: 10, y: 5))
        #expect(connector.end == CGPoint(x: 40, y: 5))
        let overlapping = MagnifierObject(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                                          callout: CGRect(x: 5, y: 0, width: 30, height: 30))
        #expect(MagnifierGeometry.connector(of: overlapping) == nil)
    }

    // MARK: Redaction safety

    private static let magenta = TestBitmaps.RGBA(r: 255, g: 0, b: 255, a: 255)
    private static let green = TestBitmaps.RGBA(r: 0, g: 255, b: 0, a: 255)

    /// 120 × 60 of blue, with a 20 × 20 one-pixel checker of magenta and green at (10, 20): the pattern to hide.
    private static func patterned() -> CGImage {
        let context = TestBitmaps.context(120, 60)
        context.setFillColor(TestBitmaps.blue)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        for y in 0..<20 {
            for x in 0..<20 {
                context.setFillColor((x + y).isMultiple(of: 2) ? CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1) : TestBitmaps.green)
                // CG is y-up: row y from the top is at 60 - 20 - y - 1.
                context.fill(CGRect(x: 10 + x, y: 60 - 20 - y - 1, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    /// The magnifier over the pattern, its callout to the right on plain blue.
    private static let patternMagnifier = MagnifierObject(source: CGRect(x: 10, y: 20, width: 20, height: 20),
                                                          callout: CGRect(x: 50, y: 0, width: 60, height: 60),
                                                          shape: .roundedSquare, border: false)

    private func redaction(_ style: RedactStyle) -> AnnotationObject {
        AnnotationObject(kind: .redact(RedactObject(rect: CGRect(x: 8, y: 18, width: 24, height: 24), style: style, intensity: 5)),
                         style: Self.style)
    }

    /// How many pixels of `image` are, or are near (each channel within 40), one of the pattern's two colors.
    private func patternPixels(in image: CGImage, within rect: CGRect? = nil) -> Int {
        let bytes = TestBitmaps.bytes(image)
        let area = rect ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var count = 0
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                let index = (y * image.width + x) * 4
                let pixel = TestBitmaps.RGBA(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2], a: bytes[index + 3])
                for color in [Self.magenta, Self.green] {
                    if abs(Int(pixel.r) - Int(color.r)) <= 40, abs(Int(pixel.g) - Int(color.g)) <= 40,
                       abs(Int(pixel.b) - Int(color.b)) <= 40 {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    private let calloutRect = CGRect(x: 50, y: 0, width: 60, height: 60)

    /// Without a redaction the callout shows the pattern, crisp: the check below can see it when it is there.
    @Test func calloutShowsThePictureMagnified() throws {
        let (document, images) = TestBitmaps.document(base: Self.patterned(), objects: [magnifierObject(Self.patternMagnifier)])
        let image = try #require(Renderer.render(document, images: images))
        // Inside the rounded corners, all of it is the pattern.
        #expect(patternPixels(in: image, within: calloutRect.insetBy(dx: 10, dy: 10)) == 40 * 40)
        // Nearest neighbour: each source pixel is a 3 × 3 square of one color. (80, 30) shows the checker's (10, 10).
        #expect(TestBitmaps.pixel(image, 80, 30) == Self.magenta)
        #expect(TestBitmaps.pixel(image, 82, 32) == Self.magenta)
        #expect(TestBitmaps.pixel(image, 83, 30) == Self.green)
        #expect(TestBitmaps.pixel(image, 80, 33) == Self.green)
    }

    @Test(arguments: [RedactStyle.blackOut, .pixelate, .secureBlur, .smoothBlur])
    func calloutNeverShowsWhatARedactionHides(style: RedactStyle) throws {
        let (document, images) = TestBitmaps.document(base: Self.patterned(),
                                                      objects: [magnifierObject(Self.patternMagnifier), redaction(style)])
        let image = try #require(Renderer.render(document, images: images))
        #expect(patternPixels(in: image) == 0)
        // The callout is drawn: black for Black out, and not the blue around it.
        let middle = TestBitmaps.pixel(image, 80, 30)
        #expect(middle != TestBitmaps.RGBA(r: 0, g: 0, b: 255, a: 255))
        if style == .blackOut { #expect(middle == TestBitmaps.RGBA(r: 0, g: 0, b: 0, a: 255)) }
    }

    /// The secrets check's masks are redactions too.
    @Test func calloutNeverShowsWhatASecretsMaskHides() throws {
        let mask = AnnotationObject.pixelateMask(rect: CGRect(x: 8, y: 18, width: 24, height: 24), intensity: 10)
        let (document, images) = TestBitmaps.document(base: Self.patterned(), objects: [mask, magnifierObject(Self.patternMagnifier)])
        let image = try #require(Renderer.render(document, images: images))
        #expect(patternPixels(in: image) == 0)
    }

    /// The same through the canvas's cached drawing, turned, with a background, and in a copy of the object alone.
    @Test(arguments: [RedactStyle.blackOut, .pixelate])
    func everyPathKeepsTheRedaction(style: RedactStyle) throws {
        let objects = [magnifierObject(Self.patternMagnifier), redaction(style)]
        var (document, images) = TestBitmaps.document(base: Self.patterned(), objects: objects)

        let cache = RenderCache()
        for _ in 0..<2 {
            let context = TestBitmaps.flippedContext(120, 60)
            Renderer.draw(document, images: images, in: context, cache: cache, deviceScale: 2, useObjectCache: true)
            #expect(patternPixels(in: try #require(context.makeImage())) == 0)
        }

        var turned = document
        turned.imageOps = [.rotateRight, .resize(width: 120, height: 240)]
        #expect(patternPixels(in: try #require(Renderer.render(turned, images: images))) == 0)

        var framed = document
        var backgroundStyle = BackgroundStyle.standard
        backgroundStyle.fill = .color(RGBAColor(red: 1, green: 1, blue: 1))
        framed.background = DocumentBackground(style: backgroundStyle)
        #expect(patternPixels(in: try #require(Renderer.render(framed, images: images))) == 0)

        let copy = try #require(Renderer.renderObjects([document.objects[0]], document: document, images: images))
        #expect(patternPixels(in: copy) == 0)

        // Positive control for the copy: without the redaction it does show the pattern.
        document.objects.removeLast()
        let plain = try #require(Renderer.renderObjects([document.objects[0]], document: document, images: images))
        #expect(patternPixels(in: plain) > 0)
    }

    /// A pasted image over the source shows in the callout, as it does on the canvas.
    @Test func calloutShowsPastedImages() throws {
        var (document, images) = TestBitmaps.document(base: TestBitmaps.solid(120, 60, TestBitmaps.blue))
        let pasted = ImageRef(name: "images/a.png")
        images = ImageStore([ImageRef.original.name: TestBitmaps.solid(120, 60, TestBitmaps.blue),
                             pasted.name: TestBitmaps.solid(4, 4, TestBitmaps.yellow)])
        document.objects = [AnnotationObject(kind: .image(ImageObject(rect: CGRect(x: 10, y: 20, width: 20, height: 20), image: pasted)),
                                             style: Self.style),
                            magnifierObject(Self.patternMagnifier)]
        let image = try #require(Renderer.render(document, images: images))
        #expect(TestBitmaps.pixel(image, 80, 30) == TestBitmaps.RGBA(r: 255, g: 255, b: 0, a: 255))
    }
}
