#if DEBUG
import CoreGraphics

/// Pixel-level probes for the capture self-test. Small and pure: no ScreenCaptureKit, no AppKit.
enum ImageProbe {
    /// `image` drawn into a `width`×`height` sRGB bitmap as premultiplied RGBA bytes, or nil if no bitmap could be made.
    static func thumbnail(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// False for a blank (single-value) image: a 32×32 thumbnail needs at least two distinct pixel values.
    static func hasContent(_ image: CGImage) -> Bool {
        guard let pixels = thumbnail(image, width: 32, height: 32) else { return false }
        return hasContent(pixels: pixels)
    }

    /// True when at least two of the RGBA pixels differ.
    static func hasContent(pixels: [UInt8]) -> Bool {
        guard pixels.count >= 8 else { return false }
        let first = pixels[0 ..< 4]
        for offset in stride(from: 4, through: pixels.count - 4, by: 4) where !pixels[offset ..< offset + 4].elementsEqual(first) {
            return true
        }
        return false
    }

    /// Mean absolute difference per colour channel (0–255) between two RGBA buffers of the same size; alpha is ignored.
    static func meanAbsoluteDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty, lhs.count.isMultiple(of: 4) else { return nil }
        var total = 0
        var samples = 0
        for pixel in stride(from: 0, to: lhs.count, by: 4) {
            for channel in 0 ..< 3 {
                total += abs(Int(lhs[pixel + channel]) - Int(rhs[pixel + channel]))
                samples += 1
            }
        }
        return Double(total) / Double(samples)
    }

    /// The images downsampled to `width`×`height` and compared with `meanAbsoluteDifference`.
    static func meanAbsoluteDifference(of lhs: CGImage, and rhs: CGImage, width: Int = 32, height: Int = 24) -> Double? {
        guard let left = thumbnail(lhs, width: width, height: height),
              let right = thumbnail(rhs, width: width, height: height) else { return nil }
        return meanAbsoluteDifference(left, right)
    }
}
#endif
