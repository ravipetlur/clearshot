import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// The objects Mask All adds to a capture's document and Undo Mask takes out again.
struct MaskObjectTests {
    private struct TestFailure: Error {}

    private let area = CGRect(x: 20, y: 10, width: 60, height: 20)

    // MARK: The mask

    @Test func aMaskIsAPixelateRedaction() throws {
        let mask = AnnotationObject.pixelateMask(rect: area, intensity: 5)
        guard case .redact(let redact) = mask.kind else {
            Issue.record("not a redaction: \(mask.kind)")
            return
        }
        #expect(redact.rect == area)
        #expect(redact.style == .pixelate)
        #expect(redact.intensity == 5)
        #expect(!mask.style.shadow)
        #expect(mask.isFinite)
    }

    @Test func everyMaskHasItsOwnID() {
        let ids = (0..<20).map { _ in AnnotationObject.pixelateMask(rect: area, intensity: 5).id }
        #expect(Set(ids).count == 20)
        let given = UUID()
        #expect(AnnotationObject.pixelateMask(rect: area, intensity: 5, id: given).id == given)
    }

    @Test(arguments: [(-3, 1), (0, 1), (1, 1), (5, 5), (10, 10), (11, 10), (400, 10)])
    func theIntensityStaysWithinWhatARedactionTakes(given: Int, used: Int) {
        guard case .redact(let redact) = AnnotationObject.pixelateMask(rect: area, intensity: given).kind else {
            Issue.record("not a redaction")
            return
        }
        #expect(redact.intensity == used)
    }

