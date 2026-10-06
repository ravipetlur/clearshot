import CoreGraphics
import CSCore
import Testing
@testable import CSCapture

struct AdjustableSelectionTests {
    // Two displays in AppKit global points: the main display, and a portrait display left of and below it.
    static let main = DisplayInfo(id: 3, name: "Main Display", frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
                                  scale: 2, isBuiltIn: false, safeAreaTop: 0)
    static let portrait = DisplayInfo(id: 2, name: "Portrait Display",
                                      frame: CGRect(x: -1800, y: -819, width: 1800, height: 3200),
                                      scale: 2, isBuiltIn: false, safeAreaTop: 0)

    func drag(_ selection: inout AdjustableSelection, from start: CGPoint, to end: CGPoint,
              modifiers: SelectionModifiers = []) {
        selection.mouseDown(at: start, modifiers: modifiers)
        selection.mouseDragged(to: end, modifiers: modifiers)
        selection.mouseUp(at: end, modifiers: modifiers)
    }

    @Test func nothingIsSelectedAtFirst() {
        let selection = AdjustableSelection(displays: [Self.main, Self.portrait])
        #expect(selection.phase == .idle)
        #expect(selection.rect == nil)
        #expect(selection.displayID == nil)
        #expect(selection.display == nil)
        #expect(!selection.isAdjustable)
        #expect(selection.startModifiers == [])
    }

    @Test func aDragOnThePortraitDisplaySelectsThere() {
        var selection = AdjustableSelection(displays: [Self.main, Self.portrait])
        drag(&selection, from: CGPoint(x: -1500, y: 0), to: CGPoint(x: -1200, y: 300), modifiers: .shift)
        #expect(selection.displayID == 2)
        #expect(selection.display == Self.portrait)
        #expect(selection.rect == CGRect(x: -1500, y: 0, width: 300, height: 300))
        #expect(selection.phase == .adjusting)
        #expect(selection.isAdjustable)
        #expect(selection.startModifiers == .shift)

        // A drag that runs onto the main display stays on the portrait display, where it began.
        var across = AdjustableSelection(displays: [Self.main, Self.portrait])
        drag(&across, from: CGPoint(x: -100, y: 0), to: CGPoint(x: 200, y: 300))
        #expect(across.displayID == 2)
        #expect(across.rect == CGRect(x: -100, y: 0, width: 100, height: 300))
    }

    @Test func aStrayClickOnAnotherDisplayKeepsTheSelection() {
        var selection = AdjustableSelection(displays: [Self.main, Self.portrait])
        drag(&selection, from: CGPoint(x: -1500, y: 0), to: CGPoint(x: -1200, y: 300), modifiers: .shift)

        selection.mouseDown(at: CGPoint(x: 500, y: 500), modifiers: .option)
        #expect(selection.displayID == 3)
        #expect(selection.phase == .dragging)
        selection.mouseUp(at: CGPoint(x: 501, y: 501), modifiers: .option)
        #expect(selection.displayID == 2)
        #expect(selection.rect == CGRect(x: -1500, y: 0, width: 300, height: 300))
        #expect(selection.phase == .adjusting)
        #expect(selection.startModifiers == .shift)
    }

    @Test func aRealDragOnAnotherDisplayReplacesTheSelection() {
        var selection = AdjustableSelection(displays: [Self.main, Self.portrait])
        drag(&selection, from: CGPoint(x: -1500, y: 0), to: CGPoint(x: -1200, y: 300))
        drag(&selection, from: CGPoint(x: 500, y: 500), to: CGPoint(x: 800, y: 700), modifiers: .option)
        #expect(selection.displayID == 3)
        #expect(selection.rect == CGRect(x: 200, y: 300, width: 600, height: 400))
        #expect(selection.startModifiers == .option)

        // The portrait display's selection is gone for good: a stray click back there keeps the main display's.
        selection.mouseDown(at: CGPoint(x: -1000, y: 100), modifiers: [])
        selection.mouseUp(at: CGPoint(x: -1000, y: 100), modifiers: [])
        #expect(selection.displayID == 3)
        #expect(selection.rect == CGRect(x: 200, y: 300, width: 600, height: 400))
    }

