import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// Where a pixel of a document's render lies in the base: what takes a finding of the secrets check, which is in the render's
/// pixels (a capture's working copy), to the base pixels an annotation object is in. Each test renders a document whose base
/// has one blue block at a known place, finds the block in the render, and checks the mapping takes it back.
struct RenderedBaseMappingTests {
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

    /// A background of plain grey around the picture, so nothing but the block is blue.
    private func background(padding: Double = 20, ratio: BackgroundRatio = .auto, autoBalance: Bool = false) -> DocumentBackground {
        DocumentBackground(style: BackgroundStyle(fill: .color(RGBAColor(red: 0.6, green: 0.6, blue: 0.6)), padding: padding, inset: 0,
                                                  insetColor: .color(RGBAColor(red: 1, green: 1, blue: 1)), shadow: 0, corners: 0,
                                                  autoBalance: autoBalance, alignment: .center, ratio: ratio))
    }

    /// The smallest rectangle holding every pure blue pixel of `image` (pixels, top-left origin), or nil with none.
    private func blueBounds(in image: CGImage) -> CGRect? {
        let bytes = TestBitmaps.bytes(image)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                guard bytes[index + 3] == 255, bytes[index + 2] > 200, bytes[index] < 60, bytes[index + 1] < 60 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The block as the render shows it, taken back to the base, against where the block is in the base.
    private func expectMapsBack(_ document: AnnotationDocument, _ images: ImageStore, tolerance: CGFloat = 1.5,
                                sourceLocation: SourceLocation = #_sourceLocation) throws {
        let render = try #require(Renderer.render(document, images: images), sourceLocation: sourceLocation)
        let mapping = try #require(Renderer.baseMapping(of: document, images: images), sourceLocation: sourceLocation)
        #expect(mapping.renderedSize == CGSize(width: render.width, height: render.height), sourceLocation: sourceLocation)
        let seen = try #require(blueBounds(in: render), "the block isn't in the render", sourceLocation: sourceLocation)
        let back = seen.applying(mapping.toBase).standardized
        #expect(abs(back.minX - marker.minX) <= tolerance && abs(back.maxX - marker.maxX) <= tolerance
                && abs(back.minY - marker.minY) <= tolerance && abs(back.maxY - marker.maxY) <= tolerance,
                "\(back) is not \(marker)", sourceLocation: sourceLocation)
    }

    // MARK: Nothing changed

    /// A plain document's render is the base, and so is a Retina one's: pixelScale 2 makes the base 120 x 80 pixels, 60 x 40
    /// points, and the render and the mapping are in pixels.
    @Test(arguments: [1.0, 2.0])
    func anUnchangedDocumentsRenderIsTheBase(scale: Double) throws {
        let (document, images) = document(scale: scale)
        let mapping = try #require(Renderer.baseMapping(of: document, images: images))
        #expect(mapping.toBase == .identity)
        #expect(mapping.renderedSize == CGSize(width: 120, height: 80))
        try expectMapsBack(document, images, tolerance: 0)
    }

    // MARK: Changes that are undone

    enum Change: String, CaseIterable {
        // Image operations.
        case rotateLeft, rotateRight, flipHorizontal, flipVertical
        case severalOperationsInARow
        case aResize
        case aResizeAfterATurn
        // The canvas.
        case aCroppedCanvas
        case anExpandedCanvas
        /// The render's bounds are rounded out to whole pixels (as `Renderer.render` does), and the mapping with them.
        case aCanvasOnPartPixels
        /// Output pixels: the turned picture is 80 x 120.
        case aCropAfterATurn
        // A background.
        case aBackgroundsFrame
        case aBackgroundOnARetinaCapture
        case aBackgroundWithATallRatio
        case aBackgroundWithAWideRatio
        /// Auto-balance trims uniform margins off the picture first, which moves the frame: the white around the block goes.
        case aBackgroundWithAutoBalance
        case everythingAtOnce

