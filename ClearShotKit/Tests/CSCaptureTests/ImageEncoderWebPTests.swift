import Accelerate
import CoreGraphics
import CSCore
import Foundation
import ImageIO
import Testing
@testable import CSCapture

/// WebP through `ImageEncoder`: always lossless, whatever `quality` says. Every file is decoded with ImageIO and its own
/// pixels (not a redrawing of them) compared with what the encoder was given.
struct ImageEncoderWebPTests {
    // MARK: Retina-like screenshot

    @Test func aRetinaScreenshotRoundTripsExactlyAtLowQuality() throws {
        let screenshot = WebPSamples.retinaWindow(width: 600, height: 400)
        let file = try ImageEncoder.encode(screenshot.image, as: .webp, quality: 0.5, pixelsPerPoint: 2)

        let decoded = try WebPDecoding.decode(file)
        #expect(decoded.rgba.count == 600 * 400 * 4)
        if let problem = decoded.firstMismatch(expected: screenshot.rgba, width: 600, height: 400) {
            Issue.record("a Retina-like screenshot at quality 0.5 came back different: \(problem)")
        }
        // An opaque image is written as one: no alpha.
        #expect(decoded.hasAlpha == false)
    }

    @Test func qualityDoesNotChangeTheFile() throws {
        let screenshot = WebPSamples.retinaWindow(width: 200, height: 120)
        let reference = try ImageEncoder.encode(screenshot.image, as: .webp, quality: 1.0)
        for quality in [0.0, 0.5, 0.9, 1.0, 7.0, -3.0, .nan] {
            let file = try ImageEncoder.encode(screenshot.image, as: .webp, quality: quality)
            #expect(file == reference, "quality \(quality)")
        }
        // The density a Retina capture would pass has nowhere to go either.
        #expect(try ImageEncoder.encode(screenshot.image, as: .webp, quality: 0.5, pixelsPerPoint: 2) == reference)
    }

    @Test func aScreenshotIsSmallerAsWebPThanAsPNG() throws {
        let screenshot = WebPSamples.retinaWindow(width: 600, height: 400)
        let webp = try ImageEncoder.encode(screenshot.image, as: .webp, quality: 0.5)
        let png = try ImageEncoder.encode(screenshot.image, as: .png, quality: 0.5)
        let source = try #require(CGImageSourceCreateWithData(webp as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == ImageFormat.webp.utType)
        #expect(webp.count < png.count, "WebP \(webp.count) bytes, PNG \(png.count) bytes")
    }

    // MARK: Alpha

    @Test func aTranslucentImageKeepsItsAlphaAndColour() throws {
        let sample = WebPSamples.translucentBands(width: 70, height: 40)
        let file = try ImageEncoder.encode(sample, as: .webp, quality: 0.5)
        let decoded = try WebPDecoding.decode(file)
        #expect(decoded.hasAlpha)

        // What was drawn: bands of alpha, left to right, in pure red.
        for (band, alpha) in WebPSamples.bandAlphas.enumerated() {
            let pixel = decoded.pixel(x: band * 10 + 5, y: 20)
            #expect(pixel.a == alpha, "band \(band)")
            if alpha > 0 {
                // Un-premultiplied, so a faint red is still red, not dark red.
                #expect(pixel.r >= 254 && pixel.g == 0 && pixel.b == 0, "band \(band): \(pixel)")
            }
        }
        // And every pixel is what encodeWebP hands the encoder: the image in 8-bit sRGB, un-premultiplied.
        let expected = WebPSamples.encoderInput(of: sample)
        if let problem = decoded.firstMismatch(expected: expected, width: 70, height: 40) {
            Issue.record("a translucent image at quality 0.5 came back different: \(problem)")
        }
    }

