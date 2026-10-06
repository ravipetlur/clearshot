import CoreGraphics
import CSCore
import Foundation
import Testing
@testable import CSAnnotation

@MainActor
struct AutoExpandTests {
    @Test func anObjectDrawnPastTheEdgeGrowsTheCanvasInTheSameStep() {
        let h = EditorHarness() // 100×80; "Automatically expand canvas" is on by default
        h.act { h.editor.add(editorRectangle(CGRect(x: 90, y: 10, width: 30, height: 20)), actionName: "Add Rectangle") }
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 136, height: 80))
        h.editor.undoManager.undo()
        #expect(h.editor.document.canvasRect == nil)
        #expect(h.editor.document.objects.isEmpty)
    }

    @Test func turnedOffItLeavesTheCanvasAlone() {
        let h = EditorHarness()
        h.preferences[Prefs.annotateAutoExpandCanvas] = false
        h.act { h.editor.add(editorRectangle(CGRect(x: 90, y: 10, width: 30, height: 20)), actionName: "Add Rectangle") }
        #expect(h.editor.document.canvasRect == nil)
    }

    @Test func aDragThatEndsPastTheEdgeGrowsTheCanvasWhenItEnds() {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object])
        h.act {
            h.editor.beginLiveChange()
            h.editor.updateLive { $0.objects[0] = ObjectGeometry.translated($0.objects[0], by: CGVector(dx: 0, dy: 70)) }
            // Not while the drag runs.
            #expect(h.editor.document.canvasRect == nil)
            h.editor.endLiveChange("Move")
        }
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 100, height: 116))
        h.editor.undoManager.undo()
        #expect(h.editor.document.canvasRect == nil)
        #expect(h.rect(of: object.id)?.minY == 10)
    }

    @Test func aCropThatCutsThroughAnObjectStaysCut() {
        let object = editorRectangle(CGRect(x: 60, y: 10, width: 30, height: 20))
        let h = EditorHarness(objects: [object])
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 0, y: 0, width: 70, height: 80))
        h.act { h.editor.applyCrop() }
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 70, height: 80))
        // Another object, inside the canvas: the cut one stays cut.
        h.act { h.editor.add(editorRectangle(CGRect(x: 5, y: 5, width: 10, height: 10)), actionName: "Add Rectangle") }
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 70, height: 80))
        // Moving the cut object changes it, so now the canvas grows to hold it.
        h.editor.selection = [object.id]
        h.act { h.editor.nudgeSelection(by: CGVector(dx: 1, dy: 0)) }
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 107, height: 80))
    }

    @Test func aCanvasCommitNeverExpandsEvenWhenItAddsAnObjectPastTheEdge() {
        // Image changes leave the objects alone, so only a body that adds one shows the difference from `change`.
        let h = EditorHarness()
        let object = editorRectangle(CGRect(x: 90, y: 10, width: 30, height: 20))
        h.act { h.editor.changeCanvas("Canvas change") { $0.objects.append(object) } }
        #expect(h.editor.document.objects == [object])
        #expect(h.editor.document.canvasRect == nil)
    }

    @Test func undoAndRedoNeverExpand() {
        // An object hanging off the picture (as if drawn with the setting off) is deleted; undo brings it back, new to
        // the document, and the setting is on.
        let object = editorRectangle(CGRect(x: 90, y: 10, width: 30, height: 20))
        let h = EditorHarness(objects: [object])
        h.editor.selection = [object.id]
        h.act { h.editor.deleteSelection() }
        h.editor.undoManager.undo()
        #expect(h.editor.document.objects == [object])
        #expect(h.editor.document.canvasRect == nil)
        h.editor.undoManager.redo()
        #expect(h.editor.document.objects.isEmpty)
        #expect(h.editor.document.canvasRect == nil)
    }

    @Test func imageChangesNeverExpand() {
        // An object already hanging off the picture (drawn with the setting off).
        let h = EditorHarness(objects: [editorRectangle(CGRect(x: 90, y: 10, width: 30, height: 20))])
        h.act { h.editor.rotateRight() }
        #expect(h.editor.document.canvasRect == nil)
        h.act { h.editor.setCanvasFill(.transparent) }
        #expect(h.editor.document.canvasRect == nil)
    }
}

