import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

private func arrowObject(_ style: ArrowStyle, control: CGPoint? = nil) -> AnnotationObject {
    AnnotationObject(kind: .arrow(ArrowShape(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), control: control, style: style)),
                     style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
}

/// The points of a path's first subpath that a straight-line approximation passes through.
private func points(of path: CGPath) -> [CGPoint] {
    var result: [CGPoint] = []
    path.applyWithBlock { element in
        let element = element.pointee
        switch element.type {
        case .moveToPoint, .addLineToPoint: result.append(element.points[0])
        case .addQuadCurveToPoint: result.append(element.points[1])
        case .addCurveToPoint: result.append(element.points[2])
        default: break
        }
    }
    return result
}

struct BendableArrowTests {
    @Test func everyStyleHasABendHandle() {
        for style in ArrowStyle.allCases {
            #expect(ObjectGeometry.handles(of: arrowObject(style)) == [.start, .end, .control])
        }
    }

    @Test func theHandleSitsOnTheCurveAtItsMiddle() {
        let bent = arrowObject(.standard, control: CGPoint(x: 50, y: 40))
        #expect(ObjectGeometry.handlePoint(.control, of: bent) == CGPoint(x: 50, y: 20))
        #expect(ObjectGeometry.handlePoint(.control, of: arrowObject(.double)) == CGPoint(x: 50, y: 0))
    }

    @Test func draggingTheHandleBendsAnyStyleThroughThePoint() {
        for style in ArrowStyle.allCases {
            let dragged = ObjectGeometry.dragging(.control, of: arrowObject(style), to: CGPoint(x: 50, y: 20), constrained: false)
            guard case .arrow(let arrow) = dragged.kind else { Issue.record("not an arrow"); return }
            #expect(arrow.control == CGPoint(x: 50, y: 40))
            #expect(arrow.style == style)
            #expect(ArrowGeometry.midpoint(of: arrow) == CGPoint(x: 50, y: 20))
        }
    }

    @Test func draggingTheHandleBackOntoTheChordStraightensTheArrow() {
        let bent = arrowObject(.fancy, control: CGPoint(x: 50, y: 40))
        let dragged = ObjectGeometry.dragging(.control, of: bent, to: CGPoint(x: 50, y: 0), constrained: false)
        guard case .arrow(let arrow) = dragged.kind else { Issue.record("not an arrow"); return }
        #expect(arrow.control == nil)
    }

    @Test func theSpineAndBoundsFollowTheBendOfAnyStyle() {
        let bent = arrowObject(.standard, control: CGPoint(x: 50, y: 60))
        #expect(ArrowGeometry.spine(of: ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), control: CGPoint(x: 50, y: 60), style: .double)).count > 2)
        #expect(ObjectGeometry.bounds(of: bent).maxY > 25)
        #expect(ObjectGeometry.hitTest(bent, at: CGPoint(x: 50, y: 30), tolerance: 2))
        #expect(!ObjectGeometry.hitTest(arrowObject(.standard), at: CGPoint(x: 50, y: 30), tolerance: 2))
    }

