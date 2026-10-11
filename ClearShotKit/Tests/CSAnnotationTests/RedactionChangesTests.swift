import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// Whether an applied document only adds coverage to the one it replaces: the question Done asks to decide whether ClearShot's
/// own copy of the capture on the clipboard is to be replaced. The copy shows what the redactions of the document it was made
/// from hide, so it is replaced only by a picture that hides **at least as much**: every redaction it had is still there, the
/// same kind and strength, over at least the same place, and something is new or bigger. A mask that moved, shrank, changed or
/// was deleted could show what the copy hid, and an unmasked picture would then overwrite a masked copy.
struct RedactionChangesTests {
    private let area = CGRect(x: 20, y: 10, width: 60, height: 20)

    private func document(_ objects: [AnnotationObject] = []) -> AnnotationDocument {
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        document.objects = objects
        return document
    }

    private func redaction(_ style: RedactStyle = .pixelate, rect: CGRect? = nil, intensity: Int = 5, id: UUID = UUID()) -> AnnotationObject {
        AnnotationObject(id: id, kind: .redact(RedactObject(rect: rect ?? area, style: style, intensity: intensity)),
                         style: ObjectStyle(color: RGBAColor(red: 0, green: 0, blue: 0), lineWidth: 1, shadow: false))
    }

