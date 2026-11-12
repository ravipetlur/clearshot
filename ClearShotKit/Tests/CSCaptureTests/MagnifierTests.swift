import CoreGraphics
import Testing
@testable import CSCapture

struct MagnifierTests {
    /// A grid centred on the pixel, kept inside the image at the edges.
    @Test func samplesAGridCenteredOnThePixelInsideTheImage() {
        let image = CGSize(width: 1000, height: 1000)
        #expect(Magnifier.sampleRect(centeredOn: CGPoint(x: 100, y: 100), gridSize: 15, imageSize: image)
            == CGRect(x: 93, y: 93, width: 15, height: 15))
        #expect(Magnifier.sampleRect(centeredOn: CGPoint(x: 2, y: 998), gridSize: 15, imageSize: image)
            == CGRect(x: 0, y: 985, width: 15, height: 15))
    }

    @Test func pixelUnderAPointUsesTheScale() {
        #expect(Magnifier.pixel(forLocalPoint: CGPoint(x: 10.7, y: 3.2), scale: 2) == CGPoint(x: 21, y: 6))
    }
}
