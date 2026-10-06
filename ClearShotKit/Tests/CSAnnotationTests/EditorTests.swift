import CoreGraphics
import CSCore
import CSTestSupport
import Foundation
import Testing
@testable import CSAnnotation

/// A red rectangle outline, 4 pixels wide, for editor tests.
func editorRectangle(_ rect: CGRect = CGRect(x: 10, y: 10, width: 20, height: 20),
                     color: RGBAColor = RGBAColor(red: 1, green: 0, blue: 0)) -> AnnotationObject {
    AnnotationObject(kind: .rectangle(rect), style: ObjectStyle(color: color, lineWidth: 4, shadow: false))
}

/// An editor over a white picture (100×80 unless told otherwise) with its own throwaway preferences and clock.
///
/// In the app, the undo manager groups each event's registrations into one step from the run loop. Tests have no run
/// loop, so the harness turns that off, and `act` opens one group per user action. A call that must record nothing is
/// made outside `act`: an undo registration there, with no group open, raises. The converse is a trap too: a call
/// inside `act` that records nothing (a coalesced nudge, an edit during a live change) leaves an empty undo group, and
/// the next `undo()` pops that group and does nothing.
@MainActor
final class EditorHarness {
    let throwaway = ThrowawayDefaults("editor")
    let defaults: UserDefaults
    let preferences: Preferences
    let editor: AnnotationEditor
    var clock = Date(timeIntervalSince1970: 1_000_000)

    /// `images` are stored by name beside the white base (a background's picture), or in its place under "original.png".
    init(baseSize: CGSize = CGSize(width: 100, height: 80), pixelScale: Double = 1, ops: [ImageOp] = [],
         canvasRect: CGRect? = nil, objects: [AnnotationObject] = [], background: DocumentBackground? = nil,
         isWindowShot: Bool = false, images: [String: CGImage] = [:]) {
        defaults = throwaway.defaults
        preferences = Preferences(defaults: defaults)
        var document = AnnotationDocument(baseSize: baseSize, pixelScale: pixelScale)
        document.imageOps = ops
        document.canvasRect = canvasRect
        document.objects = objects
        document.background = background
        document.isWindowShot = isWindowShot
        let base = TestBitmaps.solid(Int(baseSize.width), Int(baseSize.height), TestBitmaps.white)
        let store = ImageStore([ImageRef.original.name: base].merging(images) { _, supplied in supplied })
        editor = AnnotationEditor(document: document, images: store,
                                  source: .project(URL(filePath: "/tmp/Editor test.clearshot")), preferences: preferences)
        editor.undoManager.groupsByEvent = false
        editor.now = { [unowned self] in self.clock }
        editor.log = AppLogger(category: "annotate", sink: nil) // the unified log only, not the app's log file
    }

    /// One user action: whatever it registers becomes one undo step.
    func act(_ body: () -> Void) {
        editor.undoManager.beginUndoGrouping()
        body()
        editor.undoManager.endUndoGrouping()
    }

    /// The rect of the object with `id`, or nil if there is no such object or it has no rect.
    func rect(of id: UUID) -> CGRect? {
        editor.object(id).flatMap { ObjectGeometry.rect(of: $0.kind) }
    }
}

private let red = RGBAColor(red: 1, green: 0, blue: 0)
private let blue = RGBAColor(red: 0, green: 0, blue: 1)
private let green = RGBAColor(red: 0, green: 1, blue: 0)

private func styled(_ kind: ObjectKind) -> AnnotationObject {
    AnnotationObject(kind: kind, style: ObjectStyle(color: red, lineWidth: 4, shadow: false))
}

@MainActor
struct EditorUndoTests {
    @Test func aChangeUndoesAndRedoes() {
        let h = EditorHarness()
        let object = editorRectangle()
        h.act { h.editor.add(object, actionName: "Add Rectangle") }
        #expect(h.editor.document.objects == [object])
        #expect(h.editor.selection == [object.id])
        #expect(h.editor.undoManager.undoActionName == "Add Rectangle")
        h.editor.undoManager.undo()
        #expect(h.editor.document.objects.isEmpty)
        #expect(h.editor.selection.isEmpty)
        h.editor.undoManager.redo()
        #expect(h.editor.document.objects == [object])
    }

