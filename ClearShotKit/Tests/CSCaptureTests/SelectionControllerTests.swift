import CoreGraphics
import Testing
@testable import CSCapture

struct SelectionControllerTests {
    // The portrait display, in AppKit global points (negative origin).
    let portrait = CGRect(x: -1800, y: -819, width: 1800, height: 3200)
    let main = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func drag(_ controller: inout SelectionController, from start: CGPoint, to end: CGPoint, modifiers: SelectionModifiers = []) {
        controller.mouseDown(at: start)
        controller.mouseDragged(to: end, modifiers: modifiers)
        controller.mouseUp(at: end, modifiers: modifiers)
    }

    @Test func dragCreatesANormalizedRectAndConfirms() {
        var controller = SelectionController(bounds: main)
        drag(&controller, from: CGPoint(x: 300, y: 400), to: CGPoint(x: 100, y: 200))
        #expect(controller.rect == CGRect(x: 100, y: 200, width: 200, height: 200))
        #expect(controller.phase == .done)
    }

    @Test func selectionIsClampedToItsDisplay() {
        var controller = SelectionController(bounds: portrait)
        drag(&controller, from: CGPoint(x: -100, y: 0), to: CGPoint(x: 400, y: 300))
        #expect(controller.rect == CGRect(x: -100, y: 0, width: 100, height: 300))
    }

    @Test func shiftMakesASquare() {
        var controller = SelectionController(bounds: main)
        drag(&controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 150), modifiers: .shift)
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    @Test func optionGrowsFromTheCenter() {
        var controller = SelectionController(bounds: main)
        drag(&controller, from: CGPoint(x: 500, y: 400), to: CGPoint(x: 550, y: 430), modifiers: .option)
        #expect(controller.rect == CGRect(x: 450, y: 370, width: 100, height: 60))
    }

    @Test func spaceMovesTheSelectionThenResizingContinues() {
        var controller = SelectionController(bounds: main)
        controller.mouseDown(at: CGPoint(x: 100, y: 100))
        controller.mouseDragged(to: CGPoint(x: 200, y: 200), modifiers: [])
        controller.spaceDown(at: CGPoint(x: 200, y: 200))
        controller.mouseDragged(to: CGPoint(x: 250, y: 220), modifiers: [])
        #expect(controller.phase == .moving)
        #expect(controller.rect == CGRect(x: 150, y: 120, width: 100, height: 100))
        controller.spaceUp(at: CGPoint(x: 250, y: 220))
        controller.mouseDragged(to: CGPoint(x: 300, y: 260), modifiers: [])
        #expect(controller.rect == CGRect(x: 150, y: 120, width: 150, height: 140))
    }