@MainActor
struct CropModeTests {
    @Test func enteringCropStartsFromTheCanvas() throws {
        let h = EditorHarness()
        h.editor.tool = .crop
        let session = try #require(h.editor.crop)
        #expect(session.rect == CGRect(x: 0, y: 0, width: 100, height: 80))
        #expect(session.ratio == .freeform)
        #expect(session.viewport.contains(session.rect))
        #expect(h.editor.cropAspect == nil)
    }

    @Test func applyIsOneStepAndReturnsToTheToolBefore() {
        let h = EditorHarness()
        h.editor.tool = .arrow
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 10, y: 10, width: 50, height: 40))
        h.act { h.editor.applyCrop() }
        #expect(h.editor.crop == nil)
        #expect(h.editor.tool == .arrow)
        #expect(h.editor.document.canvasRect == CGRect(x: 10, y: 10, width: 50, height: 40))
        #expect(h.editor.undoManager.undoActionName == "Crop")
        h.editor.undoManager.undo()
        #expect(h.editor.document.canvasRect == nil)
    }

    @Test func cancelKeepsTheCanvasAndRecordsNothing() {
        let h = EditorHarness()
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 10, y: 10, width: 50, height: 40))
        h.editor.cancelCrop() // outside `act`: a registration would raise
        #expect(h.editor.crop == nil)
        #expect(h.editor.tool == .select)
        #expect(h.editor.document.canvasRect == nil)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func pickingAnotherToolApplies() {
        let h = EditorHarness()
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 10, y: 10, width: 50, height: 40))
        h.act { h.editor.tool = .pen }
        #expect(h.editor.crop == nil)
        #expect(h.editor.tool == .pen)
        #expect(h.editor.document.canvasRect == CGRect(x: 10, y: 10, width: 50, height: 40))
    }

    @Test func aCropOfTheWholePictureClearsTheCanvasRect() {
        let h = EditorHarness(canvasRect: CGRect(x: -20, y: 0, width: 120, height: 80))
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 0, y: 0, width: 100, height: 80))
        h.act { h.editor.applyCrop() }
        #expect(h.editor.document.canvasRect == nil)
    }

    @Test func draggingPastThePictureExpandsTheCanvas() {
        let h = EditorHarness()
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: -20, y: 0, width: 120, height: 90), final: true)
        #expect(h.editor.crop?.viewport.contains(CGRect(x: -20, y: 0, width: 120, height: 90)) == true)
        h.act { h.editor.applyCrop() }
        #expect(h.editor.document.canvasRect == CGRect(x: -20, y: 0, width: 120, height: 90))
    }

    @Test func theViewportGrowsWhenADragEndsNearItsEdgeAndNotBefore() throws {
        let h = EditorHarness() // 100×80: the starting viewport has 25 pixels to spare all round
        h.editor.tool = .crop
        let start = try #require(h.editor.crop).viewport
        // Well inside the viewport: even at the end of a drag there is room enough.
        h.editor.updateCrop(CGRect(x: 10, y: 10, width: 50, height: 40), final: true)
        #expect(h.editor.crop?.viewport == start)
        // Out near the viewport's edge: nothing moves while the drag runs, and the end of the drag makes room.
        let near = CGRect(x: -24, y: 0, width: 124, height: 80)
        h.editor.updateCrop(near)
        #expect(h.editor.crop?.viewport == start)
        h.editor.updateCrop(near, final: true)
        let grown = try #require(h.editor.crop).viewport
        #expect(grown.contains(start))
        #expect(grown.minX < start.minX)
    }

    @Test func aRatioReshapesThePendingCrop() {
        let h = EditorHarness()
        h.editor.tool = .crop
        h.editor.setCropRatio(.fixed(width: 1, height: 1))
        #expect(h.editor.crop?.rect == CGRect(x: 10, y: 0, width: 80, height: 80))
        #expect(h.editor.cropAspect == 1)
        h.editor.setCropRatio(.original)
        #expect(h.editor.cropAspect == 1.25)
    }

    @Test func rotateThenCropCutsTheTurnedPicture() throws {
        let h = EditorHarness() // 100×80
        // The base's left half red, its right half blue. Turned right, red is the top half of the picture and blue the lower.
        h.editor.addImage(TestBitmaps.split(100, 80, left: TestBitmaps.red, right: TestBitmaps.blue), for: .original)
        h.act { h.editor.rotateRight() } // the picture is now 80×100
        h.editor.tool = .crop
        #expect(h.editor.crop?.rect == CGRect(x: 0, y: 0, width: 80, height: 100))
        // The lower half, as the screen shows it.
        h.editor.updateCrop(CGRect(x: 0, y: 50, width: 80, height: 50))
        h.act { h.editor.applyCrop() }
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 50, width: 80, height: 50))
        let rendered = try #require(Renderer.render(h.editor.document, images: h.editor.images))
        #expect(rendered.width == 80)
        #expect(rendered.height == 50)
        // What survives is the blue half the overlay showed, corner to corner.
        let blue = TestBitmaps.RGBA(r: 0, g: 0, b: 255, a: 255)
        for (x, y) in [(1, 1), (78, 1), (40, 25), (1, 48), (78, 48)] {
            #expect(TestBitmaps.pixel(rendered, x, y) == blue, "at \(x), \(y)")
        }
    }

    @Test func rotatingWhileCroppingTurnsThePendingCrop() {
        let h = EditorHarness() // 100×80
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 0, y: 0, width: 50, height: 80)) // the left half
        h.act { h.editor.rotateRight() }
        // rotateRight maps (x, y) to (80 − y, x): the left half becomes the top half of the 80×100 picture.
        #expect(h.editor.crop?.rect == CGRect(x: 0, y: 0, width: 80, height: 50))
        #expect(h.editor.tool == .crop)
    }

    @Test func undoWhileCroppingStartsTheCropOverFromTheCanvas() {
        let h = EditorHarness()
        h.editor.tool = .crop
        h.act { h.editor.rotateRight() }
        h.editor.updateCrop(CGRect(x: 0, y: 0, width: 40, height: 40))
        h.editor.undoManager.undo()
        #expect(h.editor.document.imageOps.isEmpty)
        #expect(h.editor.crop?.rect == CGRect(x: 0, y: 0, width: 100, height: 80))
    }
}