    @Test func aChangeThatChangesNothingRecordsNothing() {
        let h = EditorHarness(objects: [editorRectangle()])
        // Outside `act`: a registration here would raise.
        h.editor.change("Nothing") { _ in }
        h.editor.deleteSelection() // nothing is selected
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func aLiveChangeIsOneStep() {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object])
        h.act {
            h.editor.beginLiveChange()
            for _ in 1...5 {
                h.editor.updateLive { $0.objects[0] = ObjectGeometry.translated($0.objects[0], by: CGVector(dx: 1, dy: 0)) }
            }
            h.editor.endLiveChange("Move")
        }
        #expect(h.rect(of: object.id)?.minX == 15)
        #expect(!h.editor.isInLiveChange)
        h.editor.undoManager.undo()
        #expect(h.rect(of: object.id)?.minX == 10)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func aCancelledLiveChangeLeavesNoTrace() {
        let h = EditorHarness(objects: [editorRectangle()])
        let before = h.editor.document
        h.editor.beginLiveChange()
        h.editor.updateLive { $0.objects.removeAll() }
        #expect(h.editor.isInLiveChange)
        h.editor.cancelLiveChange()
        #expect(!h.editor.isInLiveChange)
        #expect(h.editor.document == before)
        #expect(!h.editor.undoManager.canUndo)
    }
}

@MainActor
struct EditorSliderTests {
    @Test func aSliderDragIsOneStep() {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object])
        h.editor.selection = [object.id]
        // Outside `act`: during the drag nothing may register, so a slider that recorded a step per event, or a restyle
        // that ignored the open live change, would raise here. Only the end of the drag registers its one step.
        h.editor.sliderEditingChanged(true, actionName: "Change Color")
        h.editor.setColor(blue)
        h.editor.setColor(green)
        h.act { h.editor.sliderEditingChanged(false, actionName: "Change Color") }
        #expect(!h.editor.isInLiveChange)
        #expect(h.editor.object(object.id)?.style.color == green)
        #expect(h.editor.undoManager.undoActionName == "Change Color")
        h.editor.undoManager.undo()
        #expect(h.editor.object(object.id)?.style.color == red)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func aSliderDragWhileTypingJoinsTheTextEdit() {
        let text = styled(.text(TextObject(origin: CGPoint(x: 5, y: 5), string: "Hi", style: .standard, fontSize: 14)))
        let h = EditorHarness(objects: [text])
        h.act {
            // The inline text edit: a live change of its own.
            h.editor.beginLiveChange()
            h.editor.editingTextID = text.id
            h.editor.sliderEditingChanged(true, actionName: "Change Color")
            h.editor.setColor(blue)
            h.editor.sliderEditingChanged(false, actionName: "Change Color")
            // The slider didn't end the text edit's live change.
            #expect(h.editor.isInLiveChange)
            h.editor.editingTextID = nil
            h.editor.endLiveChange("Edit Text")
        }
        #expect(h.editor.object(text.id)?.style.color == blue)
        #expect(h.editor.undoManager.undoActionName == "Edit Text")
        h.editor.undoManager.undo()
        #expect(h.editor.object(text.id)?.style.color == red)
        #expect(!h.editor.undoManager.canUndo)
    }
}

