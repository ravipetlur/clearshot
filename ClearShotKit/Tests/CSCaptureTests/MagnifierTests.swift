import CoreGraphics
import Testing
@testable import CSCapture

struct MagnifierTests {
    @Test func samplesAGridCenteredOnThePixel() {
        let rect = Magnifier.sampleRect(centeredOn: CGPoint(x: 100, y: 100), gridSize: 15, imageSize: CGSize(width: 1000, height: 1000))
        #expect(rect == CGRect(x: 93, y: 93, width: 15, height: 15))
    }

    @Test func staysInsideTheImageAtTheEdges() {
        let rect = Magnifier.sampleRect(centeredOn: CGPoint(x: 2, y: 998), gridSize: 15, imageSize: CGSize(width: 1000, height: 1000))
        #expect(rect == CGRect(x: 0, y: 985, width: 15, height: 15))
    }

    @Test func pixelUnderAPointUsesTheScale() {
        #expect(Magnifier.pixel(forLocalPoint: CGPoint(x: 10.7, y: 3.2), scale: 2) == CGPoint(x: 21, y: 6))
    }
}