    private func label() -> AnnotationObject {
        AnnotationObject(kind: .rectangle(CGRect(x: 5, y: 5, width: 30, height: 20)),
                         style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 4, shadow: false))
    }

    /// `object` with a redaction's rect, style or intensity changed, the ID kept.
    private func changed(_ object: AnnotationObject, rect: CGRect? = nil, style: RedactStyle? = nil, intensity: Int? = nil) -> AnnotationObject {
        guard case .redact(var redact) = object.kind else { return object }
        redact.rect = rect ?? redact.rect
        redact.style = style ?? redact.style
        redact.intensity = intensity ?? redact.intensity
        var copy = object
        copy.kind = .redact(redact)
        return copy
    }

    // MARK: Coverage only added

    @Test func aNewRedactionAddsCoverage() {
        #expect(document([redaction()]).onlyAddsCoverage(since: document()))
    }

    @Test func aMaskAddedByTheSecretsCheckAddsCoverage() {
        let after = document([AnnotationObject.pixelateMask(rect: area, intensity: 5)])
        #expect(after.onlyAddsCoverage(since: document()))
    }

    @Test func aPixelateOrABlurTheOwnerDrewAddsCoverage() {
        for style in RedactStyle.allCases {
            #expect(document([redaction(style)]).onlyAddsCoverage(since: document()), "\(style)")
        }
    }

    @Test func aNewRedactionBesideOnesThatStayAddsCoverage() {
        let first = redaction()
        let after = document([first, redaction(.secureBlur, rect: CGRect(x: 100, y: 40, width: 30, height: 10))])
        #expect(after.onlyAddsCoverage(since: document([first])))
    }

    @Test func aRedactionThatGrewAddsCoverage() {
        let original = redaction()
        for bigger in [area.insetBy(dx: -20, dy: -5), CGRect(x: 20, y: 10, width: 100, height: 20),
                       CGRect(x: 0, y: 10, width: 80, height: 20), CGRect(x: 20, y: 10, width: 60, height: 40)] {
            #expect(document([changed(original, rect: bigger)]).onlyAddsCoverage(since: document([original])), "\(bigger)")
        }
    }

    @Test func aGrownRedactionAndANewOneAddCoverage() {
        let original = redaction()
        let after = document([changed(original, rect: area.insetBy(dx: -10, dy: -10)), redaction(rect: CGRect(x: 100, y: 60, width: 20, height: 10))])
        #expect(after.onlyAddsCoverage(since: document([original])))
    }

    @Test func aLabelAddedBesideANewRedactionStillAddsCoverage() {
        let original = redaction()
        #expect(document([original, redaction(rect: CGRect(x: 100, y: 60, width: 20, height: 10)), label()])
            .onlyAddsCoverage(since: document([original])))
    }

    // MARK: Anything else

    @Test func aRedactionMovedAddsNoCoverage() {
        // Hiding other pixels now: the old ones may show.
        let original = redaction()
        for moved in [area.offsetBy(dx: 40, dy: 0), area.offsetBy(dx: 0, dy: 5), area.offsetBy(dx: -10, dy: 0)] {
            #expect(!document([changed(original, rect: moved)]).onlyAddsCoverage(since: document([original])), "\(moved)")
        }
    }

    @Test func aRedactionShrunkAddsNoCoverage() {
        let original = redaction()
        for smaller in [area.insetBy(dx: 5, dy: 2), CGRect(x: 20, y: 10, width: 30, height: 20), CGRect(x: 20, y: 10, width: 60, height: 10)] {
            #expect(!document([changed(original, rect: smaller)]).onlyAddsCoverage(since: document([original])), "\(smaller)")
        }
    }

    @Test func aRedactionGrownOnOneSideAndShrunkOnAnotherAddsNoCoverage() {
        let original = redaction()
        let slid = CGRect(x: 30, y: 10, width: 80, height: 20)
        #expect(!document([changed(original, rect: slid)]).onlyAddsCoverage(since: document([original])))
    }

    @Test func aRedactionDeletedAddsNoCoverage() {
        let one = redaction()
        let two = redaction(rect: CGRect(x: 100, y: 40, width: 30, height: 10))
        #expect(!document([one]).onlyAddsCoverage(since: document([one, two])))
        #expect(!document().onlyAddsCoverage(since: document([one, two])))
    }

    @Test func unmaskingAndDrawingAnotherAddsNoCoverage() {
        // The masks the check made are gone and one the person drew is there: the copy of the masked picture must not be
        // replaced by this unmasked one.
        let masks = [AnnotationObject.pixelateMask(rect: area, intensity: 5),
                     AnnotationObject.pixelateMask(rect: CGRect(x: 100, y: 40, width: 30, height: 10), intensity: 5)]
        let after = document([redaction(rect: CGRect(x: 0, y: 80, width: 40, height: 10))])
        #expect(!after.onlyAddsCoverage(since: document(masks)))
    }

    @Test func unmaskingAndAddingAMaskBackWithAnotherIDAddsNoCoverage() {
        // The same place, but not the redaction the copy was made with: the check can't tell it is the same.
        let before = document([AnnotationObject.pixelateMask(rect: area, intensity: 5)])
        let after = document([AnnotationObject.pixelateMask(rect: area, intensity: 5), redaction(rect: CGRect(x: 100, y: 60, width: 20, height: 10))])
        #expect(!after.onlyAddsCoverage(since: before))
    }

    @Test func aRedactionRestyledAddsNoCoverage() {
        let original = redaction()
        #expect(!document([changed(original, style: .blackOut)]).onlyAddsCoverage(since: document([original])))
        #expect(!document([changed(original, style: .secureBlur)]).onlyAddsCoverage(since: document([original])))
    }

    @Test func aRedactionWhoseStrengthChangedAddsNoCoverage() {
        let original = redaction()
        #expect(!document([changed(original, intensity: 2)]).onlyAddsCoverage(since: document([original])))
        #expect(!document([changed(original, intensity: 9)]).onlyAddsCoverage(since: document([original])))
    }

    @Test func aRedactionGrownAndRestyledAddsNoCoverage() {
        let original = redaction()
        let after = document([changed(original, rect: area.insetBy(dx: -10, dy: -5), style: .smoothBlur)])
        #expect(!after.onlyAddsCoverage(since: document([original])))
    }

    @Test func aNewRedactionBesideOneThatShrankAddsNoCoverage() {
        let original = redaction()
        let after = document([changed(original, rect: area.insetBy(dx: 10, dy: 5)), redaction(rect: CGRect(x: 100, y: 60, width: 20, height: 10))])
        #expect(!after.onlyAddsCoverage(since: document([original])))
    }

    @Test func labelsAloneAddNoCoverage() {
        // A label, an arrow, a rectangle: they are drawn over the picture and hide nothing of it.
        #expect(!document([label()]).onlyAddsCoverage(since: document()))
        let original = redaction()
        #expect(!document([original, label()]).onlyAddsCoverage(since: document([original])))
    }

    @Test func aDocumentLeftAsItWasAddsNoCoverage() {
        #expect(!document().onlyAddsCoverage(since: document()))
        let objects = [redaction(), label()]
        #expect(!document(objects).onlyAddsCoverage(since: document(objects)))
    }

    @Test func theOrderOfTheObjectsDoesNotMatter() {
        let one = redaction()
        let two = redaction(rect: CGRect(x: 100, y: 40, width: 30, height: 10))
        let three = redaction(rect: CGRect(x: 0, y: 80, width: 30, height: 10))
        // Reordered with one more: still only coverage added. Reordered alone: nothing added.
        #expect(document([two, three, one]).onlyAddsCoverage(since: document([one, two])))
        #expect(!document([two, one]).onlyAddsCoverage(since: document([one, two])))
    }

    @Test func aDocumentThatHadTheRedactionsAndGainedNoneAddsNoCoverage() {
        // Opened with the masks applied (Review on a masked capture), then a label added: nothing new is hidden.
        let masks = [AnnotationObject.pixelateMask(rect: area, intensity: 5), redaction()]
        #expect(!document(masks + [label()]).onlyAddsCoverage(since: document(masks)))
    }
}
