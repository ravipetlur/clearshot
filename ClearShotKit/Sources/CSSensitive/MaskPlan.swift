import CoreGraphics

/// Which masks Mask All and Annotate's Mask Sensitive Info add for a scan's findings.
///
/// Pure, and in the document's terms: a finding is in the pixels of the picture that was scanned, an annotation object is in
/// the document's **base pixels** (not points: on a 2x capture they are twice the points), and the two are the same pixels
/// only for a capture nothing has changed. For one that has been turned, resized or cropped, the scanned picture is a render
/// of the document (its picture alone, without annotations: `Renderer.renderPicture`), and `toBase` is what takes a pixel of
/// the render back to the base (`Renderer.baseMapping`, in `CSAnnotation`, which this module doesn't depend on).
///
/// What a mask is, here, is only a rectangle and a strength: the app builds the Pixelate redaction from it.
public enum MaskPlan {
    /// One mask to add: a Pixelate redaction over `rect` (base pixels, top-left origin) at `intensity` (1 to 10).
    public struct Mask: Equatable, Sendable {
        public let rect: CGRect
        public let intensity: Int

        public init(rect: CGRect, intensity: Int) {
            self.rect = rect
            self.intensity = intensity
        }
    }

    /// A mask for each finding, in the findings' order.
    /// - `imageSize` is the scanned picture's size in pixels, which the findings are in and a mask is cut to
    ///   (`MaskGeometry.maskRect`).
    /// - `toBase` takes a point of that picture to the base; `.identity` when they are the same pixels.
    /// - `baseSize` is the base's size in pixels. A mask is cut to it, because a redaction covers base pixels only: a
    ///   finding that lies wholly outside the base (text in a background's frame, say) gets no mask.
    /// - `pixelScale` is the document's pixels per point, which Pixelate sizes its blocks by.
    ///
    /// **Which way the text reads.** A finding on one line is a strip along its text, so its shape says which way it runs: more
    /// than twice as tall as wide, it runs down the picture, whatever the mapping (a capture turned from the thumbnail's menu is turned itself,
    /// and so is its text, with `toBase` the identity; one turned and turned back in Annotate has a quarter-turn mapping and text
    /// that reads across again). It has to be clearly longer than wide: a short narrow value (`ijl`) on an upright picture is
    /// not text running down it. A block of lines (a private key; `ImageFinding.spansLines`) is tall by nature, so its shape says
    /// nothing, and the mapping does: a capture's text reads across the base, so after a quarter turn (`|b| > |a|`) the block's
    /// lines run down the scanned picture. Text running down puts the margins on the picture's axes the other way round
    /// (`MaskGeometry.maskRect`, `textRunsVertically`): the wide margin, which covers where Vision's range boxes end short, is
    /// then along the text, as it is in an upright picture, and the mask in the base has it to the left and right of the text
    /// when the base's text reads across.
    ///
    /// The intensity is chosen for the **text's height in the base**: the mask's thickness once it is placed there (a block's
    /// height), which is its own height when nothing has changed, and what a resize makes of it. A turn doesn't make the text
    /// longer, and text running down the base is as thick as it is wide.
    public static func masks(for findings: [ImageFinding], imageSize: CGSize, toBase: CGAffineTransform, baseSize: CGSize,
                             pixelScale: Double) -> [Mask] {
        let base = CGRect(origin: .zero, size: baseSize)
        let turnedAQuarter = abs(toBase.b) > abs(toBase.a)
        return findings.compactMap { finding in
            let box = finding.rect.standardized
            let textRunsVertically = finding.spansLines ? turnedAQuarter : box.height > 2 * box.width
            let mask = MaskGeometry.maskRect(for: finding.rect, imageSize: imageSize, textRunsVertically: textRunsVertically,
                                             isBlock: finding.spansLines)
            guard !mask.isEmpty else { return nil }
            let placed = mask.applying(toBase).standardized
            guard [placed.minX, placed.minY, placed.width, placed.height].allSatisfy(\.isFinite) else { return nil }
            let rect = placed.intersection(base)
            guard !rect.isNull, !rect.isEmpty else { return nil }
            // The text's height in the base: a strip's thickness (its shorter side, whichever way it runs), a block's height.
            let textHeight = finding.spansLines ? placed.height : min(placed.width, placed.height)
            let strength = MaskGeometry.pixelateIntensity(forHeight: Double(textHeight), pixelScale: pixelScale)
            return Mask(rect: rect, intensity: min(max(Int(strength), 1), 10))
        }
    }
}