    @Test func aStrayClickWithNoSelectionLeavesNothing() {
        var selection = AdjustableSelection(displays: [Self.main, Self.portrait])
        selection.mouseDown(at: CGPoint(x: 500, y: 500), modifiers: .shift)
        selection.mouseUp(at: CGPoint(x: 501, y: 500), modifiers: .shift)
        #expect(selection.phase == .idle)
        #expect(selection.rect == nil)
        #expect(selection.displayID == nil)
        #expect(selection.startModifiers == [])
    }

    @Test func aHandleOnTheSharedEdgeIsReachableFromTheNextDisplay() {
        // The portrait display's right edge is the main display's left edge: a press just across it still grabs the
        // handle.
        var selection = AdjustableSelection(displays: [Self.main, Self.portrait])
        selection.setRect(CGRect(x: -300, y: 0, width: 300, height: 300), onDisplay: 2)
        #expect(selection.handle(at: CGPoint(x: 3, y: 150)) == .right)
        selection.mouseDown(at: CGPoint(x: 3, y: 150), modifiers: [])
        #expect(selection.phase == .resizing(.right))
        #expect(selection.displayID == 2)
        selection.mouseUp(at: CGPoint(x: -97, y: 150), modifiers: [])
        #expect(selection.rect == CGRect(x: -300, y: 0, width: 200, height: 300))
        #expect(selection.displayID == 2)
    }

    @Test func setRectOnAMissingDisplayIsRejected() {
        var selection = AdjustableSelection(displays: [Self.main, Self.portrait])
        let missing = selection.setRect(CGRect(x: 10, y: 10, width: 100, height: 100), onDisplay: 99)
        #expect(!missing)
        #expect(selection.phase == .idle)
        #expect(selection.rect == nil)
        #expect(selection.displayID == nil)

        let onPortrait = selection.setRect(CGRect(x: -1700, y: 200, width: 640, height: 480), onDisplay: 2)
        #expect(onPortrait)
        #expect(selection.displayID == 2)
        #expect(selection.phase == .adjusting)
        #expect(selection.rect == CGRect(x: -1700, y: 200, width: 640, height: 480))
        // A rejected one keeps what is there.
        let stillMissing = selection.setRect(CGRect(x: 10, y: 10, width: 100, height: 100), onDisplay: 99)
        #expect(!stillMissing)
        let offScreen = selection.setRect(CGRect(x: 5000, y: 5000, width: 100, height: 100), onDisplay: 3)
        #expect(!offScreen)
        #expect(selection.displayID == 2)
        #expect(selection.rect == CGRect(x: -1700, y: 200, width: 640, height: 480))
    }

    @Test func setRectMovesTheSelectionToItsDisplayAndClearsTheStartModifiers() {
        var selection = AdjustableSelection(displays: [Self.main, Self.portrait])
        drag(&selection, from: CGPoint(x: -1500, y: 0), to: CGPoint(x: -1200, y: 300), modifiers: .shift)
        let onMain = selection.setRect(CGRect(x: 100, y: 100, width: 400, height: 300), onDisplay: 3)
        #expect(onMain)
        #expect(selection.displayID == 3)
        #expect(selection.rect == CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(selection.startModifiers == [])
        // Not while the mouse is down.
        selection.mouseDown(at: CGPoint(x: 1000, y: 1000), modifiers: [])
        let whileDown = selection.setRect(CGRect(x: -1700, y: 200, width: 640, height: 480), onDisplay: 2)
        #expect(!whileDown)
        #expect(selection.displayID == 3)
    }