@MainActor
struct ImageChangeTests {
    @Test func eachRotateAndFlipIsOneStep() {
        let h = EditorHarness()
        h.act { h.editor.rotateLeft() }
        #expect(h.editor.undoManager.undoActionName == "Rotate Left")
        h.act { h.editor.flipHorizontally() }
        h.act { h.editor.flipVertically() }
        #expect(h.editor.document.imageOps == [.rotateLeft, .flipHorizontal, .flipVertical])
        h.editor.undoManager.undo()
        #expect(h.editor.document.imageOps == [.rotateLeft, .flipHorizontal])
    }

    @Test func resizeIsAnImageOperationClampedToTheLimit() {
        let h = EditorHarness()
        h.act { h.editor.resizeImage(width: 50, height: 40) }
        #expect(h.editor.document.imageOps == [.resize(width: 50, height: 40)])
        #expect(h.editor.undoManager.undoActionName == "Resize Image")
        h.editor.undoManager.undo()
        h.act { h.editor.resizeImage(width: 100_000, height: 80_000) }
        #expect(h.editor.document.imageOps == [.resize(width: 16_383, height: 16_383)])
    }

    @Test func resizingToTheCurrentSizeRecordsNothing() {
        let h = EditorHarness()
        h.editor.resizeImage(width: 100, height: 80) // outside `act`: a registration would raise
        #expect(h.editor.document.imageOps.isEmpty)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func revertClearsImageChangesAndKeepsObjects() {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object])
        h.act { h.editor.rotateRight() }
        h.act { h.editor.setCanvasFill(.transparent) }
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 0, y: 0, width: 40, height: 40))
        h.act { h.editor.applyCrop() }
        #expect(h.editor.document.canRevertToOriginal)
        h.act { h.editor.revertToOriginal() }
        #expect(h.editor.document.imageOps.isEmpty)
        #expect(h.editor.document.canvasRect == nil)
        #expect(h.editor.document.canvasFill == .auto)
        #expect(h.editor.document.objects == [object])
        #expect(!h.editor.document.canRevertToOriginal)
        h.editor.undoManager.undo()
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 40, height: 40))
    }

    @Test func revertWithNothingToRevertRecordsNothing() {
        let h = EditorHarness()
        h.editor.revertToOriginal() // outside `act`: a registration would raise
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func fillChangesAreCanvasSteps() {
        let blue = RGBAColor(red: 0, green: 0, blue: 1)
        let h = EditorHarness()
        #expect(h.editor.canvasFillColor == .white)
        h.act { h.editor.setCanvasFill(.color(blue)) }
        #expect(h.editor.document.canvasFill == .color(blue))
        #expect(h.editor.canvasFillColor == blue)
        h.editor.undoManager.undo()
        #expect(h.editor.document.canvasFill == .auto)
    }

    @Test func aStreamOfFillColorsIsOneStep() {
        let h = EditorHarness()
        h.act { h.editor.setCanvasFill(.color(RGBAColor(red: 1, green: 0, blue: 0)), coalescing: true) }
        h.clock += 0.2
        h.editor.setCanvasFill(.color(RGBAColor(red: 0, green: 0, blue: 1)), coalescing: true) // coalesced
        h.editor.undoManager.undo()
        #expect(h.editor.document.canvasFill == .auto)
    }
}

