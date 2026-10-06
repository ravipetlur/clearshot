import CoreGraphics
import Foundation

enum TestImages {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    struct RGBA: Equatable {
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    }

    static func solid(width: Int, height: Int, color: CGColor, space: CGColorSpace = srgb) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// An HDR-style image: 32-bit float components in extended sRGB, which an 8-bit bitmap context can't be made in.
    static func extendedRange(width: Int, height: Int, color: CGColor) -> CGImage {
        let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.extendedSRGB)!, bitmapInfo: info)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A `base` image whose top `rows` rows (in image order) are `top`.
    static func withTopRows(width: Int, height: Int, rows: Int, top: CGColor, base: CGColor) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(base)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(top)
        context.fill(CGRect(x: 0, y: height - rows, width: width, height: rows)) // CG is y-up: top rows have high y
        return context.makeImage()!
    }

    /// Deterministic noise, useful where compression ratios matter.
    static func noise(width: Int, height: Int) -> CGImage {
        var state: UInt32 = 12345
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 {
                state = state &* 1_103_515_245 &+ 12345
                bytes[index + channel] = UInt8(truncatingIfNeeded: state >> 16)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// The pixel at (x, y), y counted from the top, as sRGB premultiplied RGBA.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> RGBA {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: srgb,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let index = (y * image.width + x) * 4
        return RGBA(r: data[index], g: data[index + 1], b: data[index + 2], a: data[index + 3])
    }

    static let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    static let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    static let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
}