        /// How far the block may land from where it is in the base, in base pixels.
        var tolerance: CGFloat {
            switch self {
            case .rotateLeft, .rotateRight, .flipHorizontal, .flipVertical, .severalOperationsInARow, .aCroppedCanvas,
                 .anExpandedCanvas, .aCropAfterATurn, .aBackgroundsFrame: 0
            case .aCanvasOnPartPixels, .aBackgroundOnARetinaCapture, .aBackgroundWithATallRatio, .aBackgroundWithAWideRatio,
                 .aBackgroundWithAutoBalance: 1
            case .aResize, .aResizeAfterATurn: 1.5
            case .everythingAtOnce: 2
            }
        }
    }

    /// The document with `change` made to it.
    private func changed(_ change: Change) -> (AnnotationDocument, ImageStore) {
        let retina = [.aBackgroundOnARetinaCapture, .everythingAtOnce].contains(change)
        var (document, images) = document(scale: retina ? 2 : 1)
        switch change {
        case .rotateLeft: document.imageOps = [.rotateLeft]
        case .rotateRight: document.imageOps = [.rotateRight]
        case .flipHorizontal: document.imageOps = [.flipHorizontal]
        case .flipVertical: document.imageOps = [.flipVertical]
        case .severalOperationsInARow: document.imageOps = [.rotateRight, .flipHorizontal, .rotateLeft, .flipVertical]
        case .aResize: document.imageOps = [.resize(width: 60, height: 40)]
        case .aResizeAfterATurn: document.imageOps = [.rotateRight, .resize(width: 50, height: 90)]
        case .aCroppedCanvas: document.canvasRect = CGRect(x: 10, y: 5, width: 80, height: 60)
        case .anExpandedCanvas:
            document.canvasRect = CGRect(x: -20, y: -10, width: 170, height: 110)
            document.canvasFill = .color(RGBAColor(red: 1, green: 1, blue: 1))
        case .aCanvasOnPartPixels: document.canvasRect = CGRect(x: 10.4, y: 5.6, width: 79.7, height: 59.9)
        case .aCropAfterATurn:
            document.imageOps = [.rotateRight]
            document.canvasRect = CGRect(x: 5, y: 10, width: 60, height: 100)
        case .aBackgroundsFrame: document.background = background()
        case .aBackgroundOnARetinaCapture: document.background = background(padding: 17.3)
        case .aBackgroundWithATallRatio: document.background = background(ratio: .r9x16)
        case .aBackgroundWithAWideRatio: document.background = background(ratio: .r16x9)
        case .aBackgroundWithAutoBalance: document.background = background(autoBalance: true)
        case .everythingAtOnce:
            document.imageOps = [.rotateLeft, .resize(width: 70, height: 100)]
            document.canvasRect = CGRect(x: -4, y: 3, width: 82, height: 96)
            document.canvasFill = .color(RGBAColor(red: 1, green: 1, blue: 1))
            document.background = background(padding: 12, ratio: .r4x3)
        }
        return (document, images)
    }

    @Test(arguments: Change.allCases)
    func aChangeIsUndone(_ change: Change) throws {
        let (document, images) = changed(change)
        let mapping = try #require(Renderer.baseMapping(of: document, images: images))
        switch change {
        case .aResize: #expect(mapping.renderedSize == CGSize(width: 60, height: 40))
        case .aCroppedCanvas: #expect(mapping.renderedSize == CGSize(width: 80, height: 60))
        case .anExpandedCanvas: #expect(mapping.renderedSize == CGSize(width: 170, height: 110))
        case .aBackgroundsFrame:
            #expect(mapping.renderedSize.width > 120 && mapping.renderedSize.height > 80, "the frame is around the picture")
        default: break
        }
        try expectMapsBack(document, images, tolerance: change.tolerance)
    }

    // MARK: Nothing to map

    @Test func aDocumentWithoutItsBaseHasNoMapping() {
        var (document, images) = document()
        document.base = ImageRef(name: "missing.png")
        _ = images
        #expect(Renderer.baseMapping(of: document, images: images) == nil)
    }
}