    @Test func aFullyTransparentImageStaysTransparent() throws {
        let clear = TestImages.solid(width: 33, height: 17, color: TestImages.clear)
        let decoded = try WebPDecoding.decode(try ImageEncoder.encode(clear, as: .webp, quality: 0.5))
        #expect(decoded.width == 33 && decoded.height == 17)
        for y in 0..<17 {
            for x in 0..<33 { #expect(decoded.pixel(x: x, y: y).a == 0, "(\(x), \(y))") }
        }
    }

    // MARK: HDR

    @Test func anHDRSourceIsWhatItLooksLikeInSRGB() throws {
        let hdr = WebPSamples.extendedRangeStripes(width: 64, height: 48)
        let file = try ImageEncoder.encode(hdr, as: .webp, quality: 0.5)
        let decoded = try WebPDecoding.decode(file)

        // The same image drawn into an 8-bit sRGB context, exactly as encodeWebP does.
        let expected = WebPSamples.encoderInput(of: hdr)
        if let problem = decoded.firstMismatch(expected: expected, width: 64, height: 48) {
            Issue.record("an extended-range source at quality 0.5 came back different: \(problem)")
        }

        // Independent of that mirror: beyond sRGB's range a channel clamps (stripe 63 is 1.5, -0.25, 0.5), and the
        // translucent rows (alpha one half) keep their alpha.
        let beyond = decoded.pixel(x: 63, y: 4)
        #expect(beyond.a == 255)
        #expect(beyond.r == 255 && beyond.g == 0 && abs(Int(beyond.b) - 128) <= 1, "\(beyond)")
        let translucent = decoded.pixel(x: 63, y: 24)
        #expect(abs(Int(translucent.a) - 128) <= 1, "\(translucent)")
        #expect(decoded.pixel(x: 63, y: 44).a == 0)
    }

    // MARK: Sizes

    @Test func theLongestSideAWebPCanHoldEncodesAndOneMoreDoesNot() throws {
        for (width, height) in [(16_383, 1), (1, 16_383)] {
            let image = TestImages.solid(width: width, height: height, color: TestImages.blue)
            let decoded = try WebPDecoding.decode(try ImageEncoder.encode(image, as: .webp, quality: 0.5))
            #expect(decoded.width == width && decoded.height == height)
            #expect(decoded.pixel(x: width - 1, y: height - 1) == WebPDecoding.Pixel(r: 0, g: 0, b: 255, a: 255))
        }
        for (width, height) in [(16_384, 1), (1, 16_384)] {
            let image = TestImages.solid(width: width, height: height, color: TestImages.blue)
            #expect(throws: ImageEncoderError.encodingFailed(.webp), "\(width)x\(height)") {
                try ImageEncoder.encode(image, as: .webp, quality: 0.5)
            }
        }
    }
}

// MARK: - Samples

/// Images made in code, and what `ImageEncoder` hands the WebP encoder for them.
enum WebPSamples {
    /// Alpha of the translucent bands, left to right, ten pixels each.
    static let bandAlphas: [UInt8] = [255, 200, 128, 64, 3, 1, 0]

