import CoreGraphics
import CSCore
import Foundation
import Testing
@testable import CSAnnotation

/// Adding the masks Mask Sensitive Info found to an open document: one undo step for all of them, selected, never growing
/// the canvas, and never under an edit in progress.
@MainActor
struct EditorMasksTests {
    private func masks(_ count: Int = 3) -> [AnnotationObject] {
        (0..<count).map { AnnotationObject.pixelateMask(rect: CGRect(x: 10, y: 10 + 20 * Double($0), width: 40, height: 12), intensity: 5) }
    }

    private let name = "Mask Sensitive Info"

    // MARK: One undo step

    @Test func allTheMasksAreOneUndoStep() {
        let h = EditorHarness()
        let added = masks(3)
        var result = false
        h.act { result = h.editor.addMasks(added, actionName: name) }
        #expect(result)
        #expect(h.editor.document.objects == added)
        #expect(h.editor.undoManager.undoActionName == name)
        // One undo takes out all three, and there is nothing further to undo.
        h.editor.undoManager.undo()
        #expect(h.editor.document.objects.isEmpty)
        #expect(!h.editor.undoManager.canUndo)
        // And one redo puts all three back.
        h.editor.undoManager.redo()
        #expect(h.editor.document.objects == added)
        #expect(!h.editor.undoManager.canRedo)
        #expect(h.editor.undoManager.undoActionName == name)
    }

    @Test func theMasksJoinWhatTheDocumentHasAndUndoLeavesThat() {
        let arrow = editorRectangle()
        let h = EditorHarness(objects: [arrow])
        let added = masks(2)
        h.act { h.editor.addMasks(added, actionName: name) }
        #expect(h.editor.document.objects == [arrow] + added)
        h.editor.undoManager.undo()
        #expect(h.editor.document.objects == [arrow])
    }

    @Test func theMasksAreSelectedAndUndoDropsThemFromTheSelection() {
        let h = EditorHarness()
        let added = masks(3)
        h.act { h.editor.addMasks(added, actionName: name) }
        #expect(h.editor.selection == Set(added.map(\.id)))
        h.editor.undoManager.undo()
        #expect(h.editor.selection.isEmpty)
    }

    @Test func aMaskIsAnEditLikeAnyOtherSoTheDocumentHasChangesToApply() {
        let h = EditorHarness()
        #expect(!h.editor.hasUnappliedChanges)
        h.act { h.editor.addMasks(masks(1), actionName: name) }
        #expect(h.editor.hasUnappliedChanges)
        h.editor.undoManager.undo()
        #expect(!h.editor.hasUnappliedChanges)
    }

    // MARK: The picture the sensitive-info button watches

    @Test func theMasksMakeAnotherPictureAndUndoAndRedoMakeTheOtherTwoAgain() {
        // The button keeps a result for each picture it has read (`PictureIdentity`): the masks' picture shows as masked, and
        // undoing them must give back the very picture that was scanned, so its warning returns with no new scan.
        let h = EditorHarness()
        let scanned = h.editor.document.pictureIdentity
        h.act { h.editor.addMasks(masks(2), actionName: name) }
        let masked = h.editor.document.pictureIdentity
        #expect(masked != scanned)
        h.editor.undoManager.undo()
        #expect(h.editor.document.pictureIdentity == scanned)
        h.editor.undoManager.redo()
        #expect(h.editor.document.pictureIdentity == masked)
    }

    @Test func deletingAMaskMakesAPictureNobodyHasRead() {
        let h = EditorHarness()
        let scanned = h.editor.document.pictureIdentity
        let added = masks(2)
        h.act { h.editor.addMasks(added, actionName: name) }
        let masked = h.editor.document.pictureIdentity
        h.act {
            h.editor.selection = [added[0].id]
            h.editor.deleteSelection()
        }
        let afterDelete = h.editor.document.pictureIdentity
        #expect(afterDelete != masked)
        #expect(afterDelete != scanned)
    }

    @Test func aLabelOverThePictureLeavesItAsItWas() {
        let h = EditorHarness()
        let scanned = h.editor.document.pictureIdentity
        h.act { h.editor.add(editorRectangle(), actionName: "Add") }
        #expect(h.editor.document.pictureIdentity == scanned)
    }

    // MARK: The canvas stays as it is

    @Test func theMasksNeverGrowTheCanvas() {
        // A canvas on part pixels: the render covers whole pixels, so a mask cut to the render can reach a fraction of a pixel
        // past it. An object change would grow the canvas for that by a margin's worth (auto-expand is on by default).
        let canvas = CGRect(x: 10.4, y: 5.6, width: 79.7, height: 59.9)
        let edge = AnnotationObject.pixelateMask(rect: CGRect(x: 10, y: 5, width: 30, height: 12), intensity: 5)

        let plain = EditorHarness(canvasRect: canvas)
        #expect(plain.preferences[Prefs.annotateAutoExpandCanvas], "auto-expand is on")
        plain.act { plain.editor.add(edge, actionName: "Add") }
        #expect(plain.editor.document.canvasRect != canvas, "an ordinary object change grows the canvas to hold it")

        let h = EditorHarness(canvasRect: canvas)
        h.act { h.editor.addMasks([edge], actionName: name) }
        #expect(h.editor.document.canvasRect == canvas)
        #expect(h.editor.document.objects == [edge])
    }

