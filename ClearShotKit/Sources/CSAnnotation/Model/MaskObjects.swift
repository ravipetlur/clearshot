import CoreGraphics
import Foundation

/// The objects the secrets check puts in a capture's document, and takes out again.
extension AnnotationObject {
    /// A Pixelate redaction over `rect`, in base pixels, at `intensity` (clamped to 1 to 10, what a redaction takes).
    /// The style carries no colour that is drawn: a redaction replaces what is under it, and has no shadow.
    ///
    /// It carries the secrets check's marker (`RedactObject.isSecretsMask`), which is how the sensitive-info button finds the
    /// masks again to take them out. Every mask the check makes, whether from the thumbnail's Mask All, Annotate's button or
    /// its Edit-menu command, is made here.
    public static func pixelateMask(rect: CGRect, intensity: Int, id: UUID = UUID()) -> AnnotationObject {
        AnnotationObject(id: id,
                         kind: .redact(RedactObject(rect: rect, style: .pixelate, intensity: min(max(intensity, 1), 10),
                                                    isSecretsMask: true)),
                         style: ObjectStyle(color: RGBAColor(red: 0, green: 0, blue: 0), lineWidth: 1, shadow: false))
    }

    /// A copy of the object for Duplicate, paste and ⌥-drag: a new ID (or `id`), and **not** marked as one of the secrets check's
    /// masks. A copy is something the person placed on purpose, so the sensitive-info button, which takes out the masks the check
    /// made, never takes it out; the original keeps its marker. Everything else is the object's.
    public func copied(id: UUID = UUID()) -> AnnotationObject {
        var copy = self
        copy.id = id
        if case .redact(var redact) = copy.kind {
            redact.isSecretsMask = false
            copy.kind = .redact(redact)
        }
        return copy
    }

    /// Whether the object is a redaction the secrets check made (and not one the person drew, or any other object).
    public var isSecretsMask: Bool {
        if case .redact(let redact) = kind { redact.isSecretsMask } else { false }
    }
}

extension AnnotationDocument {
    /// The document without the objects whose IDs are in `ids`, the others in their order and everything else as it was.
    /// An ID that names no object is ignored. This is how Undo Mask takes out exactly the masks Mask All added: a redaction
    /// the person drew has an ID of its own.
    public func removingObjects(withIDs ids: Set<UUID>) -> AnnotationDocument {
        var copy = self
        copy.objects.removeAll { ids.contains($0.id) }
        return copy
    }

    /// How many of the document's objects are masks the secrets check made.
    public var secretsMaskCount: Int {
        objects.reduce(0) { $0 + ($1.isSecretsMask ? 1 : 0) }
    }

    /// The document without the masks the secrets check made, the other objects in their order and everything else as it was:
    /// what the sensitive-info button's second click does. A redaction the person drew stays, whatever it looks like.
    public func removingSecretsMasks() -> AnnotationDocument {
        var copy = self
        copy.objects.removeAll(where: \.isSecretsMask)
        return copy
    }
}
