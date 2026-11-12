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
    private static let area = CGRect(x: 20, y: 10, width: 60, height: 20)

    private static func document(_ objects: [AnnotationObject] = []) -> AnnotationDocument {
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        document.objects = objects
        return document
    }

    private static func redaction(_ style: RedactStyle = .pixelate, rect: CGRect? = nil, intensity: Int = 5,
                                  id: UUID = UUID()) -> AnnotationObject {
        AnnotationObject(id: id, kind: .redact(RedactObject(rect: rect ?? area, style: style, intensity: intensity)),
                         style: ObjectStyle(color: RGBAColor(red: 0, green: 0, blue: 0), lineWidth: 1, shadow: false))
    }

    private static func label() -> AnnotationObject {
        AnnotationObject(kind: .rectangle(CGRect(x: 5, y: 5, width: 30, height: 20)),
                         style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 4, shadow: false))
    }

    /// `object` with a redaction's rect, style or intensity changed, the ID kept.
    private static func changed(_ object: AnnotationObject, rect: CGRect? = nil, style: RedactStyle? = nil,
                                intensity: Int? = nil) -> AnnotationObject {
        guard case .redact(var redact) = object.kind else { return object }
        redact.rect = rect ?? redact.rect
        redact.style = style ?? redact.style
        redact.intensity = intensity ?? redact.intensity
        var copy = object
        copy.kind = .redact(redact)
        return copy
    }

    /// Each before-and-after pair a scenario stands for.
    typealias Change = (before: AnnotationDocument, after: AnnotationDocument)

    // MARK: Coverage only added

    enum AddsCoverage: String, CaseIterable {
        /// A mask the secrets check added.
        case aMaskAddedByTheSecretsCheck
        /// A new redaction of any style the owner drew: Pixelate, a blur, Black Out, Erase.
        case aNewRedactionOfAnyStyle
        /// A new redaction beside ones that stay.
        case aNewRedactionBesideOnesThatStay
        /// A redaction that grew, on every side or on one.
        case aRedactionThatGrew
        /// A grown redaction and a new one.
        case aGrownRedactionAndANewOne
        /// A label added beside a new redaction.
        case aLabelBesideANewRedaction
        /// The objects reordered, with one more redaction: the order doesn't matter.
        case reorderedWithOneMoreRedaction

        var changes: [Change] {
            switch self {
            case .aMaskAddedByTheSecretsCheck:
                return [(document(), document([AnnotationObject.pixelateMask(rect: area, intensity: 5)]))]
            case .aNewRedactionOfAnyStyle:
                return RedactStyle.allCases.map { (document(), document([redaction($0)])) }
            case .aNewRedactionBesideOnesThatStay:
                let first = redaction()
                return [(document([first]), document([first, redaction(.secureBlur, rect: CGRect(x: 100, y: 40, width: 30, height: 10))]))]
            case .aRedactionThatGrew:
                let original = redaction()
                return [area.insetBy(dx: -20, dy: -5), CGRect(x: 20, y: 10, width: 100, height: 20),
                        CGRect(x: 0, y: 10, width: 80, height: 20), CGRect(x: 20, y: 10, width: 60, height: 40)]
                    .map { (document([original]), document([changed(original, rect: $0)])) }
            case .aGrownRedactionAndANewOne:
                let original = redaction()
                return [(document([original]), document([changed(original, rect: area.insetBy(dx: -10, dy: -10)),
                                                         redaction(rect: CGRect(x: 100, y: 60, width: 20, height: 10))]))]
            case .aLabelBesideANewRedaction:
                let original = redaction()
                return [(document([original]), document([original, redaction(rect: CGRect(x: 100, y: 60, width: 20, height: 10)), label()]))]
            case .reorderedWithOneMoreRedaction:
                let one = redaction()
                let two = redaction(rect: CGRect(x: 100, y: 40, width: 30, height: 10))
                let three = redaction(rect: CGRect(x: 0, y: 80, width: 30, height: 10))
                return [(document([one, two]), document([two, three, one]))]
            }
        }
    }

    @Test(arguments: AddsCoverage.allCases)
    func addsCoverage(_ scenario: AddsCoverage) {
        for (before, after) in scenario.changes {
            #expect(after.onlyAddsCoverage(since: before), "\(after.objects)")
        }
    }

    // MARK: Anything else

    enum AddsNoCoverage: String, CaseIterable {
        /// A redaction moved: hiding other pixels now, the old ones may show.
        case aRedactionMoved
        /// A redaction shrunk.
        case aRedactionShrunk
        /// A redaction grown on one side and shrunk on another.
        case aRedactionGrownOnOneSideAndShrunkOnAnother
        /// A redaction deleted, of two, or both.
        case aRedactionDeleted
        /// The masks the check made are gone and one the person drew is there: the copy of the masked picture must not be
        /// replaced by this unmasked one.
        case unmaskingAndDrawingAnother
        /// The same place, but not the redaction the copy was made with: the check can't tell it is the same.
        case unmaskingAndAddingAMaskBackWithAnotherID
        /// A redaction restyled.
        case aRedactionRestyled
        /// A redaction made weaker or stronger.
        case aRedactionWhoseStrengthChanged
        /// A redaction grown and restyled.
        case aRedactionGrownAndRestyled
        /// A new redaction beside one that shrank.
        case aNewRedactionBesideOneThatShrank
        /// A label, an arrow, a rectangle: they are drawn over the picture and hide nothing of it.
        case labelsAlone
        /// Nothing changed.
        case aDocumentLeftAsItWas
        /// The objects reordered and nothing added.
        case reorderedAlone
        /// Opened with the masks applied (Review on a masked capture), then a label added: nothing new is hidden.
        case aDocumentThatHadTheRedactionsAndGainedNone

        var changes: [Change] {
            let original = redaction()
            switch self {
            case .aRedactionMoved:
                return [area.offsetBy(dx: 40, dy: 0), area.offsetBy(dx: 0, dy: 5), area.offsetBy(dx: -10, dy: 0)]
                    .map { (document([original]), document([changed(original, rect: $0)])) }
            case .aRedactionShrunk:
                return [area.insetBy(dx: 5, dy: 2), CGRect(x: 20, y: 10, width: 30, height: 20), CGRect(x: 20, y: 10, width: 60, height: 10)]
                    .map { (document([original]), document([changed(original, rect: $0)])) }
            case .aRedactionGrownOnOneSideAndShrunkOnAnother:
                return [(document([original]), document([changed(original, rect: CGRect(x: 30, y: 10, width: 80, height: 20))]))]
            case .aRedactionDeleted:
                let two = redaction(rect: CGRect(x: 100, y: 40, width: 30, height: 10))
                return [(document([original, two]), document([original])), (document([original, two]), document())]
            case .unmaskingAndDrawingAnother:
                let masks = [AnnotationObject.pixelateMask(rect: area, intensity: 5),
                             AnnotationObject.pixelateMask(rect: CGRect(x: 100, y: 40, width: 30, height: 10), intensity: 5)]
                return [(document(masks), document([redaction(rect: CGRect(x: 0, y: 80, width: 40, height: 10))]))]
            case .unmaskingAndAddingAMaskBackWithAnotherID:
                return [(document([AnnotationObject.pixelateMask(rect: area, intensity: 5)]),
                         document([AnnotationObject.pixelateMask(rect: area, intensity: 5),
                                   redaction(rect: CGRect(x: 100, y: 60, width: 20, height: 10))]))]
            case .aRedactionRestyled:
                return [RedactStyle.blackOut, .secureBlur].map { (document([original]), document([changed(original, style: $0)])) }
            case .aRedactionWhoseStrengthChanged:
                return [2, 9].map { (document([original]), document([changed(original, intensity: $0)])) }
            case .aRedactionGrownAndRestyled:
                return [(document([original]), document([changed(original, rect: area.insetBy(dx: -10, dy: -5), style: .smoothBlur)]))]
            case .aNewRedactionBesideOneThatShrank:
                return [(document([original]), document([changed(original, rect: area.insetBy(dx: 10, dy: 5)),
                                                         redaction(rect: CGRect(x: 100, y: 60, width: 20, height: 10))]))]
            case .labelsAlone:
                return [(document(), document([label()])), (document([original]), document([original, label()]))]
            case .aDocumentLeftAsItWas:
                let objects = [original, label()]
                return [(document(), document()), (document(objects), document(objects))]
            case .reorderedAlone:
                let two = redaction(rect: CGRect(x: 100, y: 40, width: 30, height: 10))
                return [(document([original, two]), document([two, original]))]
            case .aDocumentThatHadTheRedactionsAndGainedNone:
                let masks = [AnnotationObject.pixelateMask(rect: area, intensity: 5), original]
                return [(document(masks), document(masks + [label()]))]
            }
        }
    }

    @Test(arguments: AddsNoCoverage.allCases)
    func addsNoCoverage(_ scenario: AddsNoCoverage) {
        for (before, after) in scenario.changes {
            #expect(!after.onlyAddsCoverage(since: before), "\(after.objects)")
        }
    }
}