    // MARK: Refusals: nothing changes and nothing is recorded

    @Test func noMasksAreNothingToAdd() {
        let h = EditorHarness()
        // Outside `act`: a registration with no group open would raise.
        #expect(!h.editor.addMasks([], actionName: name))
        #expect(h.editor.document.objects.isEmpty)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func aPendingCropRefusesTheMasks() {
        let h = EditorHarness()
        h.editor.tool = .crop
        #expect(h.editor.crop != nil)
        #expect(!h.editor.addMasks(masks(), actionName: name))
        #expect(h.editor.document.objects.isEmpty)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func aLiveChangeRefusesTheMasks() {
        // A drag or a text being typed holds a change open; masks added under it would be undone with it, or it with them.
        let h = EditorHarness()
        h.editor.beginLiveChange()
        #expect(h.editor.isInLiveChange)
        #expect(!h.editor.addMasks(masks(), actionName: name))
        #expect(h.editor.document.objects.isEmpty)
        #expect(!h.editor.undoManager.canUndo)
        #expect(h.editor.selection.isEmpty)
    }

    // MARK: Taking the marked masks out (the button's second click)

    private let unmask = "Unmask Sensitive Info"

    private func drawnRedaction(_ rect: CGRect = CGRect(x: 60, y: 50, width: 30, height: 10)) -> AnnotationObject {
        AnnotationObject(kind: .redact(RedactObject(rect: rect, style: .secureBlur, intensity: 5)),
                         style: masks(1)[0].style)
    }

    @Test func allTheMarkedMasksComeOutAsOneUndoStep() {
        let h = EditorHarness()
        let added = masks(3)
        h.act { h.editor.addMasks(added, actionName: name) }
        var removed: Int?
        h.act { removed = h.editor.removeSecretsMasks(actionName: unmask) }
        #expect(removed == 3)
        #expect(h.editor.document.objects.isEmpty)
        #expect(h.editor.undoManager.undoActionName == unmask)
        // One undo puts all three back, selected as they were added or not, and one more takes the masks out again.
        h.editor.undoManager.undo()
        #expect(h.editor.document.objects == added)
        #expect(h.editor.undoManager.undoActionName == name)
        h.editor.undoManager.redo()
        #expect(h.editor.document.objects.isEmpty)
    }

    @Test func theOwnersRedactionsAndEverythingElseStay() {
        let label = editorRectangle()
        let drawn = drawnRedaction()
        let h = EditorHarness(objects: [label, drawn])
        let added = masks(2)
        h.act { h.editor.addMasks(added, actionName: name) }
        #expect(h.editor.document.secretsMaskCount == 2)
        h.act { h.editor.removeSecretsMasks(actionName: unmask) }
        #expect(h.editor.document.objects == [label, drawn])
        h.editor.undoManager.undo()
        #expect(h.editor.document.objects == [label, drawn] + added)
    }

    @Test func theRemovedMasksLeaveTheSelection() {
        let h = EditorHarness()
        let added = masks(2)
        h.act { h.editor.addMasks(added, actionName: name) }
        #expect(h.editor.selection == Set(added.map(\.id)))
        h.act { h.editor.removeSecretsMasks(actionName: unmask) }
        #expect(h.editor.selection.isEmpty)
    }

    @Test func aSelectedObjectThatStaysStaysSelected() {
        let label = editorRectangle()
        let h = EditorHarness(objects: [label])
        h.act { h.editor.addMasks(masks(1), actionName: name) }
        h.editor.selection.insert(label.id)
        h.act { h.editor.removeSecretsMasks(actionName: unmask) }
        #expect(h.editor.selection == [label.id])
    }