    @Test func aMaskSurvivesTheDocumentBeingWrittenAndRead() throws {
        var (document, _) = TestBitmaps.document(base: TestBitmaps.solid(100, 60, TestBitmaps.white))
        let mask = AnnotationObject.pixelateMask(rect: area, intensity: 6)
        document.objects = [mask]
        let again = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document))
        #expect(again.objects == [mask])
        #expect(again.isWellFormed)
    }

    @Test func aMaskReallyReplacesWhatIsUnderIt() throws {
        // Deterministic noise under the mask: inside the rectangle every block is one colour (the noise is gone), and
        // outside it the render is the base.
        let (plain, images) = TestBitmaps.document(base: TestBitmaps.noise(100, 60))
        var masked = plain
        masked.objects = [AnnotationObject.pixelateMask(rect: area, intensity: 5)]
        let before = try #require(Renderer.render(plain, images: images))
        let after = try #require(Renderer.render(masked, images: images))
        #expect(TestBitmaps.pixel(after, 5, 5) == TestBitmaps.pixel(before, 5, 5))
        #expect(TestBitmaps.pixel(after, 90, 50) == TestBitmaps.pixel(before, 90, 50))
        // The block is 15 px at scale 1, counted from the rectangle's own top-left: (20, 10) to (34, 24) is one block.
        let corner = TestBitmaps.pixel(after, 20, 10)
        #expect(TestBitmaps.pixel(after, 33, 23) == corner)
        #expect(TestBitmaps.pixel(after, 25, 15) == corner)
        #expect(TestBitmaps.pixel(after, 20, 10) != TestBitmaps.pixel(before, 20, 10))
    }

    // MARK: The marker

    @Test func everyMaskTheChecksMakesCarriesTheMarker() {
        let mask = AnnotationObject.pixelateMask(rect: area, intensity: 5)
        #expect(mask.isSecretsMask)
        guard case .redact(let redact) = mask.kind else {
            Issue.record("not a redaction")
            return
        }
        #expect(redact.isSecretsMask)
    }

    @Test func aRedactionThePersonDrawsIsNeverMarked() {
        let drawn = AnnotationObject(kind: .redact(RedactObject(rect: area, style: .pixelate, intensity: 5)),
                                     style: AnnotationObject.pixelateMask(rect: area, intensity: 5).style)
        #expect(!drawn.isSecretsMask)
        for style in RedactStyle.allCases {
            #expect(!AnnotationObject(kind: .redact(RedactObject(rect: area, style: style, intensity: 5)), style: drawn.style).isSecretsMask,
                    "\(style)")
        }
    }

    @Test func noOtherKindOfObjectIsAMask() {
        for kind in AnnotationDocumentTests.everyKind {
            if case .redact = kind { continue }
            #expect(!AnnotationObject(kind: kind, style: AnnotationDocumentTests.style).isSecretsMask)
        }
    }

    @Test func theMarkerIsPartOfTheObjectSoRestylingAndMovingKeepIt() {
        var mask = AnnotationObject.pixelateMask(rect: area, intensity: 5)
        mask = ObjectGeometry.translated(mask, by: CGVector(dx: 30, dy: 5))
        #expect(mask.isSecretsMask)
        guard case .redact(var redact) = mask.kind else { return }
        redact.style = .secureBlur
        redact.intensity = 8
        mask.kind = .redact(redact)
        #expect(mask.isSecretsMask)
        #expect(ObjectScaling.scaled(mask, by: 2).isSecretsMask)
    }

    @Test func aCopyOfAMaskHasItsOwnIDAndNoMarker() throws {
        let mask = AnnotationObject.pixelateMask(rect: area, intensity: 7)
        let copy = mask.copied()
        #expect(copy.id != mask.id)
        #expect(!copy.isSecretsMask)
        // Everything else is the mask's: it is a Pixelate redaction over the same place, as strong, drawn the same way.
        var expected = mask
        expected.id = copy.id
        guard case .redact(var redact) = expected.kind else { throw TestFailure() }
        redact.isSecretsMask = false
        expected.kind = .redact(redact)
        #expect(copy == expected)
        // The original is untouched.
        #expect(mask.isSecretsMask)
    }

    @Test func aCopyCanTakeAGivenID() {
        let id = UUID()
        #expect(AnnotationObject.pixelateMask(rect: area, intensity: 5).copied(id: id).id == id)
    }

    @Test func aCopyOfARedactionThePersonDrewIsTheSameRedactionWithANewID() {
        let drawn = AnnotationObject(kind: .redact(RedactObject(rect: area, style: .blackOut, intensity: 3)),
                                     style: AnnotationObject.pixelateMask(rect: area, intensity: 5).style)
        let copy = drawn.copied()
        #expect(copy.id != drawn.id)
        var expected = drawn
        expected.id = copy.id
        #expect(copy == expected)
        #expect(!copy.isSecretsMask)
    }

    @Test func aCopyOfAnyOtherObjectOnlyGetsANewID() {
        for kind in AnnotationDocumentTests.everyKind {
            let object = AnnotationObject(kind: kind, style: AnnotationDocumentTests.style)
            let copy = object.copied()
            var expected = object
            expected.id = copy.id
            #expect(copy == expected)
            #expect(copy.id != object.id)
        }
    }

    @Test func theMarkerIsWrittenOnlyWhenSet() throws {
        let marked = AnnotationObject.pixelateMask(rect: area, intensity: 5)
        let drawn = AnnotationObject(kind: .redact(RedactObject(rect: area, style: .pixelate, intensity: 5)), style: marked.style)
        let markedJSON = try #require(String(data: JSONEncoder().encode(marked), encoding: .utf8))
        let drawnJSON = try #require(String(data: JSONEncoder().encode(drawn), encoding: .utf8))
        #expect(markedJSON.contains("isSecretsMask"))
        // What the person draws is written exactly as it always was, so an older build reads it as before.
        #expect(!drawnJSON.contains("isSecretsMask"))
    }

    @Test func theMarkerSurvivesTheDocumentBeingWrittenAndRead() throws {
        var (document, _) = TestBitmaps.document(base: TestBitmaps.solid(100, 60, TestBitmaps.white))
        let marked = AnnotationObject.pixelateMask(rect: area, intensity: 6)
        let drawn = AnnotationObject(kind: .redact(RedactObject(rect: area.offsetBy(dx: 0, dy: 30), style: .blackOut, intensity: 5)),
                                     style: marked.style)
        document.objects = [marked, drawn]
        let again = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document))
        #expect(again == document)
        #expect(again.objects.map(\.isSecretsMask) == [true, false])
        #expect(again.isWellFormed)
    }

    @Test func aRedactionWrittenBeforeTheMarkerExistedDecodesAsTheOwners() throws {
        // As every earlier build wrote it: no marker key.
        let json = #"{"intensity":5,"rect":[[20,10],[60,20]],"style":"pixelate"}"#
        let redact = try JSONDecoder().decode(RedactObject.self, from: Data(json.utf8))
        #expect(!redact.isSecretsMask)
        #expect(redact == RedactObject(rect: area, style: .pixelate, intensity: 5))
    }

    @Test func theMarkerKeyIsReadWhenPresentAndAnUnknownKeyIsIgnored() throws {
        let marked = #"{"intensity":5,"isSecretsMask":true,"rect":[[20,10],[60,20]],"style":"pixelate"}"#
        #expect(try JSONDecoder().decode(RedactObject.self, from: Data(marked.utf8)).isSecretsMask)
        // The other way round: a build that doesn't know the marker reads a document that has it, as JSONDecoder skips
        // keys it has no use for. Here a key this build doesn't know stands in for it.
        let future = #"{"intensity":5,"someLaterKey":true,"rect":[[20,10],[60,20]],"style":"pixelate"}"#
        #expect(try JSONDecoder().decode(RedactObject.self, from: Data(future.utf8)) == RedactObject(rect: area, style: .pixelate, intensity: 5))
    }

    @Test func aDocumentWithNoMarkedMaskIsWrittenAsItWasBeforeTheMarkerExisted() throws {
        // A redaction the person drew, written inside a whole document, has the three keys every build has written for it.
        let document = AnnotationDocumentTests.fullDocument()
        let written = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        let objects = try #require(written["objects"] as? [[String: Any]])
        let redactions = objects.compactMap { ($0["kind"] as? [String: Any])?["redact"] as? [String: Any] }
        let payload = try #require(redactions.first?["_0"] as? [String: Any])
        #expect(redactions.count == 1)
        #expect(Set(payload.keys) == ["intensity", "rect", "style"])
    }

    // MARK: The marked masks of a document

    @Test func theMarkedMasksAreCountedAndTheOwnersRedactionsAreNot() {
        let first = AnnotationObject.pixelateMask(rect: area, intensity: 5)
        let second = AnnotationObject.pixelateMask(rect: area.offsetBy(dx: 0, dy: 20), intensity: 5)
        let drawn = AnnotationObject(kind: .redact(RedactObject(rect: area, style: .pixelate, intensity: 5)), style: first.style)
        let label = AnnotationObject(kind: .rectangle(area), style: first.style)
        var (document, _) = TestBitmaps.document(base: TestBitmaps.solid(100, 60, TestBitmaps.white))
        #expect(document.secretsMaskCount == 0)
        document.objects = [label, first, drawn, second]
        #expect(document.secretsMaskCount == 2)
        document.objects = [label, drawn]
        #expect(document.secretsMaskCount == 0)
    }

    @Test func removingTheMarkedMasksLeavesEverythingElseInItsOrder() {
        let first = AnnotationObject.pixelateMask(rect: area, intensity: 5)
        let second = AnnotationObject.pixelateMask(rect: area.offsetBy(dx: 0, dy: 20), intensity: 5)
        let drawn = AnnotationObject(kind: .redact(RedactObject(rect: area, style: .pixelate, intensity: 5)), style: first.style)
        let label = AnnotationObject(kind: .rectangle(area), style: first.style)
        var (document, _) = TestBitmaps.document(base: TestBitmaps.solid(100, 60, TestBitmaps.white))
        document.objects = [label, first, drawn, second]
        let removed = document.removingSecretsMasks()
        // The person's own redaction, which matches a mask in everything but the marker, stays.
        #expect(removed.objects == [label, drawn])
        var expected = document
        expected.objects = [label, drawn]
        #expect(removed == expected)
        #expect(removed.secretsMaskCount == 0)
    }

    @Test func removingTheMarkedMasksOfADocumentWithNoneChangesNothing() {
        let drawn = AnnotationObject(kind: .redact(RedactObject(rect: area, style: .pixelate, intensity: 5)),
                                     style: AnnotationObject.pixelateMask(rect: area, intensity: 5).style)
        var (document, _) = TestBitmaps.document(base: TestBitmaps.solid(100, 60, TestBitmaps.white))
        #expect(document.removingSecretsMasks() == document)
        document.objects = [drawn]
        #expect(document.removingSecretsMasks() == document)
    }

    // MARK: Taking masks out

    @Test func removingMasksTakesOutExactlyTheOnesNamed() {
        let kept = AnnotationObject(kind: .rectangle(CGRect(x: 1, y: 1, width: 10, height: 10)),
                                    style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 2, shadow: false))
        let first = AnnotationObject.pixelateMask(rect: area, intensity: 5)
        let second = AnnotationObject.pixelateMask(rect: area.offsetBy(dx: 0, dy: 20), intensity: 5)
        let drawnByHand = AnnotationObject(id: UUID(), kind: .redact(RedactObject(rect: area, style: .pixelate, intensity: 5)),
                                           style: first.style)
        var (document, _) = TestBitmaps.document(base: TestBitmaps.solid(100, 60, TestBitmaps.white))
        document.objects = [kept, first, drawnByHand, second]
        let removed = document.removingObjects(withIDs: [first.id, second.id])
        // The person's own redaction, the same as a mask in everything but its ID and its marker, stays, and so does the order.
        #expect(removed.objects == [kept, drawnByHand])
        // Nothing else of the document changes.
        var expected = document
        expected.objects = [kept, drawnByHand]
        #expect(removed == expected)
    }

    @Test func removingMasksThatAreGoneChangesNothing() {
        let mask = AnnotationObject.pixelateMask(rect: area, intensity: 5)
        var (document, _) = TestBitmaps.document(base: TestBitmaps.solid(100, 60, TestBitmaps.white))
        document.objects = [mask]
        #expect(document.removingObjects(withIDs: [UUID()]) == document)
        #expect(document.removingObjects(withIDs: []) == document)
        document.objects = []
        #expect(document.removingObjects(withIDs: [mask.id]) == document)
    }

    @Test func aDocumentWithItsMasksRemovedRendersAsItDidBefore() throws {
        let (plain, images) = TestBitmaps.document(base: TestBitmaps.noise(100, 60))
        var masked = plain
        let masks = [AnnotationObject.pixelateMask(rect: area, intensity: 5),
                     AnnotationObject.pixelateMask(rect: CGRect(x: 5, y: 40, width: 30, height: 12), intensity: 3)]
        masked.objects = masks
        let restored = masked.removingObjects(withIDs: Set(masks.map(\.id)))
        let original = try #require(Renderer.render(plain, images: images))
        let undone = try #require(Renderer.render(restored, images: images))
        #expect(TestBitmaps.bytes(undone) == TestBitmaps.bytes(original))
    }
}
