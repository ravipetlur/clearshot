import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

struct PixelSelectionGeometryTests {
    private let bounds = CGSize(width: 100, height: 80)

    @Test func aDragRoundsOutwardToWholePixels() {
        let rect = PixelSelection.between(CGPoint(x: 10.4, y: 20.6), CGPoint(x: 30.2, y: 40.1), in: bounds)
        #expect(rect == CGRect(x: 10, y: 20, width: 21, height: 21))
    }

    @Test func aDragInAnyDirectionMakesTheSameSelection() {
        let a = CGPoint(x: 5, y: 6), b = CGPoint(x: 25, y: 16)
        #expect(PixelSelection.between(a, b, in: bounds) == PixelSelection.between(b, a, in: bounds))
    }

    @Test func aDragPastThePictureIsCutToIt() {
        #expect(PixelSelection.between(CGPoint(x: 90, y: 70), CGPoint(x: 150, y: 120), in: bounds) == CGRect(x: 90, y: 70, width: 10, height: 10))
        #expect(PixelSelection.between(CGPoint(x: -30, y: -5), CGPoint(x: 10, y: 10), in: bounds) == CGRect(x: 0, y: 0, width: 11, height: 11))
    }

    @Test func aDragOutsideThePictureSelectsNothing() {
        #expect(PixelSelection.between(CGPoint(x: 120, y: 10), CGPoint(x: 150, y: 30), in: bounds) == nil)
        #expect(PixelSelection.between(CGPoint(x: -20, y: 10), CGPoint(x: -5, y: 30), in: bounds) == nil)
        #expect(PixelSelection.between(CGPoint(x: Double.nan, y: 0), CGPoint(x: 5, y: 5), in: bounds) == nil)
    }

    @Test func aSelectionIsNeverSmallerThanAPixel() {
        #expect(PixelSelection.clamped(CGRect(x: 100, y: 80, width: 0, height: 0), in: bounds) == CGRect(x: 99, y: 79, width: 1, height: 1))
        #expect(PixelSelection.clamped(CGRect(x: 10, y: 10, width: 0, height: 0), in: bounds) == CGRect(x: 10, y: 10, width: 1, height: 1))
    }

    @Test func nudgingMovesBySteps() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(PixelSelection.nudged(rect, by: CGVector(dx: 1, dy: 0), in: bounds) == CGRect(x: 11, y: 10, width: 20, height: 20))
        #expect(PixelSelection.nudged(rect, by: CGVector(dx: -10, dy: 10), in: bounds) == CGRect(x: 0, y: 20, width: 20, height: 20))
    }

    @Test func nudgingStopsAtTheEdgesWithoutShrinking() {
        let rect = CGRect(x: 85, y: 5, width: 10, height: 10)
        #expect(PixelSelection.nudged(rect, by: CGVector(dx: 10, dy: -10), in: bounds) == CGRect(x: 90, y: 0, width: 10, height: 10))
    }

    @Test func resizingMovesTheRightAndBottomEdges() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(PixelSelection.resized(rect, by: CGVector(dx: 1, dy: -1), in: bounds) == CGRect(x: 10, y: 10, width: 21, height: 19))
        #expect(PixelSelection.resized(rect, by: CGVector(dx: 10, dy: 10), in: bounds) == CGRect(x: 10, y: 10, width: 30, height: 30))
    }

    @Test func resizingStopsAtOnePixelAndAtThePictureEdge() {
        let rect = CGRect(x: 90, y: 70, width: 5, height: 5)
        #expect(PixelSelection.resized(rect, by: CGVector(dx: -10, dy: -10), in: bounds) == CGRect(x: 90, y: 70, width: 1, height: 1))
        #expect(PixelSelection.resized(rect, by: CGVector(dx: 10, dy: 10), in: bounds) == CGRect(x: 90, y: 70, width: 10, height: 10))
    }

    @Test func growingMovesEverySideOut() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(PixelSelection.grown(rect, by: 1, in: bounds) == CGRect(x: 9, y: 9, width: 22, height: 22))
        #expect(PixelSelection.grown(rect, by: -1, in: bounds) == CGRect(x: 11, y: 11, width: 18, height: 18))
        #expect(PixelSelection.grown(rect, by: 10, in: bounds) == CGRect(x: 0, y: 0, width: 40, height: 40))
    }

    @Test func growingStopsAtEachEdgeSeparately() {
        let rect = CGRect(x: 2, y: 10, width: 20, height: 20)
        #expect(PixelSelection.grown(rect, by: 10, in: bounds) == CGRect(x: 0, y: 0, width: 32, height: 40))
    }

    @Test func shrinkingStopsAtAPixelInTheMiddle() {
        let rect = CGRect(x: 10, y: 10, width: 4, height: 7)
        let shrunk = PixelSelection.grown(rect, by: -10, in: bounds)
        #expect(shrunk.width == 1 && shrunk.height == 1)
        #expect(shrunk.minX == 12 && shrunk.minY == 13)
    }

    @Test func aHandleDragKeepsTheOppositeSide() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(PixelSelection.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 50.4, y: 45), in: bounds) == CGRect(x: 10, y: 10, width: 40, height: 35))
        #expect(PixelSelection.dragging(.edge(.left), of: rect, to: CGPoint(x: 4, y: 99), in: bounds) == CGRect(x: 4, y: 10, width: 26, height: 20))
        #expect(PixelSelection.dragging(.corner(.topLeft), of: rect, to: CGPoint(x: -20, y: 0), in: bounds) == CGRect(x: 0, y: 0, width: 30, height: 30))
    }

    @Test func aHandleDraggedPastTheOppositeSideFlipsTheSelection() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(PixelSelection.dragging(.edge(.right), of: rect, to: CGPoint(x: 4, y: 0), in: bounds) == CGRect(x: 4, y: 10, width: 6, height: 20))
    }

    @Test func aHandleDragStaysInsideThePicture() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(PixelSelection.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 500, y: 500), in: bounds) == CGRect(x: 10, y: 10, width: 90, height: 70))
    }
}

