import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// The picture the pixel tools read, as shown and without the annotations, and its pixels read in base pixels.
struct PicturePixelsTests {
    private let red = RGBAColor(red: 1, green: 0, blue: 0)
    private let green = RGBAColor(red: 0, green: 1, blue: 0)
    private let blue = RGBAColor(red: 0, green: 0, blue: 1)
    private let black = RGBAColor(red: 0, green: 0, blue: 0)

    /// 40 × 20, a quarter each: red top-left, green top-right, blue bottom-left, white bottom-right.
    private func quarters(ops: [ImageOp] = [], canvas: CGRect? = nil) -> (AnnotationDocument, ImageStore) {
        var (document, images) = TestBitmaps.document(base: TestBitmaps.quadrants(40, 20, topLeft: TestBitmaps.red,
                                                                                  topRight: TestBitmaps.green,
                                                                                  bottomLeft: TestBitmaps.blue,
                                                                                  bottomRight: TestBitmaps.white))
        document.imageOps = ops
        document.canvasRect = canvas
        return (document, images)
    }

    private func styled(_ kind: ObjectKind, color: RGBAColor = RGBAColor(red: 1, green: 0, blue: 0)) -> AnnotationObject {
        AnnotationObject(kind: kind, style: ObjectStyle(color: color, lineWidth: 4, shadow: false))
    }

    @Test func readsBasePixelsOfAPlainPicture() throws {
        let (document, images) = quarters()
        let pixels = try #require(PicturePixels.make(of: document, images: images))
        #expect(pixels.sampler.size == CGSize(width: 40, height: 20))
        #expect(pixels.color(at: CGPoint(x: 5, y: 5)) == red)
        #expect(pixels.color(at: CGPoint(x: 35, y: 5)) == green)
        #expect(pixels.color(at: CGPoint(x: 5, y: 15)) == blue)
        #expect(pixels.color(at: CGPoint(x: 35, y: 15)) == .white)
        #expect(pixels.color(at: CGPoint(x: 45, y: 5)) == nil)
    }

    /// After a turn the sampler holds the picture as shown, and base points still find their own color.
    @Test func followsATurn() throws {
        let (document, images) = quarters(ops: [.rotateRight])
        let pixels = try #require(PicturePixels.make(of: document, images: images))
        #expect(pixels.sampler.size == CGSize(width: 20, height: 40))
        // Turned clockwise, the base's top-left quarter is at the top right.
        #expect(pixels.sampler.color(at: CGPoint(x: 15, y: 5)) == red)
        #expect(pixels.pixelPoint(fromBase: CGPoint(x: 5, y: 5)) == CGPoint(x: 15, y: 5))
        for (point, color) in [(CGPoint(x: 5, y: 5), red), (CGPoint(x: 35, y: 5), green), (CGPoint(x: 5, y: 15), blue)] {
            #expect(pixels.color(at: point) == color)
        }
    }

    @Test func followsAFlipAndAResize() throws {
        let (document, images) = quarters(ops: [.flipHorizontal, .resize(width: 80, height: 40)])
        let pixels = try #require(PicturePixels.make(of: document, images: images))
        #expect(pixels.sampler.size == CGSize(width: 80, height: 40))
        #expect(pixels.sampler.color(at: CGPoint(x: 75, y: 5)) == red)
        #expect(pixels.color(at: CGPoint(x: 5, y: 5)) == red)
        #expect(pixels.color(at: CGPoint(x: 35, y: 15)) == .white)
    }

    /// The sampler starts at the canvas; base points outside it are off the picture.
    @Test func followsACrop() throws {
        let (document, images) = quarters(canvas: CGRect(x: 10, y: 5, width: 20, height: 10))
        let pixels = try #require(PicturePixels.make(of: document, images: images))
        #expect(pixels.sampler.size == CGSize(width: 20, height: 10))
        #expect(pixels.color(at: CGPoint(x: 15, y: 7)) == red)
        #expect(pixels.color(at: CGPoint(x: 25, y: 12)) == .white)
        #expect(pixels.color(at: CGPoint(x: 5, y: 5)) == nil)
    }

    /// Past the picture, an expanded canvas shows its fill.
    @Test func includesTheCanvasFill() throws {
        var (document, images) = quarters(canvas: CGRect(x: -10, y: 0, width: 50, height: 20))
        document.canvasFill = .color(black)
        let pixels = try #require(PicturePixels.make(of: document, images: images))
        #expect(pixels.color(at: CGPoint(x: -5, y: 5)) == black)
        #expect(pixels.color(at: CGPoint(x: 5, y: 5)) == red)
    }