/// A picture cropped to a canvas smaller than itself, the way the Resize sheet meets one.
@MainActor
struct ResizeCanvasTests {
    /// A 2880×1800 picture cropped to (100, 100, 1500, 900).
    private func croppedHarness(baseSize: CGSize = CGSize(width: 2880, height: 1800),
                                crop: CGRect = CGRect(x: 100, y: 100, width: 1500, height: 900)) -> EditorHarness {
        let h = EditorHarness(baseSize: baseSize)
        h.editor.tool = .crop
        h.editor.updateCrop(crop)
        h.act { h.editor.applyCrop() }
        return h
    }

    @Test func resizingACroppedCanvasGivesExactlyTheRequestedSize() throws {
        let h = croppedHarness()
        h.act { h.editor.resizeImage(width: 1000, height: 600) }
        let canvas = h.editor.document.canvasBounds
        #expect(canvas.size == CGSize(width: 1000, height: 600))
        #expect(canvas == canvas.integral)
        // What the Resize sheet promised is what is written: the export rounds the canvas outward.
        let rendered = try #require(Renderer.render(h.editor.document, images: h.editor.images))
        #expect(rendered.width == 1000)
        #expect(rendered.height == 600)
        #expect(h.editor.undoManager.undoActionName == "Resize Image")
    }

    @Test func resizingACanvasThatDoesNotDivideEvenlyGivesExactlyTheRequestedSize() throws {
        let h = EditorHarness(canvasRect: CGRect(x: 10, y: 10, width: 50, height: 40))
        h.act { h.editor.resizeImage(width: 33, height: 27) }
        #expect(h.editor.document.canvasBounds.size == CGSize(width: 33, height: 27))
        let rendered = try #require(Renderer.render(h.editor.document, images: h.editor.images))
        #expect(rendered.width == 33)
        #expect(rendered.height == 27)
    }

    @Test func repeatingAResizeOfACroppedCanvasRecordsNothingMore() {
        let h = croppedHarness()
        h.act { h.editor.resizeImage(width: 1000, height: 600) }
        h.act { h.editor.resizeImage(width: 1000, height: 600) }
        #expect(h.editor.document.imageOps == [.resize(width: 1920, height: 1200)])
    }

