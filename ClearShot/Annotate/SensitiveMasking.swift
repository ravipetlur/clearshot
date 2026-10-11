import CoreGraphics
import CSAnnotation
import CSHistory
import CSSensitive
import Foundation

/// Mask All and Undo Mask on a capture's annotation document: what the secrets check does to a history item once the
/// person has chosen.
///
/// Both go through the document the way Annotate's Done does. The item's document is opened (`AnnotationStorage.open`: its
/// own if it has been annotated, else a new one over the capture), changed, and written back with the same save and render
/// (`HistoryItemActions.writeDocument`), so the working copy, the thumbnail and the saved file all show the change, and
/// copies, drags and saves afterwards use it. A mask is an ordinary Pixelate redaction in that document, so Annotate shows
/// it as one: selectable, deletable, undoable.
///
/// Everything here runs off the main actor, the way Done's write does. No finding's text is in play (only rectangles), and
/// nothing is logged.
nonisolated enum SensitiveMasking {
    /// What a write did.
    nonisolated struct Written {
        /// The item to record in the store.
        var item: HistoryItem
        /// Why the saved file wasn't rewritten, for the caller to report: the capture itself is changed all the same.
        var savedFileError: (any Error)?
    }

    /// What Mask All did: the write, the masks it added (their object IDs, which Undo Mask removes again), and the picture
    /// the document has now, with them.
    nonisolated struct Applied {
        var written: Written
        var maskIDs: [UUID]
        var picture: PictureIdentity
    }

    /// What Undo Mask did: the write, how many objects it took out (fewer than it was asked for when some were deleted in
    /// Annotate since), the picture the document had **just before** they came out, and the one it has now. The first is what
    /// tells whether the findings Undo Mask would bring back still lie on it (`PictureIdentity.findingsStand`): the document
    /// is read at the moment of the removal, which can be after a change the coordinator hasn't been told of yet.
    nonisolated struct Removal {
        var written: Written
        var removed: Int
        var before: PictureIdentity
        var picture: PictureIdentity
    }

    nonisolated enum Failure: LocalizedError {
        /// The capture was annotated, but its annotations can't be read (`AnnotationStorage.open`'s `recovered`): adding to
        /// what can be read would replace the annotated picture with one that has lost them.
        case annotationsUnreadable
        /// The picture isn't the one that was scanned, so the rectangles found in it aren't where its text is.
        case pictureChanged
        /// Every possible secret lies outside the capture's own pixels (in the fill of a canvas grown past it, say).
        case nothingToCover

        var errorDescription: String? {
            switch self {
            case .annotationsUnreadable: "The annotations on this screenshot couldn't be read, so masks can't be added to it."
            case .pictureChanged: "The screenshot changed after it was checked."
            case .nothingToCover: "The possible secrets aren't on the screenshot itself, so there is nothing to mask."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .annotationsUnreadable: "Open it in Annotate to see what's wrong."
            case .pictureChanged: "ClearShot will check it again."
            case .nothingToCover: "They are in the canvas around it, past the picture, which a mask can't cover."
            }
        }
    }

    /// Adds one Pixelate mask for each finding to the item's document, and writes it.
    ///
    /// The findings are in the pixels of the picture that was scanned, `scannedSize` across: the capture's working copy when
    /// it has no document, else the document's picture alone (`Renderer.renderPicture`: the base with its turns, crop and
    /// redactions, without the annotations and the background, which a mask can't hide text in). `scannedPicture` says which
    /// picture that was (`PictureIdentity`); if the document's picture is another one now, the rectangles aren't where its text
    /// is, and nothing is written (`Failure.pictureChanged`). What was drawn over the picture or around it since doesn't count.
    ///
    /// The document's objects are in its base's pixels, so each finding is taken there through the picture's mapping
    /// (`Renderer.baseMapping` of `pictureOnly`): the identity for a capture nothing has been done to, and a turned, resized
    /// or cropped one's inverse otherwise. The scale of a 2x capture enters only the mask's strength (`MaskPlan`). The masks are
    /// **added** to the document's objects: whatever the capture already has stays.
    static func apply(_ findings: [ImageFinding], scannedSize: CGSize, scannedPicture: PictureIdentity, to item: HistoryItem,
                      root: URL, quality: Double) throws -> Applied {
        let opened = try AnnotationStorage.open(item, root: root)
        guard !opened.recovered else { throw Failure.annotationsUnreadable }
        var document = opened.document
        guard document.pictureIdentity == scannedPicture,
              let mapping = Renderer.baseMapping(of: document.pictureOnly, images: opened.images),
              mapping.renderedSize == scannedSize else {
            throw Failure.pictureChanged
        }
        let masks = MaskPlan.masks(for: findings, imageSize: scannedSize, toBase: mapping.toBase, baseSize: document.baseSize,
                                   pixelScale: document.pixelScale)
        guard !masks.isEmpty else { throw Failure.nothingToCover }
        let objects = masks.map { AnnotationObject.pixelateMask(rect: $0.rect, intensity: $0.intensity) }
        document.objects.append(contentsOf: objects)
        let written = try HistoryItemActions.writeDocument(document, images: opened.images, to: item, root: root, quality: quality)
        return Applied(written: Written(item: written.item, savedFileError: written.savedFileError), maskIDs: objects.map(\.id),
                       picture: document.pictureIdentity)
    }

    /// Takes the objects `ids` names out of the item's document and writes it: exactly the masks Mask All added, which may
    /// have been moved, restyled or deleted in Annotate since, and nothing else. Nothing is written, and the item comes back
    /// as it was, when none of them is left.
    static func remove(_ ids: Set<UUID>, from item: HistoryItem, root: URL, quality: Double) throws -> Removal {
        let opened = try AnnotationStorage.open(item, root: root)
        guard !opened.recovered else { throw Failure.annotationsUnreadable }
        let remaining = opened.document.removingObjects(withIDs: ids)
        let removed = opened.document.objects.count - remaining.objects.count
        let before = opened.document.pictureIdentity
        guard removed > 0 else {
            return Removal(written: Written(item: item, savedFileError: nil), removed: 0, before: before, picture: before)
        }
        let written = try HistoryItemActions.writeDocument(remaining, images: opened.images, to: item, root: root, quality: quality)
        return Removal(written: Written(item: written.item, savedFileError: written.savedFileError), removed: removed, before: before,
                       picture: remaining.pictureIdentity)
    }
}
