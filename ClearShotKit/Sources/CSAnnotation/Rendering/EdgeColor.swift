import CoreGraphics
import Foundation

/// The color an expanded canvas fills with: the most common color along the image's border.
public enum EdgeColor {
    public static func dominant(in image: CGImage) -> RGBAColor {
        let side = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return .white }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var buckets: [UInt32: (count: Int, sums: (Double, Double, Double, Double))] = [:]
        for index in 0..<side {
            for (x, y) in [(index, 0), (index, side - 1), (0, index), (side - 1, index)] {
                let offset = (y * side + x) * 4
                let r = pixels[offset], g = pixels[offset + 1], b = pixels[offset + 2], a = pixels[offset + 3]
                let key = UInt32(r >> 4) << 12 | UInt32(g >> 4) << 8 | UInt32(b >> 4) << 4 | UInt32(a >> 4)
                var bucket = buckets[key] ?? (0, (0, 0, 0, 0))
                bucket.count += 1
                bucket.sums.0 += Double(r)
                bucket.sums.1 += Double(g)
                bucket.sums.2 += Double(b)
                bucket.sums.3 += Double(a)
                buckets[key] = bucket
            }
        }
        // Ties go to the lowest bucket, so the same image always gives the same color.
        guard let best = buckets.max(by: { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key })?.value
        else { return .white }
        let n = Double(best.count)
        let alpha = best.sums.3 / n / 255
        guard alpha > 0 else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) }
        // The bitmap is premultiplied.
        return RGBAColor(red: best.sums.0 / n / 255 / alpha, green: best.sums.1 / n / 255 / alpha,
                         blue: best.sums.2 / n / 255 / alpha, alpha: alpha)
    }
}