    @Test func aResizePastWhatThePictureCanHoldKeepsTheRequestedAspect() throws {
        // A 400×300 crop of 4000×3000: 4000×3000 asked of the canvas would need a 40 000-pixel picture.
        let h = croppedHarness(baseSize: CGSize(width: 4000, height: 3000),
                               crop: CGRect(x: 100, y: 100, width: 400, height: 300))
        h.act { h.editor.resizeImage(width: 4000, height: 3000) }
        let size = h.editor.document.canvasBounds.size
        #expect(abs(size.width / size.height - 4.0 / 3.0) < 0.01)
        #expect(size.width < 4000)
        let operation = try #require(h.editor.document.imageOps.last)
        guard case .resize(let width, let height) = operation else {
            Issue.record("the last operation is not a resize")
            return
        }
        #expect(width <= 16_383 && height <= 16_383)
    }

    @Test func theResizeLimitShrinksOnACropOfALargerPictureAndMeetsThePictureShareLimit() throws {
        let h = croppedHarness(baseSize: CGSize(width: 4000, height: 3000),
                               crop: CGRect(x: 100, y: 100, width: 400, height: 300))
        let limit = h.editor.resizeLimit
        #expect(limit == CGSize(width: 1638, height: 1638)) // 16 383 × 400 ÷ 4000, and × 300 ÷ 3000, rounded down
        // Asking for exactly the limit is honoured as asked, and the picture's share of it fits.
        h.act { h.editor.resizeImage(width: 1638, height: 1638) }
        #expect(h.editor.document.canvasBounds.size == limit)
        let operation = try #require(h.editor.document.imageOps.last)
        guard case .resize(let width, let height) = operation else {
            Issue.record("the last operation is not a resize")
            return
        }
        #expect(width <= 16_383 && height <= 16_383)
        // At the limit the picture is as large as it may be, so the limit is the same one again.
        #expect(h.editor.resizeLimit == limit)
    }

    @Test func theResizeLimitIsTheOutputLimitWhileTheCanvasIsAtLeastThePicture() {
        let output = CGSize(width: 16_383, height: 16_383)
        #expect(EditorHarness().editor.resizeLimit == output)
        #expect(EditorHarness(canvasRect: CGRect(x: -20, y: 0, width: 200, height: 160)).editor.resizeLimit == output)
    }
}

/// Auto-expand while a crop is pending: the session follows the canvas the person hasn't cropped, and leaves alone the
/// crop they have.
@MainActor
struct CropFollowsCanvasTests {
    /// The only object (10…30) dragged 90 pixels right and dropped: it reaches 120, so the canvas grows to 136.
    private func dragTheObjectPastTheRightEdge(_ h: EditorHarness) {
        h.act {
            h.editor.beginLiveChange()
            h.editor.updateLive { $0.objects[0] = ObjectGeometry.translated($0.objects[0], by: CGVector(dx: 90, dy: 0)) }
            h.editor.endLiveChange("Move")
        }
    }

    @Test(arguments: [true, false])
    func anUntouchedCropFollowsAnAutoExpand(applying: Bool) {
        let h = EditorHarness(objects: [editorRectangle()])
        h.editor.tool = .arrow
        h.editor.tool = .crop
        dragTheObjectPastTheRightEdge(h)
        let grown = CGRect(x: 0, y: 0, width: 136, height: 80)
        #expect(h.editor.document.canvasRect == grown)
        #expect(h.editor.crop?.rect == grown)
        #expect(h.editor.crop?.viewport.contains(grown) == true)
        // Return, or another tool: either way the crop that was never touched changes nothing.
        h.act { if applying { h.editor.applyCrop() } else { h.editor.tool = .pen } }
        #expect(h.editor.document.canvasRect == grown)
        #expect(h.editor.undoManager.undoActionName != "Crop")
    }

