import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import CSAnnotation

/// Renders of documents without a background, pinned byte for byte from the renderer as it was before the background
/// was drawn. A document without a background must render exactly as it did, so a digest that changes means the
/// no-background path changed. Don't regenerate them.
///
/// One was re-pinned on purpose: `spotlightAndRedaction` drawn at 2×, once the base came to be drawn with its
/// redactions in it. The ring of pixels beside the redaction, which the 2× draw resamples, now blends the pixelate
/// effect instead of the original under it; every other pixel, and every other digest, stayed the same.
struct RenderRegressionTests {
    enum Case: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case fullDocument, transparentExpanded, shadowsRotated, spotlightAndRedaction

        var testDescription: String { rawValue }
    }

    /// SHA-256 of each case's pixels: through `Renderer.render`, and through `Renderer.draw` into a 2× bitmap.
    static let expected: [Case: (render: String, draw: String)] = [
        .fullDocument: (render: "0af1f05aea061bc32d33cdf5df76916179ffecf780d8006ff1590716b3626d74",
                        draw: "a1cbb96277196713c07bc862ecbdd0702806fe8b2f7b7bb5a36fd37c083cbf8a"),
        .transparentExpanded: (render: "d172b4dcf67d7dfbf9177e87667c8b1b3b94048669a769477d09a33fe7aa90e3",
                               draw: "629f5de8e71f5af9f9cf2e76db40d3feef5ede17a514f064936ae04dd405cd6a"),
        .shadowsRotated: (render: "37f0ac884f144fded01729e9e01101675d31919adb4bbd52b89f9335987c710c",
                          draw: "6098cf4584dfc030cb7b214b9dfada019ea2bb3891ee2672ea46c6f2628b6d39"),
        .spotlightAndRedaction: (render: "cdeac269a1ba1d7ca38ad3894c9df2f95c55316a8f14808783020be8da7cb06b",
                                 draw: "d18a7cba87d88ad40efbe336bda76c6097b70c835e67e89922cb10fb30fe5ee1"),
    ]

    static func document(_ test: Case) -> (AnnotationDocument, ImageStore) {
        let style = ObjectStyle(color: RGBAColor(red: 0.9, green: 0.2, blue: 0.1), lineWidth: 6, shadow: true)
        switch test {
        case .fullDocument:
            // Every object kind, image operations, a canvas past the picture and a translucent fill.
            let images = ImageStore([
                ImageRef.original.name: TestBitmaps.noise(800, 600),
                "images/a.png": TestBitmaps.quadrants(8, 8, topLeft: TestBitmaps.red, topRight: TestBitmaps.green,
                                                      bottomLeft: TestBitmaps.blue, bottomRight: TestBitmaps.yellow),
            ])
            return (AnnotationDocumentTests.fullDocument(), images)
        case .transparentExpanded:
            // A window-like picture: opaque blocks on transparency. Its edge is transparent, so Auto fills with nothing and
            // the expanded canvas stays transparent too.
            let base = TestBitmaps.transparent(64, 64, blocks: [CGRect(x: 8, y: 10, width: 20, height: 14),
                                                                CGRect(x: 30, y: 28, width: 26, height: 30)],
                                               color: TestBitmaps.red)
            var (document, images) = TestBitmaps.document(base: base)
            document.canvasRect = CGRect(x: -12, y: -8, width: 90, height: 80)
            document.canvasFill = .auto
            return (document, images)
        case .shadowsRotated:
            let rectangle = AnnotationObject(kind: .rectangle(CGRect(x: 20, y: 16, width: 50, height: 30)), style: style)
            let arrow = AnnotationObject(kind: .arrow(ArrowShape(start: CGPoint(x: 10, y: 70), end: CGPoint(x: 100, y: 20),
                                                                 style: .standard)), style: style)
            var (document, images) = TestBitmaps.document(base: TestBitmaps.solid(120, 80, TestBitmaps.white),
                                                          objects: [rectangle, arrow])
            document.pixelScale = 2
            document.imageOps = [.rotateRight]
            return (document, images)
        case .spotlightAndRedaction:
            let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
            let spotlight = AnnotationObject(kind: .spotlight(SpotlightObject(rect: CGRect(x: 30, y: 12, width: 40, height: 30),
                                                                              shape: .ellipse, opacity: 0.5)), style: style)
            let redaction = AnnotationObject(id: id, kind: .redact(RedactObject(rect: CGRect(x: 6, y: 40, width: 50, height: 26),
                                                                                style: .pixelate, intensity: 4)), style: style)
            return TestBitmaps.document(base: TestBitmaps.noise(96, 72), objects: [spotlight, redaction])
        }
    }

    /// The document drawn the way a Retina canvas draws it: `Renderer.draw` into a bitmap twice the canvas's size, user
    /// space output pixels with y down, a device scale of 2 and no cache.
    static func drawnAtTwoX(_ document: AnnotationDocument, _ images: ImageStore) -> CGImage? {
        let canvas = document.canvasBounds.integral
        let context = TestBitmaps.flippedContext(Int(canvas.width) * 2, Int(canvas.height) * 2)
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: -canvas.minX, y: -canvas.minY)
        Renderer.draw(document, images: images, in: context, deviceScale: 2)
        return context.makeImage()
    }

    /// SHA-256, in hex, of the image's size, pixel format and raw pixel bytes, row by row without any row padding.
    static func digest(_ image: CGImage) -> String {
        var hash = SHA256()
        let format = "\(image.width)×\(image.height) \(image.bitsPerComponent)/\(image.bitsPerPixel) \(image.bitmapInfo.rawValue) "
            + "\(image.colorSpace?.name as String? ?? "-")"
        hash.update(data: Data(format.utf8))
        if let data = image.dataProvider?.data as Data? {
            let rowBytes = image.width * image.bitsPerPixel / 8
            for row in 0..<image.height {
                let start = row * image.bytesPerRow
                hash.update(data: data[start..<start + rowBytes])
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test(arguments: Case.allCases)
    func renderRegressionDigestsAreUnchanged(_ test: Case) throws {
        let (document, images) = Self.document(test)
        let expected = try #require(Self.expected[test])
        let rendered = try #require(Renderer.render(document, images: images))
        let drawn = try #require(Self.drawnAtTwoX(document, images))
        #expect(Self.digest(rendered) == expected.render, "render")
        #expect(Self.digest(drawn) == expected.draw, "draw at 2×")
    }
}
