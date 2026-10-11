import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// The picture the secrets check reads in Annotate (Mask Sensitive Info): the document's picture as it is now, turned,
/// cropped, resized and flipped, without the annotations drawn over it (a mask is a redaction, which lies under them) and
/// without the background around it, and where each of its pixels lies in the base, which the masks are in.
///
/// Each test renders a document whose base has one blue block at a known place, finds the block in the picture render, and
/// checks that a rectangle around it, taken to the base the way `MaskPlan` takes a finding's mask there, covers the block's
/// own pixels: a mask over text found in a turned or cropped picture lands on that text in the base.
struct PictureRenderTests {
    /// 120 x 80, white, with a pure blue block here.
    private let marker = CGRect(x: 30, y: 20, width: 24, height: 10)

    private func base() -> CGImage {
        let context = TestBitmaps.context(120, 80)
        context.setFillColor(TestBitmaps.white)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        context.setFillColor(TestBitmaps.blue)
        // CG is y-up.
        context.fill(CGRect(x: marker.minX, y: 80 - marker.maxY, width: marker.width, height: marker.height))
        return context.makeImage()!
    }

    private func document(scale: Double = 1) -> (AnnotationDocument, ImageStore) {
        var (document, images) = TestBitmaps.document(base: base())
        document.pixelScale = scale
        return (document, images)
    }

    private let red = RGBAColor(red: 1, green: 0, blue: 0)

    /// A solid red box, drawn over part of the block and past it.
    private func annotation(_ rect: CGRect = CGRect(x: 40, y: 15, width: 40, height: 30)) -> AnnotationObject {
        AnnotationObject(kind: .filledRectangle(rect), style: ObjectStyle(color: red, lineWidth: 1, shadow: false))
    }

    private func background(padding: Double = 20, autoBalance: Bool = false) -> DocumentBackground {
        DocumentBackground(style: BackgroundStyle(fill: .color(RGBAColor(red: 0.6, green: 0.6, blue: 0.6)), padding: padding, inset: 0,
                                                  insetColor: .color(RGBAColor(red: 1, green: 1, blue: 1)), shadow: 0, corners: 0,
                                                  autoBalance: autoBalance, alignment: .center, ratio: .auto))
    }