@MainActor
struct EditorCoalescingTests {
    private func harness() -> (EditorHarness, UUID) {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object])
        h.editor.selection = [object.id]
        return (h, object.id)
    }

    private func nudge(_ h: EditorHarness) {
        h.editor.nudgeSelection(by: CGVector(dx: 1, dy: 0))
    }

    @Test func nudgesLessThanASecondApartAreOneStep() {
        let (h, id) = harness()
        h.act { nudge(h) }
        h.clock += 0.5
        nudge(h) // coalesced: records nothing, so it is made outside `act`
        h.clock += 0.9
        nudge(h) // within a second of the one before
        #expect(h.rect(of: id)?.minX == 13)
        h.editor.undoManager.undo()
        #expect(h.rect(of: id)?.minX == 10)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func aStepJustUnderASecondLaterStillJoinsTheRun() {
        let (h, id) = harness()
        h.act { nudge(h) }
        h.clock += 0.999
        nudge(h) // coalesced: records nothing, so it is made outside `act`
        #expect(h.rect(of: id)?.minX == 12)
        h.editor.undoManager.undo()
        #expect(h.rect(of: id)?.minX == 10)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func exactlyASecondLaterStartsANewStep() {
        let (h, id) = harness()
        h.act { nudge(h) }
        h.clock += 1.0
        h.act { nudge(h) }
        h.editor.undoManager.undo()
        #expect(h.rect(of: id)?.minX == 11)
    }

    @Test func aPauseOfASecondStartsANewStep() {
        let (h, id) = harness()
        h.act { nudge(h) }
        h.clock += 1.5
        h.act { nudge(h) }
        h.editor.undoManager.undo()
        #expect(h.rect(of: id)?.minX == 11)
    }

    @Test func anotherSelectionStartsANewStep() {
        let first = editorRectangle()
        let second = editorRectangle(CGRect(x: 50, y: 10, width: 20, height: 20))
        let h = EditorHarness(objects: [first, second])
        h.editor.selection = [first.id]
        h.act { nudge(h) }
        h.editor.selection = [second.id]
        h.act { nudge(h) }
        h.editor.undoManager.undo()
        #expect(h.rect(of: first.id)?.minX == 11)
        #expect(h.rect(of: second.id)?.minX == 50)
    }

    @Test func anotherNameStartsANewStep() {
        let (h, id) = harness()
        h.act { nudge(h) }
        h.act { h.editor.setSizeLevel(5, coalescing: true) }
        h.editor.undoManager.undo()
        #expect(h.editor.object(id)?.style.lineWidth == 4)
        #expect(h.rect(of: id)?.minX == 11)
    }

    @Test func anyOtherStepEndsTheRun() {
        let (h, id) = harness()
        h.act { nudge(h) }
        h.act { h.editor.duplicateSelection() }
        h.editor.selection = [id]
        // Same name and selection, within a second, but the duplicate came between.
        h.act { nudge(h) }
        h.editor.undoManager.undo()
        #expect(h.rect(of: id)?.minX == 11)
    }

    @Test func undoEndsTheRun() {
        let (h, id) = harness()
        h.act { nudge(h) }
        h.editor.undoManager.undo()
        h.act { nudge(h) }
        #expect(h.rect(of: id)?.minX == 11)
        h.editor.undoManager.undo()
        #expect(h.rect(of: id)?.minX == 10)
    }

    @Test func redoEndsTheRun() {
        let (h, id) = harness()
        h.act { nudge(h) }
        h.editor.undoManager.undo()
        h.editor.undoManager.redo()
        h.act { nudge(h) }
        #expect(h.rect(of: id)?.minX == 12)
        h.editor.undoManager.undo()
        #expect(h.rect(of: id)?.minX == 11)
    }
}

@MainActor
struct EditorAppliedStateTests {
    @Test func undoingBackToTheAppliedStateLeavesNothingUnapplied() {
        let h = EditorHarness()
        #expect(!h.editor.hasUnappliedChanges)
        h.act { h.editor.add(editorRectangle(), actionName: "Add Rectangle") }
        #expect(h.editor.hasUnappliedChanges)
        h.editor.markApplied(h.editor.document)
        #expect(!h.editor.hasUnappliedChanges)
        h.act { h.editor.deleteSelection() }
        #expect(h.editor.hasUnappliedChanges)
        h.editor.undoManager.undo()
        #expect(!h.editor.hasUnappliedChanges)
    }
}

@MainActor
struct EditorStyleTests {
    private let area = CGRect(x: 0, y: 0, width: 10, height: 10)

    @Test func colorLeavesRedactionsSpotlightsAndImagesAlone() {
        let redaction = styled(.redact(RedactObject(rect: area, style: .pixelate, intensity: 5)))
        let spotlight = styled(.spotlight(SpotlightObject(rect: area, shape: .rectangle, opacity: 0.5)))
        let picture = styled(.image(ImageObject(rect: area, image: ImageRef(name: "images/a.png"))))
        let shape = editorRectangle()
        let h = EditorHarness(objects: [redaction, spotlight, picture, shape])
        h.editor.selection = Set(h.editor.document.objects.map(\.id))
        h.act { h.editor.setColor(blue) }
        #expect(h.editor.object(shape.id)?.style.color == blue)
        for id in [redaction.id, spotlight.id, picture.id] {
            #expect(h.editor.object(id)?.style.color == red)
        }
    }

