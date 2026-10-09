import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CSWebP

/// Un-premultiplied sRGB RGBA8, rows top to bottom, 4 bytes per pixel and no padding: the encoder's input format.
struct RGBAImage: Sendable, Equatable {
    var width: Int
    var height: Int
    var rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4)
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// An image with every pixel `fill`.
    init(width: Int, height: Int, fill: Pixel = Pixel(0, 0, 0, 0)) {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        if fill != Pixel(0, 0, 0, 0) {
            for index in 0..<(width * height) {
                bytes[index * 4] = fill.r
                bytes[index * 4 + 1] = fill.g
                bytes[index * 4 + 2] = fill.b
                bytes[index * 4 + 3] = fill.a
            }
        }
        self.init(width: width, height: height, rgba: bytes)
    }

    subscript(x: Int, y: Int) -> Pixel {
        get {
            let offset = (y * width + x) * 4
            return Pixel(rgba[offset], rgba[offset + 1], rgba[offset + 2], rgba[offset + 3])
        }
        set {
            let offset = (y * width + x) * 4
            rgba[offset] = newValue.r
            rgba[offset + 1] = newValue.g
            rgba[offset + 2] = newValue.b
            rgba[offset + 3] = newValue.a
        }
    }

    /// Every distinct RGBA value in the image.
    var distinctColors: Set<Pixel> {
        var colors = Set<Pixel>()
        for y in 0..<height { for x in 0..<width { colors.insert(self[x, y]) } }
        return colors
    }
}

struct Pixel: Hashable, Sendable, CustomStringConvertible {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    var description: String { "RGBA(\(r), \(g), \(b), \(a))" }
}

/// Decodes the encoder's files with ImageIO and compares them with the source pixels.
///
/// ImageIO's pixel form for a decoded lossless WebP on macOS 27 (checked when this helper was written): 8 bits per
/// component, 32 bits per pixel, sRGB, bytes in R, G, B, A order, and **not premultiplied**. A file with alpha comes
/// back as `CGImageAlphaInfo.last` and an opaque one (`alpha_is_used` 0) as `.noneSkipLast`. So the comparison is
/// exact; the premultiplied branch below is kept for a decoder that changes its mind.
///
/// ImageIO is the one independent gate. It also refuses any image with a side of 16 384, although the format's 14-bit
/// size fields allow it, which is why the encoder's own limit is 16 383.
enum RoundTrip {
    enum DecodeError: Error, CustomStringConvertible {
        case notDecodable
        case noPixels
        case unsupportedLayout(String)

        var description: String {
            switch self {
            case .notDecodable: "ImageIO could not decode the file"
            case .noPixels: "ImageIO returned an image without readable pixel data"
            case .unsupportedLayout(let detail): "unsupported decoded pixel layout: \(detail)"
            }
        }
    }

    /// The decoded image as RGBA, and whether ImageIO handed its colour channels back premultiplied by alpha.
    struct Decoded {
        var image: RGBAImage
        var premultiplied: Bool
    }

    /// Decodes with `CGImageSourceCreateWithData` and `CGImageSourceCreateImageAtIndex`, then reads the `CGImage`'s own
    /// bytes through its data provider (no redrawing) and converts that layout to RGBA.
    static func decode(_ data: Data) throws -> Decoded {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DecodeError.notDecodable
        }
        guard let providerData = cgImage.dataProvider?.data else { throw DecodeError.noPixels }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        guard cgImage.bitsPerComponent == 8, cgImage.bitsPerPixel == 32,
              !cgImage.bitmapInfo.contains(.floatComponents) else {
            throw DecodeError.unsupportedLayout(
                "\(cgImage.bitsPerComponent) bits per component, \(cgImage.bitsPerPixel) bits per pixel, "
                    + "bitmapInfo \(cgImage.bitmapInfo.rawValue)")
        }
        guard CFDataGetLength(providerData) >= bytesPerRow * (height - 1) + width * 4,
              let base = CFDataGetBytePtr(providerData) else {
            throw DecodeError.noPixels
        }