    /// The smallest rectangle holding every pixel of `image` that `matches` (pixels, top-left origin), or nil with none.
    private func bounds(in image: CGImage, where matches: (_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Bool) -> CGRect? {
        let bytes = TestBitmaps.bytes(image)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                guard bytes[index + 3] == 255, matches(bytes[index], bytes[index + 1], bytes[index + 2]) else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func blueBounds(in image: CGImage) -> CGRect? { bounds(in: image) { $0 < 60 && $1 < 60 && $2 > 200 } }
    private func redBounds(in image: CGImage) -> CGRect? { bounds(in: image) { $0 > 200 && $1 < 60 && $2 < 60 } }

    /// What a mask over the block is, found in the picture: the block's box with 6 px around it, as a finding's box has a margin.
    /// Taken to the base as `MaskPlan` takes it (`applying(toBase)`), it must cover the block's own pixels there.
    private func expectMaskLandsOnTheBlock(_ document: AnnotationDocument, _ images: ImageStore, tolerance: CGFloat = 1.5,
                                           sourceLocation: SourceLocation = #_sourceLocation) throws {
        let picture = try #require(Renderer.renderPicture(of: document, images: images), sourceLocation: sourceLocation)
        #expect(picture.mapping.renderedSize == CGSize(width: picture.image.width, height: picture.image.height),
                "the mapping is of the render that was made", sourceLocation: sourceLocation)
        let seen = try #require(blueBounds(in: picture.image), "the block isn't in the picture", sourceLocation: sourceLocation)
        let toBase = picture.mapping.toBase
        let mask = seen.insetBy(dx: -6, dy: -6).applying(toBase).standardized
        #expect(mask.contains(marker.insetBy(dx: tolerance, dy: tolerance)), "\(mask) doesn't cover \(marker)", sourceLocation: sourceLocation)
        // And it is over the block, not just a large rectangle: the block fills the middle of it. Its margin is 6 pixels of the
        // picture, which is `unit` pixels of the base each (a resize), plus what a part-pixel canvas or a resize rounds.
        let unit = abs(toBase.a * toBase.d - toBase.b * toBase.c).squareRoot()
        let slack = 6 * unit + 2 * tolerance
        #expect(marker.insetBy(dx: -slack, dy: -slack).contains(mask), "\(mask) is far larger than \(marker)", sourceLocation: sourceLocation)
    }

    // MARK: What is left in the picture

    @Test func theAnnotationsAreLeftOutAndTheBlockIsWhole() throws {
        var (document, images) = document()
        document.objects = [annotation()]
        let full = try #require(Renderer.render(document, images: images))
        #expect(redBounds(in: full) != nil, "the annotation is drawn in the full render")
        let picture = try #require(Renderer.renderPicture(of: document, images: images))
        #expect(redBounds(in: picture.image) == nil)
        #expect(blueBounds(in: picture.image) == marker)
    }

    @Test func aRedactionStaysSoItsTextIsNotFoundAgain() throws {
        var (document, images) = document()
        document.objects = [AnnotationObject.pixelateMask(rect: marker.insetBy(dx: -4, dy: -4), intensity: 10), annotation()]
        let picture = try #require(Renderer.renderPicture(of: document, images: images))
        #expect(blueBounds(in: picture.image) == nil, "the block is pixelated away")
        #expect(redBounds(in: picture.image) == nil)
    }

    @Test func theBackgroundIsLeftOutSoThePictureIsTheCanvasAlone() throws {
        var (document, images) = document()
        document.background = background()
        let full = try #require(Renderer.render(document, images: images))
        #expect(full.width > 120 && full.height > 80, "the frame is around the picture")
        let picture = try #require(Renderer.renderPicture(of: document, images: images))
        #expect(picture.image.width == 120 && picture.image.height == 80)
        #expect(picture.mapping.toBase == .identity)
        #expect(blueBounds(in: picture.image) == marker)
    }

    @Test func aDocumentWithoutItsBaseHasNoPicture() {
        var (document, images) = document()
        document.base = ImageRef(name: "missing.png")
        _ = images
        #expect(Renderer.renderPicture(of: document, images: images) == nil)
    }

    // MARK: The document reduced to its picture

    @Test func theReducedDocumentKeepsRedactionsAndTheGeometryAndNothingElse() {
        var (document, _) = document(scale: 2)
        let mask = AnnotationObject.pixelateMask(rect: CGRect(x: 1, y: 2, width: 30, height: 12), intensity: 4)
        let other = AnnotationObject.pixelateMask(rect: CGRect(x: 50, y: 2, width: 30, height: 12), intensity: 6)
        document.objects = [annotation(), mask, annotation(CGRect(x: 0, y: 0, width: 5, height: 5)), other]
        document.background = background()
        document.imageOps = [.rotateLeft, .resize(width: 70, height: 100)]
        document.canvasRect = CGRect(x: 2, y: 3, width: 40, height: 50)
        document.canvasFill = .color(red)
        let reduced = document.pictureOnly
        #expect(reduced.objects == [mask, other], "the redactions, in their order")
        #expect(reduced.background == nil)
        #expect(reduced.base == document.base && reduced.baseSize == document.baseSize && reduced.pixelScale == 2)
        #expect(reduced.imageOps == document.imageOps && reduced.canvasRect == document.canvasRect && reduced.canvasFill == document.canvasFill)
    }

    // MARK: A mask lands on the text, whatever was done to the picture

    @Test func aPlainPicturesMaskIsOverTheBlock() throws {
        let (document, images) = document()
        try expectMaskLandsOnTheBlock(document, images, tolerance: 0)
    }

    @Test(arguments: [ImageOp.rotateLeft, .rotateRight, .flipHorizontal, .flipVertical])
    func aTurnedOrFlippedPicturesMaskIsOverTheBlockInTheBase(op: ImageOp) throws {
        var (document, images) = document()
        document.imageOps = [op]
        // With an annotation and a background, which the picture leaves out.
        document.objects = [annotation()]
        document.background = background()
        try expectMaskLandsOnTheBlock(document, images, tolerance: 0)
    }

    @Test func aPictureTurnedTwiceAndFlippedIsStillOverTheBlock() throws {
        var (document, images) = document()
        document.imageOps = [.rotateRight, .flipHorizontal, .rotateLeft, .flipVertical, .rotateRight]
        try expectMaskLandsOnTheBlock(document, images, tolerance: 0)
    }

    @Test func aCroppedPicturesMaskIsOverTheBlockInTheBase() throws {
        var (document, images) = document()
        document.canvasRect = CGRect(x: 10, y: 5, width: 80, height: 60)
        document.objects = [annotation()]
        let picture = try #require(Renderer.renderPicture(of: document, images: images))
        #expect(picture.image.width == 80 && picture.image.height == 60, "the render is the crop")
        try expectMaskLandsOnTheBlock(document, images, tolerance: 0)
    }

    @Test func aCropOfATurnedPictureIsOverTheBlockInTheBase() throws {
        var (document, images) = document()
        document.imageOps = [.rotateRight]
        // Output pixels: the turned picture is 80 x 120.
        document.canvasRect = CGRect(x: 5, y: 10, width: 60, height: 100)
        document.background = background(autoBalance: true)
        document.objects = [annotation()]
        try expectMaskLandsOnTheBlock(document, images, tolerance: 0)
    }

    @Test func aCropTightOnTheBlockStillHasTheBlockWhole() throws {
        // A crop that cuts at the block's edge: the mask is cut to the picture, so what it is cut to is the block.
        var (document, images) = document()
        document.canvasRect = marker
        let picture = try #require(Renderer.renderPicture(of: document, images: images))
        #expect(blueBounds(in: picture.image) == CGRect(origin: .zero, size: marker.size))
        #expect(CGRect(origin: .zero, size: marker.size).applying(picture.mapping.toBase) == marker)
    }

    @Test func aResizedPicturesMaskIsOverTheBlockInTheBase() throws {
        var (document, images) = document()
        document.imageOps = [.resize(width: 60, height: 40)]
        let picture = try #require(Renderer.renderPicture(of: document, images: images))
        #expect(picture.image.width == 60 && picture.image.height == 40)
        try expectMaskLandsOnTheBlock(document, images, tolerance: 1.5)
    }

    @Test func aCanvasOnPartPixelsMapsToTheSameWholePixels() throws {
        var (document, images) = document()
        document.canvasRect = CGRect(x: 10.4, y: 5.6, width: 79.7, height: 59.9)
        try expectMaskLandsOnTheBlock(document, images, tolerance: 1)
    }

    @Test func anExpandedCanvasMapsBackToo() throws {
        var (document, images) = document()
        document.canvasRect = CGRect(x: -20, y: -10, width: 170, height: 110)
        document.canvasFill = .color(RGBAColor(red: 1, green: 1, blue: 1))
        try expectMaskLandsOnTheBlock(document, images, tolerance: 0)
    }

    @Test func everythingAtOnceOnARetinaCaptureMapsBack() throws {
        var (document, images) = document(scale: 2)
        document.imageOps = [.rotateLeft, .resize(width: 70, height: 100)]
        document.canvasRect = CGRect(x: -4, y: 3, width: 82, height: 96)
        document.canvasFill = .color(RGBAColor(red: 1, green: 1, blue: 1))
        document.background = background(padding: 12)
        document.objects = [annotation()]
        try expectMaskLandsOnTheBlock(document, images, tolerance: 2)
    }
}
