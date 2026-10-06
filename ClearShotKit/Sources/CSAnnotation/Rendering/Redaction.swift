import CoreGraphics
import CoreImage
import Foundation

/// Redaction, computed from the base pixels under the region only. Pixelate averages each block and adds random
/// per-block noise, seeded by the object's id so every render is identical. That way the original can't be recovered
/// from the blocks.
enum Redaction {
    typealias Effect = (RedactObject, CGRect, CGImage, Double, UUID) -> CGImage?

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func image(for redact: RedactObject, region: CGRect, base: CGImage, pixelScale: Double, seed: UUID) -> CGImage? {
        guard let crop = base.cropping(to: region) else { return nil }
        let intensity = Double(min(max(redact.intensity, 1), 10))
        let scale = pixelScale.isFinite && pixelScale > 0 ? min(pixelScale, 64) : 1
        let block = max(3, Int((intensity * 3 * scale).rounded()))
        switch redact.style {
        case .pixelate:
            return pixelated(crop, block: block, seed: seed)
        case .secureBlur:
            guard let blocks = pixelated(crop, block: max(3, block / 2), seed: seed) else { return nil }
            return blurred(blocks, sigma: intensity * 1.5 * scale)
        case .smoothBlur:
            return blurred(crop, sigma: intensity * 2 * scale)
        case .blackOut:
            return nil
        }
    }

    /// Each block of `block` pixels, counted from the image's top-left, becomes the average of exactly the pixels it
    /// covers (a block cut short by the right or bottom edge averages just those) plus per-block noise. Nil if a bitmap
    /// can't be made.
    static func pixelated(_ image: CGImage, block: Int, seed: UUID) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, block > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let columns = (width + block - 1) / block
        let rows = (height + block - 1) / block
        // The pixels, premultiplied, top row first.
        var source = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = source.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var generator = SeededGenerator(seed: seed)
        var blocks = [UInt8](repeating: 0, count: columns * rows * 4)
        source.withUnsafeBufferPointer { pixels in
            for row in 0..<rows {
                let top = row * block
                let bottom = min(top + block, height)
                for column in 0..<columns {
                    let left = column * block
                    let right = min(left + block, width)
                    var sums = (red: 0, green: 0, blue: 0, alpha: 0)
                    for y in top..<bottom {
                        var offset = (y * width + left) * 4
                        for _ in left..<right {
                            sums.red += Int(pixels[offset])
                            sums.green += Int(pixels[offset + 1])
                            sums.blue += Int(pixels[offset + 2])
                            sums.alpha += Int(pixels[offset + 3])
                            offset += 4
                        }
                    }
                    let count = (bottom - top) * (right - left)
                    let alpha = (sums.alpha + count / 2) / count
                    let target = (row * columns + column) * 4
                    for (channel, sum) in [sums.red, sums.green, sums.blue].enumerated() {
                        let value = (sum + count / 2) / count + Int.random(in: -24...24, using: &generator)
                        // Premultiplied: no channel may exceed alpha.
                        blocks[target + channel] = UInt8(min(max(value, 0), alpha))
                    }
                    blocks[target + 3] = UInt8(alpha)
                }
            }
        }

        var output = [UInt8](repeating: 0, count: width * height * 4)
        blocks.withUnsafeBufferPointer { blocks in
            output.withUnsafeMutableBufferPointer { output in
                for y in 0..<height {
                    let blockRow = (y / block) * columns
                    for x in 0..<width {
                        let from = (blockRow + x / block) * 4
                        let to = (y * width + x) * 4
                        output[to] = blocks[from]
                        output[to + 1] = blocks[from + 1]
                        output[to + 2] = blocks[from + 2]
                        output[to + 3] = blocks[from + 3]
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    static func blurred(_ image: CGImage, sigma: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        return ciContext.createCGImage(output, from: input.extent)
    }
}

/// SplitMix64: a small, fast generator with a fixed seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UUID) {
        state = withUnsafeBytes(of: seed.uuid) { $0.loadUnaligned(as: UInt64.self) } ^ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
