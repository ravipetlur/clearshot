import CoreGraphics
import Foundation

extension AnnotationDocument {
    /// Whether this document only **adds coverage** to `earlier`: it hides at least everything `earlier` hid, and something more.
    /// - Every redaction `earlier` has is still here with the same ID, the same style and strength, and a rect that contains
    ///   its earlier one (a redaction that stayed, or grew).
    /// - At least one redaction is new, or grew.
    ///
    /// A redaction that moved, shrank, changed style or strength, or was deleted (the masks taken out with Unmask, say) fails the
    /// first condition: the picture could show what `earlier` hid. Annotations drawn over the picture (labels, arrows) hide
    /// nothing and are ignored, and so is the order of the objects.
    ///
    /// Done asks it of the document it writes and the one it last wrote (the one the editor opened with, the first time): the
    /// copy of the capture ClearShot put on the clipboard shows what the redactions of the document it was made from hide, so
    /// it is replaced by this document's render only when that hides at least as much. Otherwise a masked copy could be
    /// overwritten with a picture that shows what it hid.
    public func onlyAddsCoverage(since earlier: AnnotationDocument) -> Bool {
        let before = earlier.redactions
        let after = redactions
        var addsSomething = false
        for old in before {
            // The first match wins: a corrupt document with two objects of one ID is read as having the first.
            guard let now = after.first(where: { $0.id == old.id }) else { return false }
            guard now.style == old.style, now.intensity == old.intensity, now.rect.standardized.contains(old.rect.standardized) else { return false }
            if now.rect.standardized != old.rect.standardized { addsSomething = true }
        }
        if after.contains(where: { new in !before.contains { $0.id == new.id } }) { addsSomething = true }
        return addsSomething
    }

    /// The document's redactions, in the document's order.
    private var redactions: [(id: UUID, rect: CGRect, style: RedactStyle, intensity: Int)] {
        objects.compactMap { object in
            guard case .redact(let redact) = object.kind else { return nil }
            return (object.id, redact.rect, redact.style, redact.intensity)
        }
    }
}