    /// Shapes and the background are left out; what a redaction hides stays hidden; pictures placed on the canvas are in.
    @Test func leavesOutAnnotationsButNotRedactionsOrImages() throws {
        let base = TestBitmaps.solid(40, 20, TestBitmaps.white)
        let pasted = ImageRef(name: "images/blue.png")
        var (document, _) = TestBitmaps.document(base: base, objects: [
            styled(.filledRectangle(CGRect(x: 0, y: 0, width: 10, height: 10))),
            styled(.redact(RedactObject(rect: CGRect(x: 20, y: 0, width: 10, height: 10), style: .blackOut, intensity: 5))),
            styled(.image(ImageObject(rect: CGRect(x: 0, y: 10, width: 10, height: 10), image: pasted))),
            styled(.spotlight(SpotlightObject(rect: CGRect(x: 30, y: 10, width: 5, height: 5), shape: .rectangle, opacity: 0.8))),
        ])
        document.background = DocumentBackground(style: BackgroundStyle(fill: .color(green), padding: 20, inset: 0,
                                                                        insetColor: .color(.white), shadow: 0, corners: 0,
                                                                        autoBalance: false, alignment: .center, ratio: .auto))
        let images = ImageStore([ImageRef.original.name: base, pasted.name: TestBitmaps.solid(10, 10, TestBitmaps.blue)])
        let pixels = try #require(PicturePixels.make(of: document, images: images))
        #expect(pixels.sampler.size == CGSize(width: 40, height: 20))
        #expect(pixels.color(at: CGPoint(x: 5, y: 5)) == .white)
        #expect(pixels.color(at: CGPoint(x: 25, y: 5)) == black)
        #expect(pixels.color(at: CGPoint(x: 5, y: 15)) == blue)
        #expect(pixels.color(at: CGPoint(x: 37, y: 17)) == .white)
    }

    @Test func areasAreReadInBasePixels() throws {
        let (document, images) = quarters(ops: [.rotateLeft])
        let pixels = try #require(PicturePixels.make(of: document, images: images))
        #expect(pixels.average(in: CGRect(x: 0, y: 0, width: 20, height: 10)) == red)
        let half = try #require(pixels.average(in: CGRect(x: 0, y: 0, width: 40, height: 10)))
        #expect(abs(half.red - 0.5) < 1e-9 && abs(half.green - 0.5) < 1e-9)
        // Blue is the darkest of the four, by luminance.
        #expect(pixels.darkest(in: CGRect(x: 0, y: 0, width: 40, height: 20)) == blue)
        #expect(pixels.darkest(around: CGPoint(x: 20, y: 10), side: 4) == blue)
    }

    /// Directions are as shown: after a turn, down on screen runs along the base's x.
    @Test func edgesRunAsShown() throws {
        let (document, images) = quarters(ops: [.rotateRight])
        let pixels = try #require(PicturePixels.make(of: document, images: images))
        let edge = try #require(pixels.edge(from: CGPoint(x: 5, y: 5), direction: .down, tolerance: 0))
        // The start is shown at (15, 5); red runs down to row 19, green starts at row 20.
        #expect(edge.distance == 15)
        #expect(edge.boundary == CGPoint(x: 20, y: 4.5))
        #expect(!edge.reachedBorder)
        let border = try #require(pixels.edge(from: CGPoint(x: 5, y: 5), direction: .right, tolerance: 0))
        #expect(border.distance == 5 && border.reachedBorder)
        // The picture's right edge is the base's top.
        #expect(border.boundary == CGPoint(x: 5.5, y: 0))
        #expect(pixels.edge(from: CGPoint(x: -5, y: 5), direction: .down, tolerance: 0) == nil)
    }

    @Test func floodFillBoundsComeBackInBasePixels() throws {
        let (document, images) = quarters(ops: [.rotateRight])
        let pixels = try #require(PicturePixels.make(of: document, images: images))
        #expect(pixels.floodFillBounds(from: CGPoint(x: 5, y: 5), tolerance: 0, maxPixels: 1000) == CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(pixels.floodFillBounds(from: CGPoint(x: 5, y: 5), tolerance: 0, maxPixels: 100) == nil)
    }

    @Test func identityChangesWithThePictureOnly() {
        let (document, _) = quarters()
        var labelled = document
        labelled.objects.append(styled(.arrow(ArrowShape(start: .zero, end: CGPoint(x: 10, y: 10), style: .standard))))
        #expect(labelled.picturePixelsIdentity == document.picturePixelsIdentity)
        var turned = document
        turned.imageOps = [.rotateLeft]
        #expect(turned.picturePixelsIdentity != document.picturePixelsIdentity)
        var redacted = document
        redacted.objects.append(styled(.redact(RedactObject(rect: CGRect(x: 0, y: 0, width: 5, height: 5), style: .pixelate, intensity: 5))))
        #expect(redacted.picturePixelsIdentity != document.picturePixelsIdentity)
        var pasted = document
        pasted.objects.append(styled(.image(ImageObject(rect: CGRect(x: 0, y: 0, width: 5, height: 5), image: ImageRef(name: "images/a.png")))))
        #expect(pasted.picturePixelsIdentity != document.picturePixelsIdentity)
        #expect(pasted.picturePixelsIdentity.picture == document.picturePixelsIdentity.picture)
    }

    @Test func noPictureWithoutTheBaseImage() {
        let (document, _) = quarters()
        #expect(PicturePixels.make(of: document, images: ImageStore([:])) == nil)
    }
}
