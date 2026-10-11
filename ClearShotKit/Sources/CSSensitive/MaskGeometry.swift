import CoreGraphics

/// How a mask is sized from a finding.
///
/// Pure. The numbers belong to the Pixelate redaction in `CSAnnotation` (`Redaction`: a block is
/// `max(3, round(intensity × 3 × scale))` pixels, from an intensity of 1 to 10), which this module doesn't depend on, so
/// the rule is written out here.
public enum MaskGeometry {
    /// The most a margin is, in pixels: the side margin of any finding, and the margin above and below a block of lines.
    public static let largestMargin: CGFloat = 16

    /// How far a mask reaches above and below its finding's box, in pixels, for a box `height` pixels tall: a tenth of the
    /// height rounded up, at least 2. A line of text needs little, so that the mask doesn't reach into the lines around it; big
    /// type has more edge for Vision's box to be out at, so the margin grows with it. For a block of lines (`isBlock`, a private
    /// key) it stops at `largestMargin`: a block is tall because it has many lines, not big type, and a tenth of a screenful
    /// would cover what lies above and below it.
    public static func verticalMargin(forHeight height: CGFloat, ofBlock isBlock: Bool = false) -> CGFloat {
        let margin = max(2, (height / 10).rounded(.up))
        return isBlock ? min(largestMargin, margin) : margin
    }

    /// How far a mask reaches to either side of a finding's box, in pixels, for a box `height` pixels tall: a fifth of the
    /// height rounded up, from 2 to 16. Vision places the ends of a range by estimate, up to about half a character from the
    /// glyphs, and a character is about half the text's height: so the further the ends can be out, the more room they get.
    public static func horizontalMargin(forHeight height: CGFloat) -> CGFloat {
        min(largestMargin, max(2, (height / 5).rounded(.up)))
    }

    /// The smallest block Pixelate is asked for, in pixels, however short the text.
    public static let minimumBlock: Double = 12

    /// The strongest intensity a redaction takes.
    private static let strongestIntensity = 10

    /// The rectangle a mask covers for the finding at `finding` in an image `imageSize` pixels across (a top-left origin,
    /// as the finding's): the box plus `verticalMargin(forHeight:)` above and below and `horizontalMargin(forHeight:)` to each side,
    /// cut to the image. Fractions are kept. Empty (`.zero`) when the box lies outside the image, isn't a real rectangle, or
    /// the image has no area.
    ///
    /// The margins are for text that reads across the image: the wide one lies along the text, where Vision's range boxes end
    /// short, and the narrow one above and below, so that a mask doesn't reach far into the lines around it. `textRunsVertically`
    /// is for text that reads down the image, as a capture's text does once the picture is turned a quarter: the same rectangle
    /// as in the image turned upright, with both margins from the text's thickness (the box's width): the wide one above and
    /// below, the narrow one to each side. `isBlock` is for a finding over several lines, whose margin above and below stops at
    /// `largestMargin` (`verticalMargin(forHeight:ofBlock:)`).
    public static func maskRect(for finding: CGRect, imageSize: CGSize, textRunsVertically: Bool = false,
                                isBlock: Bool = false) -> CGRect {
        if textRunsVertically {
            return transposed(maskRect(for: transposed(finding), imageSize: CGSize(width: imageSize.height, height: imageSize.width),
                                       isBlock: isBlock))
        }
        let bounds = CGRect(origin: .zero, size: imageSize)
        let components = [finding.origin.x, finding.origin.y, finding.size.width, finding.size.height,
                          imageSize.width, imageSize.height]
        guard !finding.isNull, !finding.isInfinite, components.allSatisfy(\.isFinite), bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let box = finding.standardized
        let mask = box.insetBy(dx: -horizontalMargin(forHeight: box.height),
                               dy: -verticalMargin(forHeight: box.height, ofBlock: isBlock)).intersection(bounds)
        return mask.isNull || mask.isEmpty ? .zero : mask
    }

    /// `rect` with its x and y swapped: the same rectangle in an image whose axes are swapped.
    private static func transposed(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.y, y: rect.origin.x, width: rect.size.height, height: rect.size.width)
    }

    /// The Pixelate intensity for text `height` pixels tall at `pixelScale` (the redaction's pixels per point): the
    /// smallest whole intensity whose block is at least `max(height, minimumBlock)` pixels, so no glyph survives whole in
    /// a block. A whole number from 1 to 10, as a `Double`: the strongest (10) when even that block is shorter than the text
    /// (taller than 30 px at scale 1), which is the strongest a redaction does. A scale that isn't a positive number counts
    /// as 1 and a height that isn't a number as 0, as `Redaction` takes them.
    public static func pixelateIntensity(forHeight height: Double, pixelScale: Double) -> Double {
        let wanted = max(height.isNaN ? 0 : height, minimumBlock)
        let scale = pixelScale.isFinite && pixelScale > 0 ? min(pixelScale, 64) : 1
        for intensity in 1..<strongestIntensity {
            if Double(block(intensity: intensity, scale: scale)) >= wanted { return Double(intensity) }
        }
        return Double(strongestIntensity)
    }

    /// Pixelate's block for `intensity` at `scale`, as `Redaction` works it out.
    private static func block(intensity: Int, scale: Double) -> Int {
        max(3, Int((Double(intensity) * 3 * scale).rounded()))
    }
}
