import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// Guides across the picture, imprinted as lines, and the editor's contrast readout.
@MainActor
struct EditorGuidesTests {
    @Test func aVerticalGuideRunsTheFullHeightThroughThePixelUnderThePointer() throws {
        let h = EditorHarness()
        let guide = try #require(h.editor.guide(.vertical, through: CGPoint(x: 30.7, y: 20)))
        #expect(guide.start == CGPoint(x: 30.5, y: 0) && guide.end == CGPoint(x: 30.5, y: 80))
        #expect(guide.position == 30)
    }

    @Test func aHorizontalGuideRunsTheFullWidth() throws {
        let h = EditorHarness()
        let guide = try #require(h.editor.guide(.horizontal, through: CGPoint(x: 30, y: 20.2)))
        #expect(guide.start == CGPoint(x: 0, y: 20.5) && guide.end == CGPoint(x: 100, y: 20.5))
        #expect(guide.position == 20)
    }

    @Test func noGuideOffThePicture() {
        let h = EditorHarness()
        #expect(h.editor.guide(.vertical, through: CGPoint(x: -1, y: 20)) == nil)
        #expect(h.editor.guide(.horizontal, through: CGPoint(x: 20, y: 80)) == nil)
    }

    @Test func labelsFollowTheUnit() throws {
        var document = EditorHarness().editor.document
        document.pixelScale = 1
        let guide = try #require(document.guide(.vertical, through: CGPoint(x: 41, y: 5)))
        #expect(document.guideLabel(guide, in: .pixels) == "x 41 px")
        #expect(document.guideLabel(guide, in: .points).hasPrefix("x "))
        let row = try #require(document.guide(.horizontal, through: CGPoint(x: 5, y: 7)))
        #expect(document.guideLabel(row, in: .pixels) == "y 7 px")
    }

    @Test func imprintingAddsOneLineAcrossThePictureAndOneUndoRemovesIt() throws {
        let h = EditorHarness()
        let guide = try #require(h.editor.guide(.vertical, through: CGPoint(x: 30, y: 20)))
        h.act { h.editor.imprint(guide) }
        let object = try #require(h.editor.document.objects.last)
        guard case .line(let start, let end) = object.kind else { Issue.record("not a line"); return }
        #expect(start == CGPoint(x: 30.5, y: 0) && end == CGPoint(x: 30.5, y: 80))
        #expect(object.style.color == h.editor.settings.color)
        #expect(h.editor.document.objects.count == 1)
        h.editor.undoManager.undo()
        #expect(h.editor.document.objects.isEmpty)
    }

    @Test func aGuideAfterARotationIsInBaseCoordinates() throws {
        let h = EditorHarness()
        h.act { h.editor.changeCanvas("Rotate") { $0 = $0.applying(.rotateRight) } }
        // The rotated picture is 80 × 100; a vertical guide there runs along the base's rows.
        let guide = try #require(h.editor.guide(.vertical, through: CGPoint(x: 10, y: 50)))
        h.act { h.editor.imprint(guide) }
        guard case .line(let start, let end) = try #require(h.editor.document.objects.last).kind else { Issue.record("not a line"); return }
        #expect(abs(start.x - end.x) < 0.001 || abs(start.y - end.y) < 0.001)
        #expect(hypot(start.x - end.x, start.y - end.y) == 100)
    }

    @Test func aUniformSelectionHasNoContrast() async throws {
        let h = EditorHarness()
        h.editor.selectPixels(CGRect(x: 10, y: 10, width: 40, height: 30))
        h.editor.updateSelectionContrast()
        for _ in 0..<100 where h.editor.picturePixels == nil { try await Task.sleep(for: .milliseconds(10)) }
        h.editor.updateSelectionContrast()
        // The measurement is under way; it is done when its task is gone.
        try #require(h.editor.contrastTask != nil)
        for _ in 0..<200 where h.editor.contrastTask != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.editor.contrastTask == nil)
        #expect(h.editor.selectionContrast == nil)
        h.editor.clearPixelSelection()
        h.editor.updateSelectionContrast()
        #expect(h.editor.selectionContrast == nil)
    }
}