        // The channels of the 32-bit pixel word, most significant first; `alphaInfo` names where the alpha sits.
        enum Channel { case red, green, blue, alpha, skip }
        let premultiplied: Bool
        let hasAlpha: Bool
        var word: [Channel]
        switch cgImage.alphaInfo {
        case .premultipliedFirst: (word, premultiplied, hasAlpha) = ([.alpha, .red, .green, .blue], true, true)
        case .premultipliedLast: (word, premultiplied, hasAlpha) = ([.red, .green, .blue, .alpha], true, true)
        case .first: (word, premultiplied, hasAlpha) = ([.alpha, .red, .green, .blue], false, true)
        case .last: (word, premultiplied, hasAlpha) = ([.red, .green, .blue, .alpha], false, true)
        case .noneSkipFirst: (word, premultiplied, hasAlpha) = ([.skip, .red, .green, .blue], false, false)
        case .noneSkipLast: (word, premultiplied, hasAlpha) = ([.red, .green, .blue, .skip], false, false)
        default: throw DecodeError.unsupportedLayout("alphaInfo \(cgImage.alphaInfo.rawValue)")
        }
        // Memory order: the word as written for default and big-endian pixels, reversed for 32-bit little-endian.
        switch cgImage.byteOrderInfo {
        case .orderDefault, .order32Big: break
        case .order32Little: word.reverse()
        default: throw DecodeError.unsupportedLayout("byteOrderInfo \(cgImage.byteOrderInfo.rawValue)")
        }

        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = base + y * bytesPerRow
            for x in 0..<width {
                for (slot, channel) in word.enumerated() {
                    let value = row[x * 4 + slot]
                    let offset = (y * width + x) * 4
                    switch channel {
                    case .red: rgba[offset] = value
                    case .green: rgba[offset + 1] = value
                    case .blue: rgba[offset + 2] = value
                    case .alpha: rgba[offset + 3] = hasAlpha ? value : 255
                    case .skip: break
                    }
                }
            }
        }
        return Decoded(image: RGBAImage(width: width, height: height, rgba: rgba), premultiplied: premultiplied)
    }

    /// `round(c * a / 255)`.
    static func premultiply(_ channel: UInt8, alpha: UInt8) -> UInt8 {
        UInt8((Int(channel) * Int(alpha) + 127) / 255)
    }

    /// A description of the first pixel where `decoded` differs from `source` by the comparison rule, or nil when they
    /// agree. The rule: the sizes match; alpha 255 compares R, G and B exactly; alpha 0 compares only alpha (the
    /// encoder zeroes the invisible RGB); in between, premultiplied decoder output is compared with the source
    /// premultiplied as `round(c * a / 255)`, and un-premultiplied output is compared exactly.
    static func firstMismatch(source: RGBAImage, decoded: Decoded) -> String? {
        let actual = decoded.image
        guard actual.width == source.width, actual.height == source.height else {
            return "size \(actual.width)x\(actual.height), expected \(source.width)x\(source.height)"
        }
        for y in 0..<source.height {
            for x in 0..<source.width {
                let expected = source[x, y]
                let got = actual[x, y]
                if expected.a != got.a {
                    return "pixel (\(x), \(y)): expected \(expected), got \(got): alpha differs"
                }
                if expected.a == 0 { continue }
                var want = expected
                if expected.a < 255, decoded.premultiplied {
                    want = Pixel(premultiply(expected.r, alpha: expected.a),
                                 premultiply(expected.g, alpha: expected.a),
                                 premultiply(expected.b, alpha: expected.a), expected.a)
                }
                if want != got {
                    let form = decoded.premultiplied ? " (compared premultiplied: expected \(want))" : ""
                    return "pixel (\(x), \(y)): expected \(expected), got \(got)\(form)"
                }
            }
        }
        return nil
    }

    /// A description of the first fully transparent pixel whose colour is not black, or nil when there is none.
    ///
    /// The encoder zeroes the colour of a fully transparent pixel (it is invisible), and ImageIO hands pixels back
    /// un-premultiplied, so the zeroing is observable: a decoded pixel with alpha 0 has RGB 0 0 0.
    static func firstColouredTransparentPixel(in decoded: Decoded) -> String? {
        let image = decoded.image
        for y in 0..<image.height {
            for x in 0..<image.width {
                let pixel = image[x, y]
                if pixel.a == 0, pixel.r != 0 || pixel.g != 0 || pixel.b != 0 {
                    return "pixel (\(x), \(y)): alpha 0 but colour \(pixel)"
                }
            }
        }
        return nil
    }

    /// Encodes `image` (with `coding` and `transforms`, the encoder's own choices by default), decodes the file with
    /// ImageIO and records an issue at the first mismatching pixel, and at the first transparent pixel that kept a
    /// colour. Returns the file, for a test that goes on to look at it.
    @discardableResult
    static func expectRoundTrip(
        _ image: RGBAImage, coding: WebPLosslessEncoder.PixelCoding = .backReferences(cacheBits: nil),
        transforms: WebPLosslessEncoder.Transforms = .automatic, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Data {
        let file = try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height,
                                                  coding: coding, transforms: transforms)
        let decoded = try decode(file)
        let name = "\(image.width)x\(image.height) image, \(transforms), \(coding)"
        if let problem = firstMismatch(source: image, decoded: decoded) {
            Issue.record("round trip of a \(name) failed at \(problem)", sourceLocation: sourceLocation)
        }
        if let problem = firstColouredTransparentPixel(in: decoded) {
            Issue.record("a transparent pixel kept its colour in a \(name): \(problem)", sourceLocation: sourceLocation)
        }
        return file
    }
}