    @Test func aTouchedCropStandsAfterAnAutoExpand() {
        let h = EditorHarness(objects: [editorRectangle()])
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 0, y: 0, width: 50, height: 80), final: true) // the right edge dragged in
        // The object dragged past the left edge (10 → −20): the canvas grows to −36.
        h.act {
            h.editor.beginLiveChange()
            h.editor.updateLive { $0.objects[0] = ObjectGeometry.translated($0.objects[0], by: CGVector(dx: -30, dy: 0)) }
            h.editor.endLiveChange("Move")
        }
        #expect(h.editor.document.canvasRect == CGRect(x: -36, y: 0, width: 136, height: 80))
        #expect(h.editor.crop?.rect == CGRect(x: 0, y: 0, width: 50, height: 80))
        h.act { h.editor.applyCrop() }
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 50, height: 80))
    }

    @Test func anAddedObjectThatGrowsTheCanvasIsKeptByAnUntouchedCrop() {
        let h = EditorHarness()
        h.editor.tool = .crop
        h.act { h.editor.add(editorRectangle(CGRect(x: 90, y: 10, width: 30, height: 20)), actionName: "Add Rectangle") }
        h.act { h.editor.applyCrop() }
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 136, height: 80))
    }

    @Test(arguments: [CGRect(x: 10, y: 10, width: 5, height: 5), CGRect(x: 10.5, y: 10.25, width: 40.5, height: 30.75)])
    func leavingAnUntouchedCropNeverRecordsAStepOrClearsRedo(canvas: CGRect) {
        // A canvas under the 8-pixel minimum, or on fractions of a pixel, is not one a crop could write back.
        let h = EditorHarness(canvasRect: canvas)
        h.act { h.editor.setCanvasFill(.transparent) }
        h.editor.undoManager.undo()
        #expect(h.editor.undoManager.canRedo)
        h.editor.tool = .crop
        // Not `act`: ending an empty undo group clears the redo stack by itself, so the group stays open while we look.
        h.editor.undoManager.beginUndoGrouping()
        h.editor.tool = .select
        #expect(h.editor.document.canvasRect == canvas)
        #expect(h.editor.undoManager.canRedo)
        h.editor.undoManager.endUndoGrouping()
    }

    @Test func anUntouchedCropStaysTheCanvasThroughAnImageChange() {
        // Turned by the transform and clamped to a minimum crop, a 5×5 canvas would become 8×8, and so look cropped.
        let h = EditorHarness(canvasRect: CGRect(x: 10, y: 10, width: 5, height: 5))
        h.editor.tool = .crop
        h.act { h.editor.rotateRight() }
        let rotated = h.editor.document.canvasBounds
        #expect(rotated.size == CGSize(width: 5, height: 5))
        #expect(h.editor.crop?.rect == rotated)
        h.act { h.editor.tool = .select }
        #expect(h.editor.document.canvasRect == rotated)
        #expect(h.editor.undoManager.undoActionName != "Crop")
    }

    @Test func redoWhileCroppingStartsTheCropOverFromTheRestoredCanvas() {
        let h = EditorHarness()
        h.act { h.editor.add(editorRectangle(CGRect(x: 90, y: 10, width: 30, height: 20)), actionName: "Add Rectangle") }
        h.editor.undoManager.undo()
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 0, y: 0, width: 40, height: 40))
        h.editor.undoManager.redo()
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 136, height: 80))
        #expect(h.editor.crop?.rect == CGRect(x: 0, y: 0, width: 136, height: 80))
    }

    @Test func aPendingCropIsNotAnUnappliedChangeUntilItIsApplied() {
        // Every output and close applies a pending crop first (the window's `finishEditing`); the model doesn't count it.
        let h = EditorHarness()
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 10, y: 10, width: 50, height: 40))
        #expect(!h.editor.hasUnappliedChanges)
        h.act { h.editor.applyCrop() }
        #expect(h.editor.hasUnappliedChanges)
    }

    @Test func theViewportStaysWithinTheLimitWhateverTheDrags() {
        let h = EditorHarness()
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: -30_000, y: 0, width: 120, height: 90), final: true)
        let second = CGRect(x: 30_000, y: 0, width: 120, height: 90)
        h.editor.updateCrop(second, final: true)
        let viewport = h.editor.crop?.viewport ?? .null
        #expect(viewport.width <= AnnotationDocument.maximumSide)
        #expect(viewport.height <= AnnotationDocument.maximumSide)
        #expect(viewport.contains(second))
    }
}

