import CoreGraphics
import Foundation
import ImageIO

/// A change to a capture's pixels from the Quick Access menu.
public enum ImageTransform: Sendable, Equatable {
    case rotateLeft
    case flipHorizontal
    /// Halves a Retina image to one pixel per point.
    case scaleTo1x
    case resize(width: Int, height: Int)
}

/// Pixel operations for thumbnails, history and the Quick Access menu. Results are 8-bit premultiplied RGBA in the
/// source's RGB color space (sRGB when the source has none, or one an 8-bit bitmap can't hold, like extended-range).
public enum ImageOps {
    /// The longest side `loadUpright` decodes a picture at: the output limit, the largest side every format ClearShot
    /// writes can hold (`AnnotationDocument.maximumOutputSide`, WebP's limit: the encoder's 16 383, which is what macOS
    /// can decode). A larger picture is decoded scaled down to it, so it never takes a full decode of many gigabytes
    /// first.
    public static let maximumLoadedSide = 16_383

    /// The first image in a file, or nil if it can't be read.
    public static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// `load`, with the pixels decoded before it returns instead of when the image is first drawn. Called off the main
    /// actor, it keeps the decode there: Core Animation would otherwise decode a layer's image on the main thread when it
    /// first shows it (a pin's full-size picture).
    public static func loadDecoded(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// The first image in a file, turned upright using its orientation tag (photos from phones and cameras), and at most
    /// `maximumLoadedSide` on its longer side. For images coming from outside ClearShot; ClearShot's own files have no
    /// orientation tag and use `load`.
    public static func loadUpright(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return upright(from: source)?.image
    }

    /// Image data from the clipboard, turned upright and held to `maximumLoadedSide`. With several images in the data (a
    /// multi-size TIFF), the one with the most pixels is used, so Retina pixels aren't lost to a 1x copy listed first.
    public static func loadUpright(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return upright(from: source)?.image
    }

    /// What `loadUpright` gives for a source the caller has already opened, with the density (dots per inch, as
    /// `kCGImagePropertyDPIWidth`) recorded for the image it used, so a caller that wants both opens the file once.
    /// Nil when the source has no image, or it can't be decoded.
    public static func loadUpright(from source: CGImageSource) -> (image: CGImage, dpi: Double?)? {
        upright(from: source).map { (image: $0.image, dpi: $0.dpi) }
    }

    private static func upright(from source: CGImageSource) -> (image: CGImage, dpi: Double?)? {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        // The sizes come from the file, so a malformed or hostile one can claim sides whose product overflows; those
        // entries are skipped.
        var best: (index: Int, width: Int, height: Int, pixels: Int)?
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard let pixels = pixelCount(width: width, height: height), pixels > (best?.pixels ?? 0) else { continue }
            best = (index, width, height, pixels)
        }
        // No usable size: decode the first image as it is, as before.
        let index = best?.index ?? 0
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        guard let best else { return CGImageSourceCreateImageAtIndex(source, 0, nil).map { ($0, dpi) } }
        let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let longer = max(best.width, best.height)
        // Without an orientation to apply or a size to bring down, decode as-is: the thumbnail API would re-render for nothing.
        guard orientation != 1 || longer > maximumLoadedSide else {
            return CGImageSourceCreateImageAtIndex(source, best.index, nil).map { ($0, dpi) }
        }
        // The thumbnail API turns the picture upright and scales it down as it decodes.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longer, maximumLoadedSide),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, best.index, options as CFDictionary).map { ($0, dpi) }
    }

    /// `width × height`, or nil when a side isn't positive or the product overflows.
    static func pixelCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : pixels
    }

    /// A copy at most `maxPixel` on its longest side. Images already that small are returned as they are.
    public static func thumbnail(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard maxPixel > 0, longest > maxPixel else { return image }
        let factor = Double(maxPixel) / Double(longest)
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        return resized(image, width: width, height: height) ?? image
    }

    /// The image scaled to exactly `width` × `height` pixels, or nil for a side below 1.
    public static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let context = bitmapContext(width: width, height: height, preferring: image.colorSpace) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Rotated 90° counterclockwise: the top edge becomes the left edge.
    public static func rotatedLeft(_ image: CGImage) -> CGImage? {
        let width = image.height
        let height = image.width
        guard let context = bitmapContext(width: width, height: height, preferring: image.colorSpace) else { return nil }
        context.interpolationQuality = .none
        // CG is y-up, so a +90° rotation about the origin turns the image counterclockwise; shifting right by the
        // new width brings it back onto the canvas.
        context.translateBy(x: CGFloat(width), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Mirrored left to right.
    public static func flippedHorizontally(_ image: CGImage) -> CGImage? {
        guard let context = bitmapContext(width: image.width, height: image.height, preferring: image.colorSpace) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: CGFloat(image.width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Whether the image has an alpha channel. It may still be fully opaque.
    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Whether any pixel is less than fully opaque. An alpha channel alone doesn't mean transparency: most
    /// screenshots are opaque RGBA. The scan needs a byte per pixel, so an image over `maxPixels` isn't scanned and
    /// counts as transparent.
    public static func hasTransparentPixels(_ image: CGImage, maxPixels: Int = 400_000_000) -> Bool {
        guard hasAlpha(image) else { return false }
        let width = image.width
        let height = image.height
        // Treated as transparent, it is saved as PNG, which never loses anything.
        guard let pixels = pixelCount(width: width, height: height), pixels <= maxPixels else { return true }
        var alpha = [UInt8](repeating: 0, count: pixels)
        let drawn = alpha.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        // If the check can't run, treat the image as transparent: saving as PNG never loses anything.
        return !drawn || alpha.contains { $0 < 255 }
    }

    /// Applies a menu transform. `scale` is the image's pixels per point; only Scale to 1x changes it.
    public static func apply(_ transform: ImageTransform, to image: CGImage, scale: Double) -> (image: CGImage, scale: Double)? {
        switch transform {
        case .rotateLeft:
            rotatedLeft(image).map { ($0, scale) }
        case .flipHorizontal:
            flippedHorizontally(image).map { ($0, scale) }
        case .scaleTo1x:
            resized(image, width: max(1, Int((Double(image.width) / max(scale, 1)).rounded())),
                    height: max(1, Int((Double(image.height) / max(scale, 1)).rounded()))).map { ($0, 1) }
        case .resize(let width, let height):
            resized(image, width: width, height: height).map { ($0, scale) }
        }
    }

    /// An 8-bit premultiplied-RGBA bitmap in the `preferred` color space (the image's own, usually), or in sRGB when it
    /// has none that fits: no color space, gray, or extended-range color (HDR captures, float extended sRGB), which an
    /// 8-bit bitmap can't hold and which would otherwise fail every operation that draws into a new bitmap. The one place
    /// that fallback lives: the operations here, the annotation renderer and image placement all make their bitmaps with
    /// it. Nil only when no bitmap of that size can be made.
    public static func bitmapContext(width: Int, height: Int, preferring preferred: CGColorSpace?) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        if let preferred, preferred.model == .rgb,
           let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: preferred,
                                   bitmapInfo: info) {
            return context
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: info)
    }
}