struct ZoomGeometryTests {
    private let limits = 0.05...8.0

    @Test func aRectFillsTheWindowLessTheMargin() {
        let target = ZoomGeometry.fitting(CGRect(x: 100, y: 50, width: 200, height: 100), in: CGSize(width: 432, height: 232), margin: 16, limits: limits)
        #expect(target == ZoomTarget(magnification: 2, center: CGPoint(x: 200, y: 100)))
    }

    @Test func theTighterSideSetsTheZoom() {
        let target = ZoomGeometry.fitting(CGRect(x: 0, y: 0, width: 100, height: 400), in: CGSize(width: 1000, height: 832), margin: 16, limits: limits)
        #expect(target?.magnification == 2)
    }

    @Test func aTinyRectStopsAtTheMostZoom() {
        let target = ZoomGeometry.fitting(CGRect(x: 10, y: 10, width: 1, height: 1), in: CGSize(width: 800, height: 600), limits: limits)
        #expect(target?.magnification == 8)
        #expect(target?.center == CGPoint(x: 10.5, y: 10.5))
    }

    @Test func aHugeRectStopsAtTheLeastZoom() {
        let target = ZoomGeometry.fitting(CGRect(x: 0, y: 0, width: 100_000, height: 100_000), in: CGSize(width: 800, height: 600), limits: limits)
        #expect(target?.magnification == 0.05)
    }

    @Test func noAreaOrNoRoomGivesNoZoom() {
        #expect(ZoomGeometry.fitting(CGRect(x: 0, y: 0, width: 0, height: 10), in: CGSize(width: 800, height: 600), limits: limits) == nil)
        #expect(ZoomGeometry.fitting(CGRect(x: 0, y: 0, width: 10, height: 10), in: CGSize(width: 20, height: 20), margin: 16, limits: limits) == nil)
        #expect(ZoomGeometry.fitting(CGRect(x: Double.nan, y: 0, width: 10, height: 10), in: CGSize(width: 800, height: 600), limits: limits) == nil)
    }

    @Test func aDraggedRectInAnyDirectionFitsTheSame() {
        let target = ZoomGeometry.fitting(CGRect(x: 300, y: 150, width: -200, height: -100), in: CGSize(width: 432, height: 232), margin: 16, limits: limits)
        #expect(target?.magnification == 2)
    }

