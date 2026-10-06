import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a GIF file holds, as ImageIO reads it: what an opened GIF's item records, since `VideoThumbnail` never opens a
/// GIF.
public struct GIFFileInfo: Sendable, Equatable {
    public let pixelWidth: Int, pixelHeight: Int, frameCount: Int
    /// Seconds: each frame's delay (`frameDelay`), added up.
    public let duration: Double

    /// Whether the file is a GIF by its contents, whatever its name says: ImageIO's reading of its type. A PNG or WebP
    /// downloaded under a `.gif` name isn't one, and a GIF named `.png` is.
    public static func isGIF(_ url: URL) -> Bool {
        CGImageSourceCreateWithURL(url as CFURL, nil).map(isGIF) ?? false
    }

    /// Nil when the file isn't a GIF (by its contents, not its name), can't be read, or has no frames.
    public static func read(_ url: URL) -> GIFFileInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), isGIF(source) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { return nil }
        let file = (CGImageSourceCopyProperties(source, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary]
            as? [CFString: Any]
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        // The canvas (the logical screen every frame is drawn on), else the first frame's size, which ImageIO reports
        // as the canvas's.
        guard let width = int(file?[kCGImagePropertyGIFCanvasPixelWidth]) ?? int(first?[kCGImagePropertyPixelWidth]),
              let height = int(file?[kCGImagePropertyGIFCanvasPixelHeight]) ?? int(first?[kCGImagePropertyPixelHeight]),
              width > 0, height > 0 else { return nil }
        let duration = (0..<frameCount).reduce(0.0) { total, index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return total + frameDelay(unclamped: double(gif?[kCGImagePropertyGIFUnclampedDelayTime]),
                                      clamped: double(gif?[kCGImagePropertyGIFDelayTime]))
        }
        return GIFFileInfo(pixelWidth: width, pixelHeight: height, frameCount: frameCount, duration: duration)
    }

    /// The delay browsers and macOS play for a frame that stores none, 0 or 1 cs: 10 cs.
    static let defaultFrameDelay = 0.1

    /// A frame's seconds: its unclamped delay, else its (clamped) delay, but `defaultFrameDelay` for one under 0.011 s
    /// or none at all, as browsers play them. Many older GIFs store 0.
    static func frameDelay(unclamped: Double?, clamped: Double?) -> Double {
        guard let delay = unclamped ?? clamped, delay >= 0.011 else { return defaultFrameDelay }
        return delay
    }

    private static func isGIF(_ source: CGImageSource) -> Bool {
        CGImageSourceGetType(source).flatMap { UTType($0 as String) }?.conforms(to: .gif) ?? false
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