    @Test func aTinyDragIsNotASelection() {
        var controller = SelectionController(bounds: main)
        drag(&controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 102, y: 101))
        #expect(controller.phase == .idle)
    }

    @Test func adjustingModeAllowsArrowsAndConfirm() {
        var controller = SelectionController(bounds: main, confirmsOnMouseUp: false)
        drag(&controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
        #expect(controller.phase == .adjusting)
        controller.arrow(.right, modifiers: [])
        controller.arrow(.up, modifiers: .command)
        #expect(controller.rect == CGRect(x: 101, y: 110, width: 100, height: 100))
        controller.arrow(.right, modifiers: .shift)
        #expect(controller.rect.width == 101)
        controller.confirm()
        #expect(controller.phase == .done)
    }

    @Test func draggingInsideAnAdjustingRectMovesIt() {
        var controller = SelectionController(bounds: main, confirmsOnMouseUp: false)
        drag(&controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
        controller.mouseDown(at: CGPoint(x: 150, y: 150))
        controller.mouseDragged(to: CGPoint(x: 170, y: 140), modifiers: [])
        controller.mouseUp(at: CGPoint(x: 170, y: 140), modifiers: [])
        #expect(controller.rect == CGRect(x: 120, y: 90, width: 100, height: 100))
        #expect(controller.phase == .adjusting)
    }

    @Test func snapsThePointerToNearbyEdges() {
        var controller = SelectionController(bounds: main, snapLines: SnapLines(xs: [400], ys: [300]))
        drag(&controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 395, y: 307))
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 300, height: 200))
        var far = SelectionController(bounds: main, snapLines: SnapLines(xs: [400], ys: [300]))
        drag(&far, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 380, y: 280))
        #expect(far.rect == CGRect(x: 100, y: 100, width: 280, height: 180))
    }

    @Test func escapeCancels() {
        var controller = SelectionController(bounds: main)
        controller.mouseDown(at: CGPoint(x: 1, y: 1))
        controller.cancel()
        #expect(controller.phase == .cancelled)
    }

    @Test func setRectEntersAdjusting() {
        var controller = SelectionController(bounds: main, confirmsOnMouseUp: false)
        controller.setRect(CGRect(x: 900, y: 700, width: 400, height: 400))
        #expect(controller.phase == .adjusting)
        #expect(controller.rect == CGRect(x: 900, y: 700, width: 100, height: 100))
    }

    // MARK: setRect validation

    @Test func setRectReportsThatItWasApplied() {
        var controller = SelectionController(bounds: main, confirmsOnMouseUp: false)
        let first = controller.setRect(CGRect(x: 900, y: 700, width: 400, height: 400))
        #expect(first)
        // Adjusting can be re-seeded with another valid rect.
        let second = controller.setRect(CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(second)
        #expect(controller.phase == .adjusting)
        #expect(controller.rect == CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    @Test func setRectOutsideTheBoundsIsRejected() {
        var controller = SelectionController(bounds: main)
        let outside = controller.setRect(CGRect(x: 2000, y: 2000, width: 100, height: 100))
        #expect(!outside)
        #expect(controller.phase == .idle)
        #expect(controller.rect == .zero)
        // Touching an edge leaves a zero-width intersection, which is no selection either.
        let touching = controller.setRect(CGRect(x: 1000, y: 100, width: 50, height: 50))
        #expect(!touching)
        #expect(controller.phase == .idle)
        #expect(controller.rect == .zero)
    }

    @Test func setRectBelowTheMinimumSizeIsRejected() {
        var controller = SelectionController(bounds: main)
        let tiny = controller.setRect(CGRect(x: 10, y: 10, width: 2, height: 2))
        #expect(!tiny)
        #expect(controller.phase == .idle)
        #expect(controller.rect == .zero)
        // Clipping to the display counts: only 2 pt of this rect are on screen.
        let clipped = controller.setRect(CGRect(x: 998, y: 100, width: 100, height: 100))
        #expect(!clipped)
        #expect(controller.phase == .idle)
        #expect(controller.rect == .zero)
        // Exactly the minimum is allowed.
        let minimum = controller.setRect(CGRect(x: 10, y: 10, width: 4, height: 4))
        #expect(minimum)
        #expect(controller.phase == .adjusting)
    }

    @Test func aRejectedSetRectKeepsTheCurrentAdjustingSelection() {
        var controller = SelectionController(bounds: main, confirmsOnMouseUp: false)
        controller.setRect(CGRect(x: 100, y: 100, width: 200, height: 200))
        let rejected = controller.setRect(CGRect(x: 5000, y: 5000, width: 100, height: 100))
        #expect(!rejected)
        #expect(controller.phase == .adjusting)
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    @Test func setRectCannotReviveACancelledOrConfirmedSelection() {
        var cancelled = SelectionController(bounds: main)
        cancelled.cancel()
        let revived = cancelled.setRect(CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(!revived)
        #expect(cancelled.phase == .cancelled)

        var confirmed = SelectionController(bounds: main)
        drag(&confirmed, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
        #expect(confirmed.phase == .done)
        let reopened = confirmed.setRect(CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(!reopened)
        #expect(confirmed.phase == .done)
        #expect(confirmed.rect == CGRect(x: 100, y: 100, width: 100, height: 100))
    }

    @Test func setRectIsIgnoredWhileTheMouseIsDown() {
        var dragging = SelectionController(bounds: main)
        dragging.mouseDown(at: CGPoint(x: 100, y: 100))
        dragging.mouseDragged(to: CGPoint(x: 200, y: 200), modifiers: [])
        let whileDragging = dragging.setRect(CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(!whileDragging)
        #expect(dragging.phase == .dragging)
        #expect(dragging.rect == CGRect(x: 100, y: 100, width: 100, height: 100))

        dragging.spaceDown(at: CGPoint(x: 200, y: 200))
        let whileMoving = dragging.setRect(CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(!whileMoving)
        #expect(dragging.phase == .moving)
    }

    // MARK: ⇧ and ⌥ at the display edge

    @Test func shiftStaysSquareAtTheDisplayEdge() {
        var controller = SelectionController(bounds: main)
        drag(&controller, from: CGPoint(x: 900, y: 100), to: CGPoint(x: 1000, y: 300), modifiers: .shift)
        #expect(controller.rect == CGRect(x: 900, y: 100, width: 100, height: 100))
    }

    @Test func shiftStaysSquareWhenDraggingTowardTheLowerEdgesAndPastTheDisplay() {
        var controller = SelectionController(bounds: main)
        drag(&controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: -50, y: 300), modifiers: .shift)
        #expect(controller.rect == CGRect(x: 0, y: 100, width: 100, height: 100))
        var beyond = SelectionController(bounds: main)
        drag(&beyond, from: CGPoint(x: 900, y: 700), to: CGPoint(x: 3000, y: 900), modifiers: .shift)
        #expect(beyond.rect == CGRect(x: 900, y: 700, width: 100, height: 100))
    }

    @Test func optionStaysCenteredAtTheDisplayEdge() {
        var controller = SelectionController(bounds: main)
        drag(&controller, from: CGPoint(x: 50, y: 400), to: CGPoint(x: 150, y: 450), modifiers: .option)
        #expect(controller.rect == CGRect(x: 0, y: 350, width: 100, height: 100))
    }

    @Test func shiftAndOptionGiveASquareAroundTheAnchorAtTheDisplayEdge() {
        var controller = SelectionController(bounds: main)
        drag(&controller, from: CGPoint(x: 50, y: 400), to: CGPoint(x: 200, y: 420), modifiers: [.shift, .option])
        #expect(controller.rect == CGRect(x: 0, y: 350, width: 100, height: 100))
        // Away from every edge the square is simply the larger side, centered on the anchor.
        var open = SelectionController(bounds: main)
        drag(&open, from: CGPoint(x: 500, y: 400), to: CGPoint(x: 540, y: 460), modifiers: [.shift, .option])
        #expect(open.rect == CGRect(x: 440, y: 340, width: 120, height: 120))
    }

    // MARK: The modifiers the drag began with (the ⇧ that skips the background preset)

    @Test func shiftHeldAsTheDragStartsIsKeptAfterItIsReleased() {
        var controller = SelectionController(bounds: main)
        #expect(controller.startModifiers == [])
        controller.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: .shift)
        controller.mouseDragged(to: CGPoint(x: 300, y: 150), modifiers: .shift)
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 200, height: 200))
        // Released mid-drag: the rect is free again, and the drag still began with ⇧.
        controller.mouseUp(at: CGPoint(x: 300, y: 150), modifiers: [])
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 200, height: 50))
        #expect(controller.phase == .done)
        #expect(controller.startModifiers == .shift)
    }

    @Test func shiftPressedOnlyAfterTheDragStartsSquaresWithoutBeingAStartModifier() {
        var controller = SelectionController(bounds: main)
        controller.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: [])
        controller.mouseDragged(to: CGPoint(x: 300, y: 150), modifiers: .shift)
        controller.mouseUp(at: CGPoint(x: 300, y: 150), modifiers: [.shift, .control])
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(controller.startModifiers == [])
    }

    @Test func movingAnAdjustingSelectionKeepsItsStartModifiersAndANewDragReplacesThem() {
        var controller = SelectionController(bounds: main, confirmsOnMouseUp: false)
        controller.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: .shift)
        controller.mouseUp(at: CGPoint(x: 200, y: 200), modifiers: [])
        #expect(controller.phase == .adjusting)
        // A mouse-down inside the rect moves it: the selection is the same one.
        controller.mouseDown(at: CGPoint(x: 150, y: 150), modifiers: [])
        controller.mouseUp(at: CGPoint(x: 160, y: 150), modifiers: [])
        #expect(controller.phase == .adjusting)
        #expect(controller.startModifiers == .shift)
        // One outside it starts a new drag, with the keys held now.
        controller.mouseDown(at: CGPoint(x: 500, y: 500), modifiers: .option)
        #expect(controller.phase == .dragging)
        #expect(controller.startModifiers == .option)
    }

    // MARK: The capture style stays as it was

    @Test func confirmOnMouseUpNeverAdjustsResizesOrRevertsAStrayClick() {
        var controller = SelectionController(bounds: main)
        drag(&controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180))
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 100, height: 80))
        #expect(controller.phase == .done)
        #expect(controller.handle(at: CGPoint(x: 100, y: 180)) == nil)
        controller.mouseDown(at: CGPoint(x: 100, y: 180), modifiers: [])
        #expect(controller.phase == .done)

        // A tiny drag from idle selects nothing and forgets the keys it began with.
        var tiny = SelectionController(bounds: main)
        tiny.mouseDown(at: CGPoint(x: 300, y: 300), modifiers: .shift)
        tiny.mouseUp(at: CGPoint(x: 302, y: 301), modifiers: .shift)
        #expect(tiny.phase == .idle)
        #expect(tiny.rect == .zero)
        #expect(tiny.startModifiers == [])

        // Even seeded with a rect, a confirming controller has no handles and a stray click selects nothing, as before.
        var seeded = SelectionController(bounds: main)
        seeded.setRect(CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(seeded.handle(at: CGPoint(x: 100, y: 200)) == nil)
        seeded.mouseDown(at: CGPoint(x: 100, y: 200), modifiers: [])
        #expect(seeded.phase == .dragging)
        seeded.mouseUp(at: CGPoint(x: 101, y: 201), modifiers: [])
        #expect(seeded.phase == .idle)
        #expect(seeded.rect == .zero)
    }

    // MARK: Handles (adjusting only)

    /// An adjusting controller on `main` holding `rect`.
    func adjusting(_ rect: CGRect, aspectRatio: CGFloat? = nil) -> SelectionController {
        var controller = SelectionController(bounds: main, confirmsOnMouseUp: false)
        controller.aspectRatio = aspectRatio
        controller.setRect(rect)
        return controller
    }

    @Test func handlesSitOnTheCornersAndEdges() {
        let controller = adjusting(CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(controller.handle(at: CGPoint(x: 100, y: 200)) == .topLeft)
        #expect(controller.handle(at: CGPoint(x: 200, y: 200)) == .top)
        #expect(controller.handle(at: CGPoint(x: 305, y: 205)) == .topRight)
        #expect(controller.handle(at: CGPoint(x: 300, y: 150)) == .right)
        #expect(controller.handle(at: CGPoint(x: 300, y: 100)) == .bottomRight)
        #expect(controller.handle(at: CGPoint(x: 120, y: 102)) == .bottom)
        #expect(controller.handle(at: CGPoint(x: 94, y: 94)) == .bottomLeft)
        #expect(controller.handle(at: CGPoint(x: 104, y: 150)) == .left)
        // The middle, and anything more than 6 pt from the outline, is no handle.
        #expect(controller.handle(at: CGPoint(x: 200, y: 150)) == nil)
        #expect(controller.handle(at: CGPoint(x: 200, y: 207)) == nil)
        #expect(controller.handle(at: CGPoint(x: 93, y: 150)) == nil)
        #expect(SelectionController.handleTolerance == 6)
    }

    @Test func aCornerHandleResizesKeepingTheOppositeCorner() {
        var controller = adjusting(CGRect(x: 100, y: 100, width: 200, height: 100))
        controller.mouseDown(at: CGPoint(x: 300, y: 200), modifiers: [])
        #expect(controller.phase == .resizing(.topRight))
        controller.mouseDragged(to: CGPoint(x: 400, y: 300), modifiers: [])
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 300, height: 200))
        controller.mouseUp(at: CGPoint(x: 400, y: 300), modifiers: [])
        #expect(controller.phase == .adjusting)
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 300, height: 200))

        controller.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: [])
        #expect(controller.phase == .resizing(.bottomLeft))
        controller.mouseUp(at: CGPoint(x: 50, y: 50), modifiers: [])
        #expect(controller.rect == CGRect(x: 50, y: 50, width: 350, height: 250))
        #expect(controller.phase == .adjusting)
    }

    @Test func anEdgeHandleMovesOnlyThatEdge() {
        var controller = adjusting(CGRect(x: 100, y: 100, width: 200, height: 100))
        controller.mouseDown(at: CGPoint(x: 200, y: 200), modifiers: [])
        #expect(controller.phase == .resizing(.top))
        controller.mouseDragged(to: CGPoint(x: 250, y: 260), modifiers: [])
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 200, height: 160))
        controller.mouseUp(at: CGPoint(x: 250, y: 260), modifiers: [])

        // Anywhere along an edge, not only its midpoint. The edge keeps the distance to the pointer it was grabbed at.
        controller.mouseDown(at: CGPoint(x: 103, y: 230), modifiers: [])
        #expect(controller.phase == .resizing(.left))
        controller.mouseUp(at: CGPoint(x: 160, y: 10), modifiers: [])
        #expect(controller.rect == CGRect(x: 157, y: 100, width: 143, height: 160))
    }

    @Test func handlesWinOverMoving() {
        var controller = adjusting(CGRect(x: 100, y: 100, width: 200, height: 100))
        // 3 pt inside the top-left corner is inside the rect too, but the handle wins.
        controller.mouseDown(at: CGPoint(x: 103, y: 197), modifiers: [])
        #expect(controller.phase == .resizing(.topLeft))
        // A click on a handle without moving changes nothing.
        controller.mouseUp(at: CGPoint(x: 103, y: 197), modifiers: [])
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(controller.phase == .adjusting)
        // Well inside, a mouse-down still moves.
        controller.mouseDown(at: CGPoint(x: 200, y: 150), modifiers: [])
        #expect(controller.phase == .moving)
    }

    @Test func resizingStopsAtTheMinimumSizeAndTheDisplayEdge() {
        var controller = adjusting(CGRect(x: 100, y: 100, width: 200, height: 100))
        controller.mouseDown(at: CGPoint(x: 300, y: 150), modifiers: [])
        // Past the opposite edge it stops at 4 pt instead of flipping.
        controller.mouseDragged(to: CGPoint(x: 50, y: 150), modifiers: [])
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 4, height: 100))
        controller.mouseDragged(to: CGPoint(x: 5000, y: 150), modifiers: [])
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 900, height: 100))
        controller.mouseUp(at: CGPoint(x: 5000, y: 150), modifiers: [])

        controller.mouseDown(at: CGPoint(x: 100, y: 200), modifiers: [])
        #expect(controller.phase == .resizing(.topLeft))
        controller.mouseUp(at: CGPoint(x: -50, y: 900), modifiers: [])
        #expect(controller.rect == CGRect(x: 0, y: 100, width: 1000, height: 700))
    }

    @Test func optionResizesAboutTheCentre() {
        var controller = adjusting(CGRect(x: 400, y: 300, width: 200, height: 100))
        controller.mouseDown(at: CGPoint(x: 600, y: 350), modifiers: [])
        controller.mouseUp(at: CGPoint(x: 650, y: 380), modifiers: .option)
        #expect(controller.rect == CGRect(x: 350, y: 300, width: 300, height: 100))

        controller.mouseDown(at: CGPoint(x: 650, y: 400), modifiers: [])
        #expect(controller.phase == .resizing(.topRight))
        controller.mouseDragged(to: CGPoint(x: 700, y: 450), modifiers: .option)
        #expect(controller.rect == CGRect(x: 300, y: 250, width: 400, height: 200))
        // About the centre (500, 350) it can only grow as far as the nearer display edge allows on each axis.
        controller.mouseUp(at: CGPoint(x: 5000, y: 5000), modifiers: .option)
        #expect(controller.rect == CGRect(x: 0, y: 0, width: 1000, height: 700))
    }

    @Test func shiftLocksTheAspectAtTheResizeStart() {
        var controller = adjusting(CGRect(x: 100, y: 100, width: 200, height: 100))
        controller.mouseDown(at: CGPoint(x: 300, y: 100), modifiers: [])
        #expect(controller.phase == .resizing(.bottomRight))
        // 2:1 from the fixed top-left corner (100, 200); the pointer's larger pull wins.
        controller.mouseDragged(to: CGPoint(x: 500, y: 150), modifiers: .shift)
        #expect(controller.rect == CGRect(x: 100, y: 0, width: 400, height: 200))
        controller.mouseDragged(to: CGPoint(x: 500, y: 150), modifiers: [])
        #expect(controller.rect == CGRect(x: 100, y: 150, width: 400, height: 50))
        // ⇧ again locks to the aspect the resize started with, not the one it has now.
        controller.mouseUp(at: CGPoint(x: 500, y: 150), modifiers: .shift)
        #expect(controller.rect == CGRect(x: 100, y: 0, width: 400, height: 200))

        // An edge keeps the opposite edge and the centre of the other axis.
        var edge = adjusting(CGRect(x: 100, y: 100, width: 200, height: 100))
        edge.mouseDown(at: CGPoint(x: 300, y: 150), modifiers: [])
        edge.mouseUp(at: CGPoint(x: 400, y: 150), modifiers: .shift)
        #expect(edge.rect == CGRect(x: 100, y: 75, width: 300, height: 150))
    }

    @Test func aRatioLocksResizingAndShrinksToStayInside() {
        // 2:1 set as the ratio: ⇧ isn't needed.
        var controller = adjusting(CGRect(x: 100, y: 100, width: 200, height: 100), aspectRatio: 2)
        controller.mouseDown(at: CGPoint(x: 300, y: 100), modifiers: [])
        controller.mouseDragged(to: CGPoint(x: 500, y: 150), modifiers: [])
        #expect(controller.rect == CGRect(x: 100, y: 0, width: 400, height: 200))
        // Only 200 pt below the fixed corner: it can't get any taller, so it can't get any wider either.
        controller.mouseUp(at: CGPoint(x: 900, y: 150), modifiers: [])
        #expect(controller.rect == CGRect(x: 100, y: 0, width: 400, height: 200))
    }

    // MARK: Ratios in new drags

    @Test func aRatioShapesNewDragsAndKeepsItAtTheEdge() {
        var controller = SelectionController(bounds: main, confirmsOnMouseUp: false)
        controller.aspectRatio = 16.0 / 9.0
        drag(&controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 420, y: 200))
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 320, height: 180))

        // Toward the display edge the shape survives: only 100 pt of room to the right.
        var edge = SelectionController(bounds: main, confirmsOnMouseUp: false)
        edge.aspectRatio = 16.0 / 9.0
        drag(&edge, from: CGPoint(x: 900, y: 100), to: CGPoint(x: 1200, y: 300))
        #expect(edge.rect.maxX == 1000)
        #expect(abs(edge.rect.height - edge.rect.width * 9 / 16) < 0.5)

        // ⇧ adds nothing while a ratio is set.
        var shifted = SelectionController(bounds: main, confirmsOnMouseUp: false)
        shifted.aspectRatio = 16.0 / 9.0
        drag(&shifted, from: CGPoint(x: 900, y: 100), to: CGPoint(x: 1200, y: 300), modifiers: .shift)
        #expect(shifted.rect == edge.rect)
    }

    // MARK: Stray clicks and start modifiers

    @Test func aStrayClickInAdjustingKeepsTheRectAndItsStartModifiers() {
        var controller = SelectionController(bounds: main, confirmsOnMouseUp: false)
        controller.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: .shift)
        controller.mouseDragged(to: CGPoint(x: 300, y: 250), modifiers: [])
        controller.mouseUp(at: CGPoint(x: 300, y: 250), modifiers: [])
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 200, height: 150))
        #expect(controller.startModifiers == .shift)

        controller.mouseDown(at: CGPoint(x: 600, y: 600), modifiers: .option)
        #expect(controller.phase == .dragging)
        controller.mouseUp(at: CGPoint(x: 602, y: 601), modifiers: .option)
        #expect(controller.phase == .adjusting)
        #expect(controller.rect == CGRect(x: 100, y: 100, width: 200, height: 150))
        #expect(controller.startModifiers == .shift)

        // A real drag still replaces it, with its own keys.
        controller.mouseDown(at: CGPoint(x: 600, y: 600), modifiers: .option)
        controller.mouseUp(at: CGPoint(x: 700, y: 700), modifiers: [])
        #expect(controller.rect == CGRect(x: 600, y: 600, width: 100, height: 100))
        #expect(controller.startModifiers == .option)
    }

    @Test func setRectClearsStartModifiers() {
        var controller = SelectionController(bounds: main, confirmsOnMouseUp: false)
        controller.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: .shift)
        controller.mouseUp(at: CGPoint(x: 200, y: 200), modifiers: [])
        #expect(controller.startModifiers == .shift)
        controller.setRect(CGRect(x: 10, y: 10, width: 50, height: 50))
        #expect(controller.startModifiers == [])
    }

    // MARK: Typed sizes and ratios

    @Test func setSizeKeepsTheTopLeftAndClamps() {
        var controller = adjusting(CGRect(x: 100, y: 500, width: 300, height: 200))
        let wide = controller.setSize(width: 5000, height: nil)
        #expect(wide)
        // As wide as the display, so it slides left; the top stays at 700.
        #expect(controller.rect == CGRect(x: 0, y: 500, width: 1000, height: 200))
        let narrow = controller.setSize(width: 2, height: nil)
        #expect(narrow)
        #expect(controller.rect == CGRect(x: 0, y: 500, width: 4, height: 200))
        let negative = controller.setSize(width: -50, height: nil)
        #expect(negative)
        #expect(controller.rect == CGRect(x: 0, y: 500, width: 4, height: 200))
        // Rounded to whole points, the top-left kept.
        let rounded = controller.setSize(width: 120.6, height: 249.6)
        #expect(rounded)
        #expect(controller.rect == CGRect(x: 0, y: 450, width: 121, height: 250))
        // Too tall to hang from the top-left: clamped to the display height and slid back up from below.
        let tall = controller.setSize(width: nil, height: 5000)
        #expect(tall)
        #expect(controller.rect == CGRect(x: 0, y: 0, width: 121, height: 800))

        // Only in adjusting.
        var fresh = SelectionController(bounds: main, confirmsOnMouseUp: false)
        let notAdjusting = fresh.setSize(width: 100, height: 100)
        #expect(!notAdjusting)
        #expect(fresh.rect == .zero)
        let nothingTyped = controller.setSize(width: nil, height: nil)
        #expect(!nothingTyped)
    }

    @Test func setSizeWithARatioDrivesTheOtherSide() {
        var controller = adjusting(CGRect(x: 100, y: 100, width: 200, height: 200), aspectRatio: 4.0 / 3.0)
        let byWidth = controller.setSize(width: 400, height: nil)
        #expect(byWidth)
        #expect(controller.rect == CGRect(x: 100, y: 0, width: 400, height: 300))
        let byHeight = controller.setSize(width: nil, height: 150)
        #expect(byHeight)
        #expect(controller.rect == CGRect(x: 100, y: 150, width: 200, height: 150))
        // Both given: the width drives.
        let byBoth = controller.setSize(width: 600, height: 100)
        #expect(byBoth)
        #expect(controller.rect.size == CGSize(width: 600, height: 450))
        // 5 000 tall would need 6 667 wide: both shrink together until the width fits, then it slides inside.
        let tooTall = controller.setSize(width: nil, height: 5000)
        #expect(tooTall)
        #expect(controller.rect == CGRect(x: 0, y: 0, width: 1000, height: 750))
        // Below the minimum, both grow together until the smaller side is 4 pt.
        let tiny = controller.setSize(width: -50, height: nil)
        #expect(tiny)
        #expect(controller.rect.size == CGSize(width: 5, height: 4))
    }

    @Test func fitToAspectRatioKeepsTheWidthAndShrinksToFit() {
        var controller = adjusting(CGRect(x: 100, y: 500, width: 400, height: 100))
        controller.fitToAspectRatio()
        #expect(controller.rect == CGRect(x: 100, y: 500, width: 400, height: 100))

        controller.aspectRatio = 4.0 / 3.0
        controller.fitToAspectRatio()
        #expect(controller.rect == CGRect(x: 100, y: 300, width: 400, height: 300))
        // 1:2 would need 800 pt below a top edge at 600: both scale down to the 600 there is.
        controller.aspectRatio = 0.5
        controller.fitToAspectRatio()
        #expect(controller.rect == CGRect(x: 100, y: 0, width: 300, height: 600))
    }

    @Test func shiftArrowAtTheRightEdgeDoesNotMoveTheLeftEdge() {
        var controller = adjusting(CGRect(x: 900, y: 100, width: 100, height: 100))
        controller.arrow(.right, modifiers: .shift)
        #expect(controller.rect == CGRect(x: 900, y: 100, width: 100, height: 100))
        var top = adjusting(CGRect(x: 100, y: 700, width: 100, height: 100))
        top.arrow(.up, modifiers: [.shift, .command])
        #expect(top.rect == CGRect(x: 100, y: 700, width: 100, height: 100))
        // Short of the edge it grows only as far as the edge.
        var near = adjusting(CGRect(x: 895, y: 100, width: 100, height: 100))
        near.arrow(.right, modifiers: [.shift, .command])
        #expect(near.rect == CGRect(x: 895, y: 100, width: 105, height: 100))
    }
}