    @Test func shadowsLeaveRedactionsSpotlightsAndHighlightsAlone() {
        let redaction = styled(.redact(RedactObject(rect: area, style: .pixelate, intensity: 5)))
        let spotlight = styled(.spotlight(SpotlightObject(rect: area, shape: .rectangle, opacity: 0.5)))
        let highlight = styled(.highlight(HighlightObject(points: [], rects: [area], width: 10, opacity: 0.4)))
        let shape = editorRectangle()
        let h = EditorHarness(objects: [redaction, spotlight, highlight, shape])
        h.editor.selection = Set(h.editor.document.objects.map(\.id))
        h.act { h.editor.setShadows(true) }
        #expect(h.editor.object(shape.id)?.style.shadow == true)
        for id in [redaction.id, spotlight.id, highlight.id] {
            #expect(h.editor.object(id)?.style.shadow == false)
        }
    }

    @Test func sizeLeavesRedactionsSpotlightsImagesAndSnappedHighlightsAlone() {
        let redaction = styled(.redact(RedactObject(rect: area, style: .pixelate, intensity: 5)))
        let spotlight = styled(.spotlight(SpotlightObject(rect: area, shape: .rectangle, opacity: 0.5)))
        let picture = styled(.image(ImageObject(rect: area, image: ImageRef(name: "images/a.png"))))
        let snapped = styled(.highlight(HighlightObject(points: [], rects: [area], width: 10, opacity: 0.4)))
        let h = EditorHarness(objects: [redaction, spotlight, picture, snapped])
        h.editor.selection = Set(h.editor.document.objects.map(\.id))
        // Nothing here takes a size, so the document must not change. In `act` so a restyle that wrongly does change it
        // fails this expectation, instead of raising for an undo registered outside a group.
        h.act { h.editor.setSizeLevel(5) }
        #expect(h.editor.settings.sizeLevel == 5)
        #expect(h.editor.document.objects == [redaction, spotlight, picture, snapped])
    }

    @Test func sizeRestylesShapesAndFreehandHighlights() throws {
        let shape = editorRectangle()
        let freehand = styled(.highlight(HighlightObject(points: [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)], rects: [],
                                                         width: 10, opacity: 0.4)))
        let h = EditorHarness(objects: [shape, freehand])
        h.editor.selection = [shape.id, freehand.id]
        h.act { h.editor.setSizeLevel(5) }
        #expect(h.editor.object(shape.id)?.style.lineWidth == ToolSizes.lineWidth(5))
        let restyled = try #require(h.editor.object(freehand.id))
        guard case .highlight(let highlight) = restyled.kind else {
            Issue.record("the highlight changed kind")
            return
        }
        #expect(highlight.width == ToolSizes.highlighterWidth(5))
        #expect(restyled.style.lineWidth == 4) // the marker's height is its width, not its line width
    }

    @Test func redactIntensityStaysWithinOneToTen() {
        let redaction = styled(.redact(RedactObject(rect: area, style: .pixelate, intensity: 5)))
        let h = EditorHarness(objects: [redaction])
        h.editor.selection = [redaction.id]
        h.act { h.editor.setRedactIntensity(0) }
        #expect(h.editor.settings.redactIntensity == 1)
        guard case .redact(let low) = h.editor.object(redaction.id)?.kind else {
            Issue.record("the redaction changed kind")
            return
        }
        #expect(low.intensity == 1)
        h.act { h.editor.setRedactIntensity(11) }
        #expect(h.editor.settings.redactIntensity == 10)
        guard case .redact(let high) = h.editor.object(redaction.id)?.kind else {
            Issue.record("the redaction changed kind")
            return
        }
        #expect(high.intensity == 10)
    }

    @Test func counterStartIsNeverNegative() {
        let h = EditorHarness()
        h.editor.setCounterStart(-3)
        #expect(h.editor.settings.counterStart == 0)
        h.editor.setCounterStart(7)
        #expect(h.editor.settings.counterStart == 7)
    }

    @Test func curvingAStraightArrowGivesItAControlPoint() {
        let start = CGPoint(x: 10, y: 10)
        let end = CGPoint(x: 90, y: 50)
        let arrow = styled(.arrow(ArrowShape(start: start, end: end, control: nil, style: .standard)))
        let h = EditorHarness(objects: [arrow])
        h.editor.selection = [arrow.id]
        h.act { h.editor.setArrowStyle(.curved) }
        #expect(h.editor.settings.arrowStyle == .curved)
        guard case .arrow(let curved) = h.editor.object(arrow.id)?.kind else {
            Issue.record("the arrow changed kind")
            return
        }
        #expect(curved.style == .curved)
        #expect(curved.control == ArrowGeometry.initialControl(start: start, end: end))
    }
}

