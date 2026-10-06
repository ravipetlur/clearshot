import CoreGraphics
import Testing
@testable import CSCapture

struct SnapLinesTests {
    @Test func collectsWindowAndDisplayEdgesInsideTheBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let lines = SnapLines.from(windowFrames: [CGRect(x: 100, y: 200, width: 300, height: 100), CGRect(x: 5000, y: 0, width: 10, height: 10)],
                                   bounds: bounds)
        #expect(Set(lines.xs) == [0, 1000, 100, 400])
        #expect(Set(lines.ys) == [0, 800, 200, 300])
    }

    @Test func snapsOnlyWithinTheThreshold() {
        let lines = SnapLines(xs: [100], ys: [])
        #expect(lines.snapped(CGPoint(x: 106, y: 50), threshold: 8) == CGPoint(x: 100, y: 50))
        #expect(lines.snapped(CGPoint(x: 109, y: 50), threshold: 8) == CGPoint(x: 109, y: 50))
    }
}
