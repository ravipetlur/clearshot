import Accelerate
import CoreGraphics
import CSCore
import CSWebP
import Foundation
import ImageIO

public enum ImageEncoderError: Error, LocalizedError, Equatable {
    case encodingFailed(ImageFormat)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed(let format): "Couldn't create the \(format.title) image."
        }
    }
}

public enum ImageEncoder {
    /// Encodes an image. `quality` (0…1) applies to JPEG and HEIC; PNG and WebP are always lossless and ignore it.
    /// `pixelsPerPoint`, the image's own scale (2 for a Retina screenshot), is recorded as its density, 72 dpi per pixel
    /// per point, as macOS records its screenshots': Preview then shows the file at its point size, and an editor it is
    /// dropped or pasted into reads it back at its scale (`ImagePlacement.scale(forDPI:)`). Nil, or a scale that isn't a
    /// positive number, records none, and so does WebP, which has nowhere to keep one.
    public static func encode(_ image: CGImage, as format: ImageFormat, quality: Double, pixelsPerPoint: Double? = nil) throws -> Data {
        switch format {
        case .webp: try encodeWebP(image)
        default: try encodeWithImageIO(image, format: format, quality: quality, pixelsPerPoint: pixelsPerPoint)
        }
    }

    /// JPEG can't hold transparency, so a see-through image is drawn onto white first and that is what is encoded. ImageIO
    /// does this itself for ordinary bitmaps, but drops the alpha of an HDR one (float extended sRGB), leaving see-through
    /// pixels black or dark. An image with nothing see-through is encoded as it is. PNG, HEIC and WebP keep their alpha.
    private static func flattenedOntoWhite(_ image: CGImage) -> CGImage {
        guard ImageOps.hasTransparentPixels(image),
              let context = ImageOps.bitmapContext(width: image.width, height: image.height, preferring: image.colorSpace) else {
            return image
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    private static func encodeWithImageIO(_ image: CGImage, format: ImageFormat, quality: Double, pixelsPerPoint: Double?) throws -> Data {
        let image = format == .jpeg ? flattenedOntoWhite(image) : image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.utType as CFString, 1, nil) else {
            throw ImageEncoderError.encodingFailed(format)
        }
        var properties: [CFString: Any] = [:]
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        }
        if let pixelsPerPoint, pixelsPerPoint.isFinite, pixelsPerPoint > 0 {
            properties[kCGImagePropertyDPIWidth] = 72 * pixelsPerPoint
            properties[kCGImagePropertyDPIHeight] = 72 * pixelsPerPoint
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageEncoderError.encodingFailed(format) }
        return data as Data
    }

    /// ImageIO can't write WebP (macOS 27), so `WebPLosslessEncoder` encodes from un-premultiplied sRGB RGBA. The image is
    /// drawn into an 8-bit sRGB bitmap first, which is also what turns an HDR (float extended sRGB) or wide-gamut source
    /// into the 8-bit sRGB the encoder takes. The file is always lossless, so there is no quality here, and a side beyond
    /// the encoder's limit (16 383, what macOS can decode) fails.
    private static func encodeWebP(_ image: CGImage) throws -> Data {
        let width = image.width
        let height = image.height
        // Before a bitmap of gigabytes is made for an image the encoder would refuse.
        guard width <= WebPLosslessEncoder.maxSide, height <= WebPLosslessEncoder.maxSide else {
            throw ImageEncoderError.encodingFailed(.webp)
        }
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var buffer = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: stride)
            vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
            return true
        }
        guard drawn else { throw ImageEncoderError.encodingFailed(.webp) }

        do {
            return try WebPLosslessEncoder.encode(rgba: pixels, width: width, height: height)
        } catch {
            throw ImageEncoderError.encodingFailed(.webp)
        }
    }
}