@MainActor
struct EditorScreenDirectionTests {
    @Test func aNudgeFollowsTheScreenAfterRotating() {
        // At 2× and turned right, one point right on screen is two base pixels up.
        let object = editorRectangle()
        let h = EditorHarness(pixelScale: 2, ops: [.rotateRight], objects: [object])
        h.editor.selection = [object.id]
        h.act { h.editor.nudgeSelection(by: CGVector(dx: 1, dy: 0)) }
        #expect(h.rect(of: object.id)?.origin == CGPoint(x: 10, y: 8))
    }

    @Test func duplicatesAndPastesLandTenPointsAway() throws {
        let original = editorRectangle()
        let h = EditorHarness(pixelScale: 2, objects: [original])
        h.editor.selection = [original.id]
        h.act { h.editor.duplicateSelection() }
        let copy = try #require(h.editor.selectedObjects.first)
        #expect(copy.id != original.id)
        #expect(ObjectGeometry.rect(of: copy.kind)?.origin == CGPoint(x: 30, y: 30))
        h.act { h.editor.paste([original]) }
        let pasted = try #require(h.editor.selectedObjects.first)
        #expect(pasted.id != original.id)
        #expect(ObjectGeometry.rect(of: pasted.kind)?.origin == CGPoint(x: 30, y: 30))
        #expect(h.editor.document.objects.count == 3)
    }
}

@MainActor
struct EditorToolTests {
    @Test func aDrawingToolClearsTheSelection() {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object])
        h.editor.selection = [object.id]
        h.editor.tool = .arrow
        #expect(h.editor.selection.isEmpty)
    }

    @Test func selectKeepsTheSelection() {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object])
        h.editor.tool = .arrow
        h.editor.selection = [object.id] // the shape just drawn
        h.editor.tool = .select
        #expect(h.editor.selection == [object.id])
    }

    @Test func choosingTheActiveToolAgainKeepsTheSelection() {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object])
        h.editor.tool = .rectangle
        h.editor.selection = [object.id] // the shape just drawn
        h.editor.tool = .rectangle // the tool button assigns the tool it already has
        #expect(h.editor.selection == [object.id])
    }

    @Test func adoptingAStyleRecordsNoStep() {
        let h = EditorHarness()
        let other = AnnotationObject(kind: .rectangle(CGRect(x: 0, y: 0, width: 5, height: 5)),
                                     style: ObjectStyle(color: blue, lineWidth: h.editor.document.pixels(fromPoints: ToolSizes.lineWidth(5)),
                                                        shadow: false))
        h.act { h.editor.add(editorRectangle(), actionName: "Add Rectangle") }
        // Outside `act`: a registration here would raise.
        h.editor.adoptStyle(of: other)
        #expect(h.editor.settings.color == blue)
        #expect(h.editor.settings.sizeLevel == 5)
        h.editor.undoManager.undo()
        #expect(h.editor.document.objects.isEmpty)
        #expect(!h.editor.undoManager.canUndo)
    }
}

struct InitialControlTests {
    @Test func aCurvedArrowStartsWithAQuarterBend() {
        #expect(ArrowGeometry.initialControl(start: .zero, end: CGPoint(x: 100, y: 0)) == CGPoint(x: 50, y: 25))
    }
}
