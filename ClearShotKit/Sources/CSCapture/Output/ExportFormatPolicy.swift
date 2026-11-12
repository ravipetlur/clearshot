import CoreGraphics
import CSCore

public enum ExportFormatPolicy {
    /// The format a capture is saved in. A transparent window shot can't be saved as JPEG without losing its
    /// transparent background, so it's saved as PNG instead.
    public static func format(preferred: ImageFormat, isTransparent: Bool) -> ImageFormat {
        isTransparent && !preferred.supportsTransparency ? .png : preferred
    }

    /// `format(preferred:isTransparent:)` for the File format setting. Automatic reads the picture (`FormatClassifier`):
    /// PNG for a transparent, flat or text-heavy one, JPEG for a photographic one. Without the picture (it couldn't be
    /// read) Automatic is PNG, which never loses anything.
    public static func format(preferred: FileFormatChoice, image: CGImage?, isTransparent: Bool) -> ImageFormat {
        if let fixed = preferred.imageFormat { return format(preferred: fixed, isTransparent: isTransparent) }
        guard !isTransparent, let image else { return .png }
        return FormatClassifier.classify(image) == .photographic ? .jpeg : .png
    }
}
