import CoreGraphics
import CSCapture
import Foundation

/// An image-backed fill's picture as the document stores it: blurred pictures small, sharp ones just big enough to
/// cover the frame, the captured window wallpaper as it is. Pure.
public enum BackgroundImagePrep {
    /// The longest side a sharp picture is stored at, in pixels.
    public static let sharpMaximumSide: Double = 4096
    /// How much larger than the frame, on both axes, a sharp picture is kept.
    public static let coverFactor: Double = 1.5

    /// The size a `source`-sized picture is stored at for a background whose frame is `frame` (output pixels). Blurred: at
    /// most `BackgroundBlur.maximumSide` on its longest side. Sharp: scaled to cover the frame × `coverFactor` on both axes,
    /// then to at most `sharpMaximumSide` on its longest side. Never scaled up; whole pixels, at least 1 per side.
    public static func storedSize(source: CGSize, frame: CGSize, blurred: Bool) -> CGSize {
        let longest = max(source.width, source.height)
        var factor: Double
        if blurred {
            factor = Double(BackgroundBlur.maximumSide) / longest
        } else {
            let cover = max(frame.width * coverFactor / source.width, frame.height * coverFactor / source.height)
            // A frame that isn't a number leaves the picture its own size, up to the cap.
            factor = min(cover.isNaN ? 1 : cover, sharpMaximumSide / longest)
        }
        factor = factor.isFinite ? min(max(factor, 0), 1) : 1
        return CGSize(width: max(1, (source.width * factor).rounded()), height: max(1, (source.height * factor).rounded()))
    }

    /// `picture` ready to store for `fill`, whose frame is `frame` (output pixels, the untrimmed layout): the blurred
    /// desktop blurred (`BackgroundBlur.blurred`); the captured window wallpaper unchanged; any other image-backed fill
    /// resized to `storedSize` (the picture itself when it already is that size). Nil for a fill without a picture, or when
    /// a bitmap can't be made.
    public static func prepare(_ picture: CGImage, for fill: BackgroundFill, frame: CGSize) -> CGImage? {
        switch fill {
        case .blurredDesktop:
            return BackgroundBlur.blurred(picture)
        case .windowWallpaper:
            return picture
        case .desktop, .systemWallpaper, .custom:
            let size = storedSize(source: CGSize(width: picture.width, height: picture.height), frame: frame, blurred: false)
            let width = Int(size.width), height = Int(size.height)
            guard width != picture.width || height != picture.height else { return picture }
            return ImageOps.resized(picture, width: width, height: height)
        case .none, .color, .gradient, .blurredScreenshot:
            return nil
        }
    }

    /// A fresh name for a background picture in the document's `ImageStore`: `images/background-<uuid>.jpg` for an opaque
    /// picture (`DocumentPackage` writes it as JPEG), `.png` for one with see-through pixels.
    public static func reference(for picture: CGImage) -> ImageRef {
        let fileExtension = ImageOps.hasTransparentPixels(picture) ? "png" : "jpg"
        return ImageRef(name: "images/background-\(UUID().uuidString).\(fileExtension)")
    }
}