    @Test func aSelectionHandedOverKeepsItsDragsStartModifiersUntilAFreshDrag() {
        // All-In-One's S hands its selection to the scrolling capture's Ready with the keys held as it was dragged.
        var selection = AdjustableSelection(displays: [Self.main, Self.portrait])
        let handedOver = selection.setRect(CGRect(x: 100, y: 100, width: 400, height: 300), onDisplay: 3,
                                           startModifiers: .shift)
        #expect(handedOver)
        #expect(selection.startModifiers == .shift)

        // Still that selection: resized by a handle, moved, nudged, and kept by stray clicks here and on the portrait
        // display.
        selection.mouseDown(at: CGPoint(x: 500, y: 250), modifiers: [])
        #expect(selection.phase == .resizing(.right))
        selection.mouseUp(at: CGPoint(x: 600, y: 250), modifiers: [])
        selection.mouseDown(at: CGPoint(x: 300, y: 250), modifiers: [])
        #expect(selection.phase == .moving)
        selection.mouseDragged(to: CGPoint(x: 320, y: 260), modifiers: [])
        selection.mouseUp(at: CGPoint(x: 320, y: 260), modifiers: [])
        selection.arrow(.left, modifiers: [])
        selection.mouseDown(at: CGPoint(x: 2000, y: 1500), modifiers: [])
        selection.mouseUp(at: CGPoint(x: 2001, y: 1500), modifiers: [])
        selection.mouseDown(at: CGPoint(x: -1000, y: 100), modifiers: [])
        selection.mouseUp(at: CGPoint(x: -1000, y: 100), modifiers: [])
        #expect(selection.displayID == 3)
        #expect(selection.rect == CGRect(x: 119, y: 110, width: 500, height: 300))
        #expect(selection.startModifiers == .shift)

        // A fresh drag is a selection of its own, with only its own keys, and a stray click now keeps that one.
        drag(&selection, from: CGPoint(x: 1000, y: 1000), to: CGPoint(x: 1400, y: 1300))
        #expect(selection.rect == CGRect(x: 1000, y: 1000, width: 400, height: 300))
        #expect(selection.startModifiers == [])
        selection.mouseDown(at: CGPoint(x: 2000, y: 1500), modifiers: .shift)
        selection.mouseUp(at: CGPoint(x: 2000, y: 1500), modifiers: .shift)
        #expect(selection.startModifiers == [])
    }

    @Test func handlesResizeAndArrowsSizesAndRatiosReachTheSelection() throws {
        var selection = AdjustableSelection(displays: [Self.main, Self.portrait])
        #expect(selection.handle(at: CGPoint(x: 100, y: 400)) == nil)
        selection.setRect(CGRect(x: 100, y: 100, width: 400, height: 300), onDisplay: 3)
        #expect(selection.handle(at: CGPoint(x: 100, y: 400)) == .topLeft)
        selection.mouseDown(at: CGPoint(x: 500, y: 250), modifiers: [])
        #expect(selection.phase == .resizing(.right))
        #expect(selection.isAdjustable)
        selection.mouseUp(at: CGPoint(x: 600, y: 250), modifiers: [])
        #expect(selection.rect == CGRect(x: 100, y: 100, width: 500, height: 300))

        selection.arrow(.right, modifiers: .command)
        #expect(selection.rect == CGRect(x: 110, y: 100, width: 500, height: 300))
        let typed = selection.setSize(width: 800, height: nil)
        #expect(typed)
        #expect(selection.rect == CGRect(x: 110, y: 100, width: 800, height: 300))
        // 16:9 at 800 wide needs 450 pt below the top edge at 400: both scale down to the 400 there is.
        selection.aspectRatio = 16.0 / 9.0
        selection.fitToAspectRatio()
        let fitted = try #require(selection.rect)
        #expect(fitted.origin == CGPoint(x: 110, y: 0))
        #expect(fitted.height == 400)
        #expect(abs(fitted.width - 400 * 16 / 9) < 0.001)

        // The ratio shapes the next drag too, on another display as well.
        drag(&selection, from: CGPoint(x: -1500, y: 0), to: CGPoint(x: -1180, y: 50))
        #expect(selection.displayID == 2)
        #expect(selection.rect == CGRect(x: -1500, y: 0, width: 320, height: 180))
    }
}