    @Test func noMarkedMasksAreNothingToRemove() {
        let drawn = drawnRedaction()
        let h = EditorHarness(objects: [drawn])
        // Outside `act`: a registration with no group open would raise. Nothing is recorded, so nothing is undoable.
        #expect(h.editor.removeSecretsMasks(actionName: unmask) == 0)
        #expect(h.editor.document.objects == [drawn])
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func removingTheMasksGivesBackThePictureThatWasScanned() {
        // The button keeps the result for the picture it scanned: with the masks out, the document is that picture again, so the
        // warning comes back with no new scan.
        let h = EditorHarness(objects: [drawnRedaction()])
        let scanned = h.editor.document.pictureIdentity
        h.act { h.editor.addMasks(masks(2), actionName: name) }
        let masked = h.editor.document.pictureIdentity
        h.act { h.editor.removeSecretsMasks(actionName: unmask) }
        #expect(h.editor.document.pictureIdentity == scanned)
        h.editor.undoManager.undo()
        #expect(h.editor.document.pictureIdentity == masked)
    }

    @Test func removingTheMasksNeverGrowsTheCanvas() {
        let canvas = CGRect(x: 10.4, y: 5.6, width: 79.7, height: 59.9)
        let h = EditorHarness(canvasRect: canvas)
        h.act { h.editor.addMasks(masks(1), actionName: name) }
        h.act { h.editor.removeSecretsMasks(actionName: unmask) }
        #expect(h.editor.document.canvasRect == canvas)
    }

    @Test func aPendingCropRefusesTheRemoval() {
        let h = EditorHarness()
        let added = masks(2)
        h.act { h.editor.addMasks(added, actionName: name) }
        h.editor.tool = .crop
        #expect(h.editor.crop != nil)
        #expect(h.editor.removeSecretsMasks(actionName: unmask) == nil)
        #expect(h.editor.document.objects == added)
        #expect(h.editor.undoManager.undoActionName == name)
    }

    @Test func aLiveChangeRefusesTheRemoval() {
        let h = EditorHarness()
        let added = masks(2)
        h.act { h.editor.addMasks(added, actionName: name) }
        h.editor.beginLiveChange()
        #expect(h.editor.removeSecretsMasks(actionName: unmask) == nil)
        #expect(h.editor.document.objects == added)
        h.editor.cancelLiveChange()
        #expect(h.editor.undoManager.undoActionName == name)
    }

    // MARK: A copy of a marked mask is the person's own

    @Test func aDuplicateOfAMaskIsNotMarkedAndTheOriginalIs() {
        let h = EditorHarness()
        let added = masks(1)
        h.act { h.editor.addMasks(added, actionName: name) }
        h.act { h.editor.duplicateSelection() }
        #expect(h.editor.document.objects.count == 2)
        // One marked mask, so the button counts one: the copy was placed on purpose.
        #expect(h.editor.document.secretsMaskCount == 1)
        let original = h.editor.object(added[0].id)
        let copy = h.editor.document.objects.first { $0.id != added[0].id }
        #expect(original?.isSecretsMask == true)
        #expect(copy?.isSecretsMask == false)
        // The copy is the same redaction in every other way (offset a little, its own ID).
        if case .redact(let kept)? = original?.kind, case .redact(let duplicated)? = copy?.kind {
            #expect(duplicated.style == kept.style)
            #expect(duplicated.intensity == kept.intensity)
            #expect(duplicated.rect.size == kept.rect.size)
        } else {
            Issue.record("not redactions")
        }
        // So the button's second click takes out the original and leaves the copy.
        h.act { h.editor.removeSecretsMasks(actionName: unmask) }
        #expect(h.editor.document.objects.count == 1)
        #expect(h.editor.document.objects.first?.id == copy?.id)
    }

    @Test func aPastedMaskIsNotMarked() {
        let h = EditorHarness()
        let added = masks(2)
        h.act { h.editor.paste(added) }
        #expect(h.editor.document.objects.count == 2)
        #expect(h.editor.document.secretsMaskCount == 0)
        #expect(h.editor.document.objects.allSatisfy { !$0.isSecretsMask })
    }

    @Test func aMaskPastedBackFromThePasteboardIsNotMarked() throws {
        // What the pasteboard carries is the objects as JSON, marker included: the file keeps what it was given. A paste is a
        // copy, so what comes out of it is the person's own.
        let added = masks(2)
        let decoded = try JSONDecoder().decode([AnnotationObject].self, from: JSONEncoder().encode(added))
        #expect(decoded.allSatisfy { $0.isSecretsMask })
        let h = EditorHarness()
        h.act { h.editor.paste(decoded) }
        #expect(h.editor.document.secretsMaskCount == 0)
        // Pasted into the editor the masks came from, too: the originals stay marked, the pastes don't.
        let source = EditorHarness()
        source.act { source.editor.addMasks(added, actionName: name) }
        source.act { source.editor.paste(decoded) }
        #expect(source.editor.document.objects.count == 4)
        #expect(source.editor.document.secretsMaskCount == 2)
    }

    @Test func aCopyTheOptionDragMakesIsNotMarked() {
        // The canvas's ⌥-drag makes its copies with `copied()`, as Duplicate and paste do.
        let marked = masks(2)
        let copies = marked.map { $0.copied() }
        #expect(copies.allSatisfy { !$0.isSecretsMask })
        #expect(Set(copies.map(\.id)).isDisjoint(with: Set(marked.map(\.id))))
        #expect(marked.allSatisfy { $0.isSecretsMask })
    }

    @Test func movingAndRestylingTheOriginalKeepsItMarked() {
        let h = EditorHarness()
        let added = masks(1)
        h.act { h.editor.addMasks(added, actionName: name) }
        h.act { h.editor.nudgeSelection(by: CGVector(dx: 10, dy: 0)) }
        h.act { h.editor.setRedactStyle(.secureBlur) }
        #expect(h.editor.document.objects.count == 1)
        #expect(h.editor.document.secretsMaskCount == 1)
    }
}