    @Test func aClickDoublesTheZoomAtThePoint() {
        let target = ZoomGeometry.zooming(at: CGPoint(x: 40, y: 60), from: 1.5, limits: limits)
        #expect(target == ZoomTarget(magnification: 3, center: CGPoint(x: 40, y: 60)))
        #expect(ZoomGeometry.zooming(at: .zero, from: 6, limits: limits)?.magnification == 8)
    }

    @Test func clickOrDrag() {
        #expect(ZoomGeometry.isClick(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 13)))
        #expect(!ZoomGeometry.isClick(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 30)))
    }
}

@MainActor
struct EditorPixelSelectionTests {
    @Test func selectingPixelsFitsThemToThePictureAndDeselectsObjects() {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object]) // the picture is 100×80
        h.editor.selection = [object.id]
        h.editor.selectPixels(CGRect(x: 90, y: 70, width: 40, height: 40))
        #expect(h.editor.pixelSelection == CGRect(x: 90, y: 70, width: 10, height: 10))
        #expect(h.editor.selection.isEmpty)
        #expect(h.editor.pixelSelectionSizeText == "10 × 10")
    }

    @Test func selectingAnObjectClearsThePixelSelection() {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object])
        h.editor.selectPixels(CGRect(x: 5, y: 5, width: 10, height: 10))
        h.editor.selection = [object.id]
        #expect(h.editor.pixelSelection == nil)
    }

    @Test func nilOrAnAreaOutsideThePictureClearsIt() {
        let h = EditorHarness()
        h.editor.selectPixels(CGRect(x: 5, y: 5, width: 10, height: 10))
        h.editor.selectPixels(CGRect(x: 500, y: 5, width: 10, height: 10))
        #expect(h.editor.pixelSelection == nil)
        h.editor.selectPixels(CGRect(x: 5, y: 5, width: 10, height: 10))
        h.editor.selectPixels(nil)
        #expect(h.editor.pixelSelection == nil)
    }

    @Test func theKeyEditsNudgeResizeAndGrow() {
        let h = EditorHarness()
        h.editor.selectPixels(CGRect(x: 10, y: 10, width: 20, height: 20))
        #expect(h.editor.nudgePixelSelection(by: CGVector(dx: 10, dy: 1)))
        #expect(h.editor.pixelSelection == CGRect(x: 20, y: 11, width: 20, height: 20))
        #expect(h.editor.resizePixelSelection(by: CGVector(dx: 1, dy: -1)))
        #expect(h.editor.pixelSelection == CGRect(x: 20, y: 11, width: 21, height: 19))
        #expect(h.editor.growPixelSelection(by: 1))
        #expect(h.editor.pixelSelection == CGRect(x: 19, y: 10, width: 23, height: 21))
    }

    @Test func withNoSelectionTheEditsDoNothing() {
        let h = EditorHarness()
        #expect(!h.editor.nudgePixelSelection(by: CGVector(dx: 1, dy: 0)))
        #expect(!h.editor.resizePixelSelection(by: CGVector(dx: 1, dy: 0)))
        #expect(!h.editor.growPixelSelection(by: 1))
        #expect(h.editor.pixelSelection == nil)
    }

    @Test func aTurnClearsTheSelectionAndSoDoesCropMode() {
        let h = EditorHarness()
        h.editor.selectPixels(CGRect(x: 5, y: 5, width: 10, height: 10))
        h.act { h.editor.rotateRight() }
        #expect(h.editor.pixelSelection == nil)
        h.editor.selectPixels(CGRect(x: 5, y: 5, width: 10, height: 10))
        h.editor.tool = .crop
        #expect(h.editor.pixelSelection == nil)
    }

    @Test func arrowKeysFollowTheScreenAfterAFlip() {
        let h = EditorHarness()
        h.act { h.editor.flipHorizontally() }
        h.editor.selectPixels(CGRect(x: 10, y: 10, width: 20, height: 20))
        h.editor.nudgePixelSelection(by: CGVector(dx: 1, dy: 0)) // right on screen is left in the picture
        #expect(h.editor.pixelSelection == CGRect(x: 9, y: 10, width: 20, height: 20))
    }
}
