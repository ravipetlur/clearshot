import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// Fit to content, the flat-region ⌘-click and the padding that go with a pixel selection.
@MainActor
struct SmartSelectionTests {
    /// A 60 × 40 sampler: `background` everywhere, with the rect (20, 10, 20 × 10) painted `button` and, inside it, a 1-pixel
    /// `border` ring when asked.
    private func sampler(button: UInt8 = 0, border: UInt8? = nil, background: UInt8 = 255) -> PixelSampler {
        var bytes = [UInt8](repeating: 255, count: 60 * 40 * 4)
        for y in 0..<40 {
            for x in 0..<60 {
                var value = background
                if (20..<40).contains(x), (10..<20).contains(y) {
                    value = button
                    if let border, x == 20 || x == 39 || y == 10 || y == 19 { value = border }
                }
                let index = (y * 60 + x) * 4
                bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
            }
        }
        return PixelSampler(width: 60, height: 40, premultipliedRGBA: bytes)!
    }

    private let button = CGRect(x: 20, y: 10, width: 20, height: 10)
    private let rough = CGRect(x: 10, y: 5, width: 40, height: 30)

    @Test func aRoughSelectionAroundAButtonFitsToTheButton() {
        #expect(PixelFit.fitted(rough, in: sampler(), tolerance: 8) == button)
    }

    @Test func anAlreadyTightSelectionStaysPut() {
        #expect(PixelFit.fitted(button, in: sampler(), tolerance: 8) == button)
    }

    @Test func aFlatSelectionHasNothingToFitTo() {
        let flat = CGRect(x: 0, y: 0, width: 15, height: 8)
        #expect(PixelFit.fitted(flat, in: sampler(), tolerance: 8) == flat)
        #expect(PixelFit.fitted(flat, in: sampler(), tolerance: 8, edges: [.left]) == flat)
    }

    @Test func aSelectionPartlyOutsideThePictureIsFittedWithinIt() {
        #expect(PixelFit.fitted(CGRect(x: 10, y: 5, width: 100, height: 100), in: sampler(), tolerance: 8) == button)
    }

    @Test func aBorderOfAnotherColourStopsTheFit() {
        #expect(PixelFit.fitted(rough, in: sampler(button: 200, border: 100), tolerance: 8) == button)
    }

    @Test func toleranceLetsNoiseThrough() {
        var bytes = [UInt8](repeating: 255, count: 10 * 10 * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) where (i / 4) % 3 == 0 { bytes[i] = 250 }
        let noisy = PixelSampler(width: 10, height: 10, premultipliedRGBA: bytes)!
        let area = CGRect(x: 0, y: 0, width: 10, height: 10)
        // Flat within the tolerance, so nothing to fit to; flat to the pixel it is not, but still nothing is lost to it.
        #expect(PixelFit.fitted(area, in: noisy, tolerance: 8) == area)
        #expect(PixelFit.fitted(area, in: noisy, tolerance: 0).width >= 1)
    }

    @Test func oneEdgeFitsOnAlone() {
        let sampler = sampler()
        #expect(PixelFit.fitted(rough, in: sampler, tolerance: 8, edges: [.left]) == CGRect(x: 20, y: 5, width: 30, height: 30))
        #expect(PixelFit.fitted(rough, in: sampler, tolerance: 8, edges: [.top]) == CGRect(x: 10, y: 10, width: 40, height: 25))
        #expect(PixelFit.fitted(rough, in: sampler, tolerance: 8, edges: [.bottom]) == CGRect(x: 10, y: 5, width: 40, height: 15))
        #expect(PixelFit.fitted(rough, in: sampler, tolerance: 8, edges: [.right]) == CGRect(x: 10, y: 5, width: 30, height: 30))
    }

    @Test func anEdgeOnContentDoesNotMove() {
        let area = CGRect(x: 25, y: 5, width: 20, height: 30)
        #expect(PixelFit.fitted(area, in: sampler(), tolerance: 8, edges: [.left]) == area)
    }

    // MARK: Through the picture pixels

    private func pixels(rotated: Bool) throws -> PicturePixels {
        let base = TestBitmaps.solid(60, 40, TestBitmaps.white)
        let object = AnnotationObject(kind: .redact(RedactObject(rect: button, style: .blackOut, intensity: 5)),
                                      style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 4, shadow: false))
        var (document, images) = TestBitmaps.document(base: base, objects: [object])
        if rotated { document = document.applying(.rotateRight) }
        return try #require(PicturePixels.make(of: document, images: images))
    }

    @Test(arguments: [false, true]) func fitsInBasePixelsWhateverTheTurn(rotated: Bool) throws {
        let pixels = try pixels(rotated: rotated)
        #expect(pixels.fitBounds(of: rough, tolerance: 8) == button)
        #expect(pixels.fitBounds(of: rough, tolerance: 8, edges: [.left]) == CGRect(x: 20, y: 5, width: 30, height: 30))
        #expect(pixels.fitBounds(of: rough, tolerance: 8, edges: [.bottom]) == CGRect(x: 10, y: 5, width: 40, height: 15))
    }

    // MARK: The editor

    @Test func aClickOnTheBackgroundSelectsTheWholeFlatRegion() async throws {
        let h = EditorHarness()
        let result = await h.editor.selectFlatRegion(at: CGPoint(x: 10, y: 10))
        #expect(result == .selected)
        #expect(h.editor.pixelSelection == CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    @Test func aClickOffThePictureSelectsNothing() async throws {
        let h = EditorHarness()
        #expect(await h.editor.selectFlatRegion(at: CGPoint(x: -20, y: 10)) == .nothing)
        #expect(h.editor.pixelSelection == nil)
        #expect(h.editor.pixelNotice == nil)
    }

    @Test func fittingAFlatSelectionChangesNothing() async throws {
        let h = EditorHarness()
        h.editor.selectPixels(CGRect(x: 10, y: 10, width: 30, height: 20))
        #expect(await h.editor.fitPixelSelectionToContent() == false)
        #expect(h.editor.pixelSelection == CGRect(x: 10, y: 10, width: 30, height: 20))
    }

    @Test func fittingWithNoSelectionDoesNothing() async {
        let h = EditorHarness()
        #expect(await h.editor.fitPixelSelectionToContent() == false)
    }

    /// Padding is `growPixelSelection`: every side, clamped to the picture.
    @Test func paddingGrowsEverySideAndStopsAtThePicture() {
        let h = EditorHarness()
        h.editor.selectPixels(CGRect(x: 5, y: 40, width: 20, height: 10))
        h.editor.growPixelSelection(by: 10)
        #expect(h.editor.pixelSelection == CGRect(x: 0, y: 30, width: 35, height: 30))
        h.editor.growPixelSelection(by: 1)
        #expect(h.editor.pixelSelection == CGRect(x: 0, y: 29, width: 36, height: 32))
    }
}
