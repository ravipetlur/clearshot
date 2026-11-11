import CoreGraphics
import CSCore
import Foundation

/// The unit Annotate shows sizes in (a ruler, a selection's size): Settings › Annotate › Show sizes in.
public enum SizeUnit: String, CaseIterable, Sendable, Identifiable, PrefValue {
    /// The picture's pixels divided by its pixels per point: a Retina capture's sizes read as they do on screen.
    case points
    /// The picture's own pixels, as an export has them.
    case pixels

    public var id: String { rawValue }

    /// The name a settings picker shows.
    public var title: String {
        switch self {
        case .points: "Points"
        case .pixels: "Pixels"
        }
    }

    /// The short form written after a number: "pt" or "px".
    public var abbreviation: String {
        switch self {
        case .points: "pt"
        case .pixels: "px"
        }
    }
}

extension AnnotationDocument {
    /// A length measured on the picture as shown, in output pixels (what `PicturePixels`' sampler and an export count), in
    /// `unit`. Points divide by the picture's pixels per point as ClearShot records it (`renderedScale`, which a resize
    /// changes), so a Retina capture resized to half reads the same in both.
    public func displayedLength(outputPixels: Double, in unit: SizeUnit) -> Double {
        switch unit {
        case .pixels: outputPixels
        case .points: outputPixels / max(renderedScale, 0.0001)
        }
    }

    /// The size of `rect` (base pixels, where objects live) as shown, in `unit`: through the image operations, so after a
    /// turn its width is what runs across the screen, and after a resize it is the exported picture's pixels.
    public func displayedSize(ofBaseRect rect: CGRect, in unit: SizeUnit) -> CGSize {
        let shown = rect.applying(transform.transform)
        return CGSize(width: displayedLength(outputPixels: shown.width, in: unit),
                      height: displayedLength(outputPixels: shown.height, in: unit))
    }
}