/// An open live change (a drag, a slider, a text edit) is the person's first; canvas commands wait for it.
@MainActor
struct LiveChangeGuardTests {
    @Test func canvasCommandsWaitForAnOpenLiveChange() {
        let h = EditorHarness(objects: [editorRectangle()])
        h.act { h.editor.rotateRight() } // something for Revert to Original to undo
        h.editor.beginLiveChange()
        h.act {
            h.editor.rotateLeft()
            h.editor.flipHorizontally()
            h.editor.flipVertically()
            h.editor.resizeImage(width: 50, height: 40)
            h.editor.setCanvasFill(.transparent)
            h.editor.revertToOriginal()
            h.editor.tool = .crop
        }
        #expect(h.editor.document.imageOps == [.rotateRight])
        #expect(h.editor.document.canvasFill == .auto)
        #expect(h.editor.crop == nil)
        h.editor.cancelLiveChange()
        h.act { h.editor.flipVertically() }
        #expect(h.editor.document.imageOps == [.rotateRight, .flipVertical])
    }

    /// ⌘V during a Select drag (the key arrives with the mouse down): the paste would go into the drag's undo step.
    @Test func pastingWaitsForAnOpenLiveChange() {
        let moved = editorRectangle()
        let h = EditorHarness(objects: [moved])
        h.editor.beginLiveChange()
        h.editor.updateLive { $0.objects[0] = ObjectGeometry.translated($0.objects[0], by: CGVector(dx: 5, dy: 0)) }
        h.editor.paste([editorRectangle(CGRect(x: 40, y: 40, width: 10, height: 10))], sourceScale: 1) // outside `act`
        #expect(h.editor.document.objects.count == 1)
        #expect(h.editor.isInLiveChange)
        h.act { h.editor.endLiveChange("Move") }
        #expect(h.editor.undoManager.undoActionName == "Move")
        // With the drag over, the same paste goes through, as a step of its own.
        h.act { h.editor.paste([editorRectangle(CGRect(x: 40, y: 40, width: 10, height: 10))], sourceScale: 1) }
        #expect(h.editor.document.objects.count == 2)
        h.editor.undoManager.undo()
        #expect(h.editor.document.objects.count == 1)
        #expect(h.rect(of: moved.id)?.minX == 15)
    }

