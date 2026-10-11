import CoreGraphics
import CSAnnotation
import CSSensitive
import Foundation

/// What Edit › Mask Sensitive Info does off the main actor: it renders the open document's picture, scans it for the kinds
/// switched on in Settings, and makes the masks for what it finds, in the document's own pixels.
///
/// **What is scanned** is the document's picture as it is now (`Renderer.renderPicture`): the base with the image operations
/// (turns, flips, resize) and the crop or canvas applied, as Annotate shows it, at the document's pixel size. Annotations and
/// the background around the picture are left out. A mask is a redaction, which lies under every annotation, so a mask over
/// text inside one (a label, a pasted picture) would hide nothing; and text in the background's frame is outside the base,
/// where no mask can go. Redactions are kept, so text already pixelated isn't found and masked again.
///
/// **Coordinates.** The findings are in the render's pixels. The render's own mapping (`PictureRender.mapping`, made from
/// the same reduced document, so the two agree) takes a pixel of the render back to the base, where the document's objects
/// are, undoing the crop, the turns, flips and resize; `MaskPlan` cuts each finding's box to the render, adds the margin, and
/// takes it through that mapping. The document's pixel scale only sizes the Pixelate blocks.
///
/// No finding's text is read out of the scanner, kept or logged: the result is rectangles and counts.
nonisolated enum SensitiveInfoScan {
    nonisolated struct Found: Sendable {
        /// One Pixelate redaction for each finding that has a place on the base's pixels, in reading order.
        var masks: [AnnotationObject]
        /// What was found, by kind: a finding with no place on the base has no mask, so these can outnumber `masks`.
        var findings: FindingCounts
        /// How long rendering and scanning took.
        var duration: Duration
    }

    nonisolated enum Failure: Error {
        /// The document's picture couldn't be rendered (its base image is missing, or its output is empty or too big).
        case noPicture
    }

    /// Throws `CancellationError` when the task is cancelled, and what Vision throws when it can't read the picture. A scan
    /// can still return normally if the cancel came after its last check: the caller checks `Task.isCancelled` too.
    @concurrent
    static func run(_ document: AnnotationDocument, images: ImageStore, kinds: SensitiveKinds) async throws -> Found {
        let clock = ContinuousClock()
        let start = clock.now
        guard let picture = Renderer.renderPicture(of: document, images: images) else { throw Failure.noPicture }
        try Task.checkCancellation()
        let findings = try await SensitiveScanner.scan(picture.image, kinds: kinds)
        let plan = MaskPlan.masks(for: findings, imageSize: picture.mapping.renderedSize, toBase: picture.mapping.toBase,
                                  baseSize: document.baseSize, pixelScale: document.pixelScale)
        return Found(masks: plan.map { AnnotationObject.pixelateMask(rect: $0.rect, intensity: $0.intensity) },
                     findings: FindingCounts(findings), duration: clock.now - start)
    }
}