    /// An opaque, window-like picture at 2x: flat fills, 2-pixel borders (a 1-point line), glyph-like strokes, a grid of
    /// 2-colour checkboxes and a gradient bar (more than 256 colours). Returns the bytes too, since an opaque image's are
    /// the same premultiplied or not.
    static func retinaWindow(width: Int, height: Int) -> (image: CGImage, rgba: [UInt8]) {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        func set(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let offset = (y * width + x) * 4
            rgba[offset] = r
            rgba[offset + 1] = g
            rgba[offset + 2] = b
        }
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            let (left, right, top, bottom) = (max(x0, 0), min(x1, width), max(y0, 0), min(y1, height))
            guard left < right, top < bottom else { return }
            for y in top..<bottom {
                for x in left..<right { set(x, y, r, g, b) }
            }
        }
        fill(0, 0, width, height, 236, 236, 236)                         // window
        fill(0, 0, width, 56, 218, 218, 220)                             // title bar
        fill(0, 56, width, 58, 190, 190, 192)                            // its border
        fill(0, 0, 2, height, 160, 160, 162)                             // window borders
        fill(width - 2, 0, width, height, 160, 160, 162)
        fill(0, height - 2, width, height, 160, 160, 162)
        for (index, color) in [(255, 95, 86), (255, 189, 46), (39, 201, 63)].enumerated() {   // traffic lights
            let x = 24 + index * 36
            fill(x, 18, x + 20, 38, UInt8(color.0), UInt8(color.1), UInt8(color.2))
        }
        // "Text": dark strokes on light, a repeated glyph-like pattern, line after line.
        for line in 0..<6 {
            let y = 90 + line * 28
            for glyph in 0..<((width - 80) / 14) {
                let x = 40 + glyph * 14
                guard (glyph * 7 + line * 3) % 11 != 0 else { continue }       // word gaps
                fill(x, y, x + 2, y + 16, 40, 40, 44)
                if glyph % 3 != 0 { fill(x, y, x + 10, y + 2, 40, 40, 44) }
                if glyph % 2 == 0 { fill(x + 8, y, x + 10, y + 16, 40, 40, 44) }
            }
        }
        // A grid of 2-colour checkboxes: white, or blue inside the white.
        for row in 0..<2 {
            for column in 0..<12 {
                let x = 40 + column * 30
                let y = 270 + row * 30
                let checked = (row + column) % 2 == 0
                fill(x, y, x + 20, y + 20, 255, 255, 255)
                if checked { fill(x + 4, y + 4, x + 16, y + 16, 10, 132, 255) }
            }
        }
        // A gradient bar.
        let barWidth = max(width - 80, 1)
        for x in 0..<barWidth {
            let level = UInt8(x * 255 / max(barWidth - 1, 1))
            fill(40 + x, 340, 41 + x, 354, level, UInt8(255 - Int(level)), 128 + level / 2)
        }
        return (cgImage(rgba: rgba, width: width, height: height), rgba)
    }

    /// Bands of pure red, ten pixels wide, with the alphas of `bandAlphas`, drawn into an ordinary premultiplied bitmap.
    static func translucentBands(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: TestImages.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (band, alpha) in bandAlphas.enumerated() where alpha > 0 {
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: CGFloat(alpha) / 255))
            context.fill(CGRect(x: band * 10, y: 0, width: 10, height: height))
        }
        return context.makeImage()!
    }

    /// An extended-sRGB float image (what an HDR display captures), stripe `x` having red from -0.25 to 1.5 and blue 0.5;
    /// the top third of the rows opaque, the middle third half transparent and the bottom third clear. Stripe
    /// `width - 1` is (1.5, -0.25, 0.5), beyond what sRGB can show.
    static func extendedRangeStripes(width: Int, height: Int) -> CGImage {
        let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: 0,
                                space: space, bitmapInfo: info)!
        let third = height / 3
        for x in 0..<width {
            let t = CGFloat(x) / CGFloat(width - 1)
            let red = -0.25 + 1.75 * t
            let green = 0.9 - 1.15 * t
            for (band, alpha) in [(0, CGFloat(1)), (1, CGFloat(0.5))] {
                context.setFillColor(CGColor(colorSpace: space, components: [red, green, 0.5, alpha])!)
                // CG is y-up: the top third of the image is the highest rows.
                context.fill(CGRect(x: x, y: height - (band + 1) * third, width: 1, height: third))
            }
        }
        return context.makeImage()!
    }

    /// An 8-bit sRGB RGBA image over `rgba`, rows top to bottom.
    static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: TestImages.srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)!
    }

    /// What `ImageEncoder` gives the encoder for `image`: it drawn into an 8-bit premultiplied sRGB bitmap, then
    /// un-premultiplied. Written out again here so a change to that conversion shows up as a failing test.
    static func encoderInput(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: TestImages.srgb,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var buffer = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
            vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        }
        return pixels
    }
}

// MARK: - Decoding

