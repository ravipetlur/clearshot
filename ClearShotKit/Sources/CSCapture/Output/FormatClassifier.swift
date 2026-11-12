import CoreGraphics

/// Tells a flat, UI or text-heavy picture (best saved as PNG) from a photographic one (best as JPEG), for the
/// Automatic file format.
///
/// The picture is drawn down to at most `sampleSide` pixels on its long side with no smoothing, so flat areas stay
/// exactly flat instead of picking up blended edge colors. Each sampled pixel's colors are quantised to
/// `bitsPerChannel` bits, and two numbers come out: how many distinct colors there are, and what share of the pixels the
/// `topCount` most common ones hold. A UI is a few big flat areas, so its common colors cover most of it; a photograph
/// or a noisy gradient spreads over thousands of colors, and no few of them dominate.
///
/// A picture is photographic when it has at least `minimumPhotoColors` distinct colors and its top colors hold under
/// `maximumPhotoTopShare` of the pixels. Either number on the other side of its line means flat, and flat is PNG: a
/// mixed picture (a web page with one photo in it) stays PNG, because JPEG would smear its text. A picture with a
/// less-than-opaque pixel is flat too.
///
/// The lines were set from the synthetic pictures in `FormatClassifierTests`: a UI mock measures 11 colors with all
/// its pixels in the top ones; a noisy gradient (the quietest picture meant to count as a photo) measures about 1,700
/// colors with 3.5% in the top ones. The color floor sits well under the photo and far over any UI; the share ceiling
/// is the stronger test. On a 6K capture the sampling and counting take about 10 ms in a debug build.
public enum FormatClassifier {
    public enum Kind: Sendable, Equatable {
        case flat, photographic
    }

    /// What the classifier measured, for tests and tuning.
    public struct Measurement: Sendable, Equatable {
        public var distinctColors: Int
        /// The share, 0...1, of the sampled pixels in the `topCount` most common colors.
        public var topShare: Double
        /// Whether a sampled pixel was less than fully opaque.
        public var hasTransparency: Bool
    }

    public static let sampleSide = 256
    public static let bitsPerChannel = 5
    public static let topCount = 16
    public static let minimumPhotoColors = 600
    public static let maximumPhotoTopShare = 0.5

    public static func classify(_ image: CGImage) -> Kind {
        guard let measured = measure(image), !measured.hasTransparency else { return .flat }
        return measured.distinctColors >= minimumPhotoColors && measured.topShare < maximumPhotoTopShare ? .photographic : .flat
    }

    /// nil when the picture can't be sampled.
    public static func measure(_ image: CGImage) -> Measurement? {
        guard image.width > 0, image.height > 0 else { return nil }
        let factor = min(1, Double(sampleSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let shift = UInt8(8 - bitsPerChannel)
        var histogram = [UInt32](repeating: 0, count: 1 << (3 * bitsPerChannel))
        var transparent = false
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index + 3] < 255 { transparent = true }
            let key = (Int(pixels[index] >> shift) << (2 * bitsPerChannel)) | (Int(pixels[index + 1] >> shift) << bitsPerChannel)
                | Int(pixels[index + 2] >> shift)
            histogram[key] += 1
        }

        var distinct = 0
        // The topCount largest counts, ascending: top[0] is the smallest one kept.
        var top = [UInt32](repeating: 0, count: topCount)
        for count in histogram where count > 0 {
            distinct += 1
            guard count > top[0] else { continue }
            var slot = 0
            while slot + 1 < topCount, top[slot + 1] < count {
                top[slot] = top[slot + 1]
                slot += 1
            }
            top[slot] = count
        }
        let share = Double(top.reduce(0) { $0 + Int($1) }) / Double(width * height)
        return Measurement(distinctColors: distinct, topShare: share, hasTransparency: transparent)
    }
}