    @Test func theHeadFollowsTheTangentAtTheEnd() {
        let arrow = ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), control: CGPoint(x: 100, y: 80), style: .standard)
        let head = points(of: ArrowGeometry.parts(for: arrow, width: 4).fills[0])
        // Tip, then the two base corners: the base's middle is straight back along the tangent (control to end: straight down).
        let tip = head[0]
        let baseMiddle = CGPoint(x: (head[1].x + head[2].x) / 2, y: (head[1].y + head[2].y) / 2)
        #expect(tip == CGPoint(x: 100, y: 0))
        #expect(abs(baseMiddle.x - 100) < 0.001)
        #expect(baseMiddle.y > 0)
    }

    @Test func aDoubleHeadedArrowHasATangentHeadAtEachEnd() {
        let arrow = ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), control: CGPoint(x: 50, y: 60), style: .double)
        let parts = ArrowGeometry.parts(for: arrow, width: 4)
        #expect(parts.fills.count == 2)
        let startHead = points(of: parts.fills[1])
        let baseMiddle = CGPoint(x: (startHead[1].x + startHead[2].x) / 2, y: (startHead[1].y + startHead[2].y) / 2)
        // The tangent at the start runs from the start towards the control point: the head sits back along it.
        let direction = CGVector(dx: baseMiddle.x - startHead[0].x, dy: baseMiddle.y - startHead[0].y)
        let expected = ArrowGeometry.unit(from: arrow.control!, to: .zero)
        let length = hypot(direction.dx, direction.dy)
        #expect(abs(direction.dx / length - -expected.dx) < 0.001)
        #expect(abs(direction.dy / length - -expected.dy) < 0.001)
        #expect(!parts.shaft.isEmpty)
    }

    @Test func aStraightArrowIsDrawnAsBefore() {
        let straight = ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), style: .standard)
        let parts = ArrowGeometry.parts(for: straight, width: 4)
        #expect(points(of: parts.shaft) == [CGPoint(x: 0, y: 0), CGPoint(x: 100 - ArrowGeometry.headLength(for: 4) - 2, y: 0)])
        let fancy = ArrowGeometry.parts(for: ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), style: .fancy), width: 4)
        #expect(points(of: fancy.fills[0]).count == 7)
    }

    @Test func aBentFancyArrowCurvesItsBody() {
        let fancy = ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), control: CGPoint(x: 50, y: 60), style: .fancy)
        let body = points(of: ArrowGeometry.parts(for: fancy, width: 4).fills[0])
        #expect(body.count > 7)
        #expect(body.contains { $0.y > 20 })
        #expect(body.contains(CGPoint(x: 100, y: 0)))
    }

    @Test func aControlPointOnAnEndLeavesAStraightArrow() {
        let arrow = ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), control: CGPoint(x: 100, y: 0), style: .standard)
        let parts = ArrowGeometry.parts(for: arrow, width: 4)
        #expect(points(of: parts.shaft).count == 2)
    }

    @Test func anOldDocumentsArrowDecodesUnchanged() throws {
        let json = #"{"start":[0,0],"end":[10,0],"style":"curved","control":[5,5]}"#
        let arrow = try JSONDecoder().decode(ArrowShape.self, from: Data(json.utf8))
        #expect(arrow == ArrowShape(start: .zero, end: CGPoint(x: 10, y: 0), control: CGPoint(x: 5, y: 5), style: .curved))
        let straight = try JSONDecoder().decode(ArrowShape.self, from: Data(#"{"start":[0,0],"end":[10,0],"style":"standard"}"#.utf8))
        #expect(straight.control == nil)
    }
}

@MainActor
struct ArrowEditorTests {
    @Test func changingTheStyleKeepsTheBend() {
        let object = arrowObject(.standard, control: CGPoint(x: 50, y: 30))
        let h = EditorHarness(objects: [object])
        h.editor.selection = [object.id]
        h.act { h.editor.setArrowStyle(.fancy) }
        guard case .arrow(let arrow) = h.editor.object(object.id)?.kind else { Issue.record("not an arrow"); return }
        #expect(arrow.style == .fancy)
        #expect(arrow.control == CGPoint(x: 50, y: 30))
    }

    @Test func curvedStillStartsBent() {
        let object = arrowObject(.standard)
        let h = EditorHarness(objects: [object])
        h.editor.selection = [object.id]
        h.act { h.editor.setArrowStyle(.curved) }
        guard case .arrow(let arrow) = h.editor.object(object.id)?.kind else { Issue.record("not an arrow"); return }
        #expect(arrow.control == ArrowGeometry.initialControl(start: arrow.start, end: arrow.end))
    }

    @Test func straighteningIsOneUndoStep() {
        let object = arrowObject(.double, control: CGPoint(x: 50, y: 30))
        let h = EditorHarness(objects: [object])
        h.act { h.editor.straightenArrow(object.id) }
        guard case .arrow(let arrow) = h.editor.object(object.id)?.kind else { Issue.record("not an arrow"); return }
        #expect(arrow.control == nil)
        h.editor.undoManager.undo()
        guard case .arrow(let restored) = h.editor.object(object.id)?.kind else { Issue.record("not an arrow"); return }
        #expect(restored.control == CGPoint(x: 50, y: 30))
    }
}

@MainActor
struct HandDrawnEditorTests {
    private func rectangle(handDrawn: Bool, seed: UInt32 = 0) -> AnnotationObject {
        AnnotationObject(kind: .rectangle(CGRect(x: 10, y: 10, width: 40, height: 30)),
                         style: ObjectStyle(color: .black, lineWidth: 4, shadow: false, handDrawn: handDrawn, seed: seed))
    }

    @Test func theToggleRestylesTheSelectionAndRemembersTheSetting() {
        let object = rectangle(handDrawn: false)
        let h = EditorHarness(objects: [object])
        h.editor.selection = [object.id]
        h.act { h.editor.setHandDrawn(true) }
        let updated = h.editor.object(object.id)
        #expect(updated?.style.handDrawn == true)
        #expect(updated?.style.seed != 0)
        #expect(h.editor.settings.handDrawn)
        h.editor.undoManager.undo()
        #expect(h.editor.object(object.id) == object)
    }

    @Test func textTakesTheFlagInItsOwnObject() {
        let text = AnnotationObject(kind: .text(TextObject(origin: .zero, string: "Hi", style: .standard, fontSize: 20)),
                                    style: ObjectStyle(color: .black, lineWidth: 1, shadow: false))
        let h = EditorHarness(objects: [text])
        h.editor.selection = [text.id]
        h.act { h.editor.setHandDrawn(true) }
        guard case .text(let changed) = h.editor.object(text.id)?.kind else { Issue.record("not text"); return }
        #expect(changed.handDrawn)
    }

    @Test func newObjectsFollowTheSettingWithTheirOwnSeeds() {
        let h = EditorHarness()
        #expect(!h.editor.newStyle(lineWidthPoints: 2, handDrawable: true).handDrawn)
        h.editor.settings.handDrawn = true
        let first = h.editor.newStyle(lineWidthPoints: 2, handDrawable: true)
        let second = h.editor.newStyle(lineWidthPoints: 2, handDrawable: true)
        #expect(first.handDrawn && first.seed != 0)
        #expect(first.seed != second.seed)
        // Redactions and the like never get the flag.
        #expect(!h.editor.newStyle(lineWidthPoints: 2).handDrawn)
    }

    @Test func rerollChangesTheSeedAsOneUndoStep() {
        let object = rectangle(handDrawn: true, seed: 5)
        let h = EditorHarness(objects: [object])
        h.editor.selection = [object.id]
        #expect(h.editor.canRerollHandDrawn)
        h.act { h.editor.rerollHandDrawn() }
        #expect(h.editor.object(object.id)?.style.seed != 5)
        #expect(h.editor.undoManager.undoActionName == "Reroll Hand-drawn")
        h.editor.undoManager.undo()
        #expect(h.editor.object(object.id)?.style.seed == 5)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func rerollDoesNothingWithoutAHandDrawnShapeSelected() {
        let clean = rectangle(handDrawn: false)
        let h = EditorHarness(objects: [clean])
        h.editor.selection = [clean.id]
        #expect(!h.editor.canRerollHandDrawn)
        h.editor.rerollHandDrawn()
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func duplicatingKeepsTheSeed() {
        let object = rectangle(handDrawn: true, seed: 77)
        let h = EditorHarness(objects: [object])
        h.editor.selection = [object.id]
        h.act { h.editor.duplicateSelection() }
        #expect(h.editor.document.objects.count == 2)
        #expect(h.editor.document.objects.allSatisfy { $0.style.seed == 77 && $0.style.handDrawn })
    }

    @Test func toolSettingsWrittenBeforeHandDrawnDecode() throws {
        let settings = try JSONDecoder().decode(AnnotateToolSettings.self, from: Data(#"{"sizeLevel":4}"#.utf8))
        #expect(settings.sizeLevel == 4)
        #expect(!settings.handDrawn)
    }
}