    @Test func anOpenLiveChangeHoldsBackApplyingTheCrop() {
        let h = EditorHarness(objects: [editorRectangle()])
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 10, y: 10, width: 50, height: 40))
        h.editor.beginLiveChange()
        h.act { h.editor.applyCrop() }
        #expect(h.editor.document.canvasRect == nil)
        #expect(h.editor.crop?.rect == CGRect(x: 10, y: 10, width: 50, height: 40))
        #expect(h.editor.tool == .crop)
        h.editor.cancelLiveChange()
        h.act { h.editor.applyCrop() }
        #expect(h.editor.document.canvasRect == CGRect(x: 10, y: 10, width: 50, height: 40))
    }

    @Test func leavingCropModeDuringALiveChangeDropsTheSessionWithoutWritingIt() {
        let h = EditorHarness(objects: [editorRectangle()])
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 10, y: 10, width: 50, height: 40))
        h.editor.beginLiveChange()
        h.act { h.editor.tool = .pen }
        #expect(h.editor.tool == .pen)
        #expect(h.editor.crop == nil)
        #expect(h.editor.document.canvasRect == nil)
    }

    @Test func aCropSessionStartsOnceTheLiveChangeThatBlockedItHasEnded() throws {
        let h = EditorHarness(objects: [editorRectangle()])
        h.editor.tool = .arrow
        h.editor.beginLiveChange() // a text edit being typed
        h.editor.tool = .crop
        #expect(h.editor.crop == nil)
        // Nothing starts one while the change is open.
        h.editor.ensureCropSession()
        #expect(h.editor.crop == nil)
        // Ending it starts one.
        h.editor.endLiveChange("Edit Text")
        let session = try #require(h.editor.crop)
        #expect(session.rect == CGRect(x: 0, y: 0, width: 100, height: 80))
        #expect(session.isUntouched)
        // A second call keeps the session as it is.
        h.editor.updateCrop(CGRect(x: 10, y: 10, width: 50, height: 40))
        h.editor.ensureCropSession()
        #expect(h.editor.crop?.rect == CGRect(x: 10, y: 10, width: 50, height: 40))
        h.act { h.editor.applyCrop() }
        #expect(h.editor.tool == .arrow)
        #expect(h.editor.crop == nil)
        #expect(h.editor.document.canvasRect == CGRect(x: 10, y: 10, width: 50, height: 40))
    }

    /// Crop & Resize picked while a Select drag or a slider holds a change open (C pressed with the mouse still down) gets
    /// no session then; the change ending starts it, on the canvas the change left.
    @Test func aCropModeEnteredDuringALiveChangeGetsItsSessionWhenTheChangeEnds() throws {
        let h = EditorHarness(objects: [editorRectangle(CGRect(x: 70, y: 10, width: 20, height: 20))]) // 100×80, auto-expand on
        h.editor.beginLiveChange() // the drag
        h.editor.updateLive { $0.objects[0] = ObjectGeometry.translated($0.objects[0], by: CGVector(dx: 30, dy: 0)) }
        h.editor.tool = .crop
        #expect(h.editor.crop == nil)
        h.act { h.editor.endLiveChange("Move") }
        let session = try #require(h.editor.crop)
        // The rectangle went past the edge, so the canvas grew as the drag ended; the crop starts from that canvas.
        #expect(h.editor.document.canvasRect != nil)
        #expect(session.rect == h.editor.document.canvasBounds)
        #expect(session.isUntouched)
        #expect(h.editor.tool == .crop)
    }

    @Test func aCropModeEnteredDuringALiveChangeGetsItsSessionWhenTheChangeIsCancelled() throws {
        let h = EditorHarness(objects: [editorRectangle()])
        h.editor.beginLiveChange()
        h.editor.tool = .crop
        #expect(h.editor.crop == nil)
        h.editor.cancelLiveChange() // records nothing
        let session = try #require(h.editor.crop)
        #expect(session.rect == CGRect(x: 0, y: 0, width: 100, height: 80))
        #expect(session.isUntouched)
    }

    @Test func ensuringACropSessionDoesNothingOutsideCropMode() {
        let h = EditorHarness()
        h.editor.ensureCropSession()
        #expect(h.editor.crop == nil)
        #expect(h.editor.tool == .select)
    }
}

/// Auto-expand and undo, through the other routes an object change takes.
@MainActor
struct AutoExpandRouteTests {
    @Test func aHeldArrowKeyThatExpandsTheCanvasIsOneStep() {
        let object = editorRectangle(CGRect(x: 75, y: 10, width: 20, height: 20))
        let h = EditorHarness(objects: [object])
        h.editor.selection = [object.id]
        h.act { h.editor.nudgeSelection(by: CGVector(dx: 10, dy: 0)) }
        for _ in 0..<2 {
            h.clock += 0.1
            h.editor.nudgeSelection(by: CGVector(dx: 10, dy: 0)) // coalesced: registers nothing
        }
        #expect(h.rect(of: object.id)?.minX == 105)
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 141, height: 80))
        h.editor.undoManager.undo()
        #expect(h.editor.document.canvasRect == nil)
        #expect(h.rect(of: object.id)?.minX == 75)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func aSliderDragThatExpandsTheCanvasIsOneStep() {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object])
        h.act {
            h.editor.sliderEditingChanged(true, actionName: "Change Size")
            h.editor.updateLive { $0.objects[0] = ObjectGeometry.translated($0.objects[0], by: CGVector(dx: 90, dy: 0)) }
            #expect(h.editor.document.canvasRect == nil) // not while the slider is held
            h.editor.sliderEditingChanged(false, actionName: "Change Size")
        }
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 136, height: 80))
        #expect(h.editor.undoManager.undoActionName == "Change Size")
        h.editor.undoManager.undo()
        #expect(h.editor.document.canvasRect == nil)
        #expect(h.rect(of: object.id)?.minX == 10)
    }
}