/// ImageIO's reading of a WebP file, taken from the `CGImage`'s own bytes (no redrawing) and put in RGBA order.
///
/// On macOS 27 ImageIO returns a lossless WebP as 8-bit sRGB RGBA, not premultiplied (`alphaInfo` `.last`, or
/// `.noneSkipLast` for a file with no alpha). The comparison below also handles a premultiplied layout, in case that
/// changes.
struct WebPDecoding {
    struct Pixel: Equatable, CustomStringConvertible {
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8
        var description: String { "RGBA(\(r), \(g), \(b), \(a))" }
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    var width: Int
    var height: Int
    var rgba: [UInt8]
    var premultiplied: Bool
    var hasAlpha: Bool

    static func decode(_ data: Data) throws -> WebPDecoding {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(description: "ImageIO could not decode the file")
        }
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, !image.bitmapInfo.contains(.floatComponents),
              let bytes = image.dataProvider?.data, let base = CFDataGetBytePtr(bytes) else {
            throw Failure(description: "unexpected decoded layout: \(image.bitsPerComponent) bits per component, "
                + "\(image.bitsPerPixel) per pixel, bitmapInfo \(image.bitmapInfo.rawValue)")
        }
        let premultiplied: Bool
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .last: (premultiplied, hasAlpha) = (false, true)
        case .premultipliedLast: (premultiplied, hasAlpha) = (true, true)
        case .noneSkipLast: (premultiplied, hasAlpha) = (false, false)
        default: throw Failure(description: "unexpected decoded alphaInfo \(image.alphaInfo.rawValue)")
        }
        guard image.byteOrderInfo == .orderDefault || image.byteOrderInfo == .order32Big else {
            throw Failure(description: "unexpected decoded byte order \(image.byteOrderInfo.rawValue)")
        }
        let width = image.width
        let height = image.height
        guard CFDataGetLength(bytes) >= image.bytesPerRow * (height - 1) + width * 4 else {
            throw Failure(description: "the decoded image holds fewer bytes than its size needs")
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<(hasAlpha ? 4 : 3) {
                    rgba[(y * width + x) * 4 + channel] = base[y * image.bytesPerRow + x * 4 + channel]
                }
            }
        }
        return WebPDecoding(width: width, height: height, rgba: rgba, premultiplied: premultiplied, hasAlpha: hasAlpha)
    }

    func pixel(x: Int, y: Int) -> Pixel {
        let offset = (y * width + x) * 4
        return Pixel(r: rgba[offset], g: rgba[offset + 1], b: rgba[offset + 2], a: rgba[offset + 3])
    }

    /// A description of the first pixel that differs from `expected` (un-premultiplied RGBA, rows top to bottom), or nil.
    /// Alpha 255: R, G and B equal. Alpha 0: only alpha (the encoder may zero the invisible colour). In between: equal
    /// when un-premultiplied; compared after premultiplying `expected`, `round(c * a / 255)`, when the decoder
    /// premultiplied.
    func firstMismatch(expected: [UInt8], width expectedWidth: Int, height expectedHeight: Int) -> String? {
        guard width == expectedWidth, height == expectedHeight, expected.count == width * height * 4 else {
            return "size \(width)x\(height), expected \(expectedWidth)x\(expectedHeight)"
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let want = Pixel(r: expected[offset], g: expected[offset + 1], b: expected[offset + 2], a: expected[offset + 3])
                let got = pixel(x: x, y: y)
                if want.a != got.a { return "pixel (\(x), \(y)): expected \(want), got \(got): alpha differs" }
                if want.a == 0 { continue }
                var target = want
                if premultiplied, want.a < 255 {
                    func premultiply(_ channel: UInt8) -> UInt8 { UInt8((Int(channel) * Int(want.a) + 127) / 255) }
                    target = Pixel(r: premultiply(want.r), g: premultiply(want.g), b: premultiply(want.b), a: want.a)
                }
                if target != got { return "pixel (\(x), \(y)): expected \(want), got \(got)" }
            }
        }
        return nil
    }
}
