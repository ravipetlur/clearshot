import CoreGraphics
import Testing
@testable import CSCapture

struct PointerToolsTests {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)

    // MARK: Lens

    @Test func lensSitsBelowAndRightOfThePointer() {
        let frame = ZoomLens.frame(near: CGPoint(x: 200, y: 700), in: display)
        #expect(frame == CGRect(x: 224, y: 196, width: 480, height: 480))
    }

    @Test func lensFlipsLeftAtTheRightEdge() {
        let frame = ZoomLens.frame(near: CGPoint(x: 900, y: 700), in: display)
        #expect(frame.maxX == 876)
        #expect(!frame.contains(CGPoint(x: 900, y: 700)))
    }

    @Test func lensFlipsAboveAtTheBottomEdge() {
        let frame = ZoomLens.frame(near: CGPoint(x: 200, y: 100), in: display)
        #expect(frame.minY == 124)
        #expect(!frame.contains(CGPoint(x: 200, y: 100)))
    }

    @Test func lensStaysOnTheDisplayInEveryCorner() {
        let bounds = CGRect(x: -500, y: 100, width: 1200, height: 700)
        for x in stride(from: bounds.minX, through: bounds.maxX, by: 100) {
            for y in stride(from: bounds.minY, through: bounds.maxY, by: 100) {
                let frame = ZoomLens.frame(near: CGPoint(x: x, y: y), in: bounds)
                #expect(bounds.contains(frame))
                #expect(frame.size == CGSize(width: 480, height: 480))
            }
        }
    }

    @Test func lensShrinksToADisplaySmallerThanIt() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(ZoomLens.frame(near: CGPoint(x: 150, y: 100), in: tiny) == tiny)
    }

    @Test func lensSamplesAFortyEightPointSquare() {
        #expect(ZoomLens.sampleSide(scale: 1) == 48)
        #expect(ZoomLens.sampleSide(scale: 2) == 96)
        let rect = ZoomLens.sampleRect(centeredOn: CGPoint(x: 500, y: 400), scale: 2, imageSize: CGSize(width: 2000, height: 1600))
        #expect(rect.size == CGSize(width: 96, height: 96))
        #expect(rect.contains(CGPoint(x: 500, y: 400)))
    }

    @Test func markerFindsThePixelInsideTheLens() {
        let sample = CGRect(x: 100, y: 200, width: 48, height: 48)
        #expect(ZoomLens.markerRect(pixel: CGPoint(x: 100, y: 200), sample: sample, lensSide: 480)
            == CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(ZoomLens.markerRect(pixel: CGPoint(x: 112, y: 203), sample: sample, lensSide: 480)
            == CGRect(x: 120, y: 30, width: 10, height: 10))
        #expect(ZoomLens.markerRect(pixel: CGPoint(x: 148, y: 200), sample: sample, lensSide: 480) == nil)
    }

    // MARK: Precision

    @Test func precisionMovesAQuarterOfTheHardwareDelta() {
        var pointer = PrecisionPointer()
        // The system moved the pointer by the full 40 from (100, 100).
        let first = pointer.move(byHardwareDelta: CGVector(dx: 40, dy: -8), systemPointer: CGPoint(x: 140, y: 92), displays: [display])
        #expect(first == CGPoint(x: 110, y: 98))
        // The pointer now sits at the warped point; the next full delta is 40 again.
        let second = pointer.move(byHardwareDelta: CGVector(dx: 40, dy: 0), systemPointer: CGPoint(x: 150, y: 98), displays: [display])
        #expect(second == CGPoint(x: 120, y: 98))
    }

    @Test func precisionKeepsFractionsWhenTheSystemRounds() {
        var pointer = PrecisionPointer()
        var system = CGPoint(x: 100, y: 100)
        var last = system
        for _ in 0..<8 {
            // Each event: delta 1, the system puts the pointer one past where it rounded the last warp to.
            last = pointer.move(byHardwareDelta: CGVector(dx: 1, dy: 0), systemPointer: CGPoint(x: system.x + 1, y: system.y), displays: [display])
            system = CGPoint(x: last.x.rounded(), y: last.y.rounded())
        }
        #expect(last.x == 102)
    }

    @Test func precisionResyncsWhenThePointerWasMovedElsewhere() {
        var pointer = PrecisionPointer()
        _ = pointer.move(byHardwareDelta: CGVector(dx: 4, dy: 0), systemPointer: CGPoint(x: 104, y: 100), displays: [display])
        // A nudge put the pointer at (500, 500).
        let moved = pointer.move(byHardwareDelta: CGVector(dx: 4, dy: 0), systemPointer: CGPoint(x: 504, y: 500), displays: [display])
        #expect(moved == CGPoint(x: 501, y: 500))
    }

    @Test func precisionResetsAndStaysOnTheDisplays() {
        var pointer = PrecisionPointer()
        _ = pointer.move(byHardwareDelta: CGVector(dx: 4, dy: 0), systemPointer: CGPoint(x: 104, y: 100), displays: [display])
        #expect(pointer.anchor != nil)
        pointer.reset()
        #expect(pointer.anchor == nil)
        // From x = 12, a hardware delta of -80 asks for -8.
        _ = pointer.move(byHardwareDelta: CGVector(dx: 8, dy: 0), systemPointer: CGPoint(x: 18, y: 100), displays: [display])
        let clamped = pointer.move(byHardwareDelta: CGVector(dx: -80, dy: 0), systemPointer: CGPoint(x: -68, y: 100), displays: [display])
        #expect(clamped.x == 0)
    }

    // MARK: Nudge and bounds

    @Test func nudgeMovesOneOrTenPoints() {
        let point = CGPoint(x: 500, y: 400)
        #expect(PointerNudge.target(from: point, .up, large: false, displays: [display]) == CGPoint(x: 500, y: 401))
        #expect(PointerNudge.target(from: point, .down, large: false, displays: [display]) == CGPoint(x: 500, y: 399))
        #expect(PointerNudge.target(from: point, .left, large: true, displays: [display]) == CGPoint(x: 490, y: 400))
        #expect(PointerNudge.target(from: point, .right, large: true, displays: [display]) == CGPoint(x: 510, y: 400))
    }

    @Test func nudgeStopsAtTheDisplayEdges() {
        #expect(PointerNudge.target(from: CGPoint(x: 3, y: 400), .left, large: true, displays: [display]).x == 0)
        #expect(PointerNudge.target(from: CGPoint(x: 998, y: 400), .right, large: true, displays: [display]).x == 999)
        #expect(PointerNudge.target(from: CGPoint(x: 500, y: 798), .up, large: true, displays: [display]).y == 800)
        #expect(PointerNudge.target(from: CGPoint(x: 500, y: 3), .down, large: true, displays: [display]).y == 1)
    }

    @Test func nudgeCrossesToANeighbouringDisplay() {
        let target = PointerNudge.target(from: CGPoint(x: 999, y: 400), .right, large: false, displays: [display, right])
        #expect(target == CGPoint(x: 1000, y: 400))
    }

    @Test func clampLeavesAPointOnADisplayAlone() {
        #expect(PointerBounds.clamp(CGPoint(x: 10, y: 800), to: [display]) == CGPoint(x: 10, y: 800))
    }

    @Test func clampPullsAnOffscreenPointToTheNearestDisplay() {
        #expect(PointerBounds.clamp(CGPoint(x: 5000, y: 400), to: [display, right]) == CGPoint(x: 1999, y: 400))
    }
}
