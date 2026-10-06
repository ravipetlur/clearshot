import CoreGraphics
import Foundation
@testable import CSAnnotation

enum TestBitmaps {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    static let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    static let yellow = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)

    struct RGBA: Equatable {
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    }

    static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func solid(_ width: Int, _ height: Int, _ color: CGColor) -> CGImage {
        let context = context(width, height)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Pixels left of `at` (default: the middle) are `left`, the rest `right`.
    static func split(_ width: Int, _ height: Int, left: CGColor, right: CGColor, at: Int? = nil) -> CGImage {
        let context = context(width, height)
        context.setFillColor(right)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(left)
        context.fill(CGRect(x: 0, y: 0, width: at ?? width / 2, height: height))
        return context.makeImage()!
    }

    /// Each quarter of the bitmap its own color (as seen, y down), so a turn or mirror shows in the picture.
    static func quadrants(_ width: Int, _ height: Int, topLeft: CGColor, topRight: CGColor, bottomLeft: CGColor,
                          bottomRight: CGColor) -> CGImage {
        let context = context(width, height)
        let halfWidth = width / 2, halfHeight = height / 2
        // CG is y-up: the top row of quarters is the upper one.
        let quarters: [(CGColor, CGRect)] = [
            (topLeft, CGRect(x: 0, y: halfHeight, width: halfWidth, height: height - halfHeight)),
            (topRight, CGRect(x: halfWidth, y: halfHeight, width: width - halfWidth, height: height - halfHeight)),
            (bottomLeft, CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight)),
            (bottomRight, CGRect(x: halfWidth, y: 0, width: width - halfWidth, height: halfHeight)),
        ]
        for (color, rect) in quarters {
            context.setFillColor(color)
            context.fill(rect)
        }
        return context.makeImage()!
    }

    /// An HDR-style base: 32-bit float components in extended sRGB, which an 8-bit bitmap context can't be made in.
    static func extendedSRGB(_ width: Int, _ height: Int, _ color: CGColor) -> CGImage {
        let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.extendedSRGB)!, bitmapInfo: info)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A context for drawing a document into: user space is pixels with y down, like `Renderer.render` sets up.
    static func flippedContext(_ width: Int, _ height: Int) -> CGContext {
        let context = context(width, height)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    /// Top half `top`, bottom half `bottom` (as seen, y down).
    static func stacked(_ width: Int, _ height: Int, top: CGColor, bottom: CGColor) -> CGImage {
        let context = context(width, height)
        context.setFillColor(bottom)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(top)
        // CG is y-up: the top half is the upper one.
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return context.makeImage()!
    }

    /// Fully transparent, with `blocks` (rects in pixels counted from the top-left, y down) painted in `color`.
    static func transparent(_ width: Int, _ height: Int, blocks: [CGRect] = [], color: CGColor = black) -> CGImage {
        let context = context(width, height)
        context.setFillColor(color)
        for block in blocks {
            context.fill(CGRect(x: block.minX, y: CGFloat(height) - block.maxY, width: block.width, height: block.height))
        }
        return context.makeImage()!
    }

    /// `border` pixels of `edge` around `inside`.
    static func bordered(_ size: Int, border: Int, edge: CGColor, inside: CGColor) -> CGImage {
        let context = context(size, size)
        context.setFillColor(edge)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(inside)
        context.fill(CGRect(x: border, y: border, width: size - 2 * border, height: size - 2 * border))
        return context.makeImage()!
    }

    /// Deterministic opaque noise.
    static func noise(_ width: Int, _ height: Int) -> CGImage {
        var state: UInt32 = 7
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 {
                state = state &* 1_103_515_245 &+ 12345
                bytes[index + channel] = UInt8(truncatingIfNeeded: state >> 16)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: srgb,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// All pixels as RGBA bytes, top row first.
    static func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    /// The pixel at (x, y), y counted from the top.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGBA {
        let data = bytes(image)
        let index = (y * image.width + x) * 4
        return RGBA(r: data[index], g: data[index + 1], b: data[index + 2], a: data[index + 3])
    }

    static func document(base: CGImage, objects: [AnnotationObject] = []) -> (AnnotationDocument, ImageStore) {
        var document = AnnotationDocument(baseSize: CGSize(width: base.width, height: base.height), pixelScale: 1)
        document.objects = objects
        return (document, ImageStore([ImageRef.original.name: base]))
    }
}
