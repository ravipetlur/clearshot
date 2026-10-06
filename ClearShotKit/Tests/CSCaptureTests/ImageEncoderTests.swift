import CoreGraphics
import CSCore
import Foundation
import ImageIO
import Testing
@testable import CSCapture

struct ImageEncoderTests {
    func decode(_ data: Data) -> (type: String?, image: CGImage?) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return (CGImageSourceGetType(source) as String?, CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test(arguments: ImageFormat.allCases)
    func encodesEachFormatAsItsType(format: ImageFormat) throws {
        let image = TestImages.solid(width: 32, height: 16, color: TestImages.red)
        let decoded = decode(try ImageEncoder.encode(image, as: format, quality: 0.9))
        #expect(decoded.type == format.utType)
        #expect(decoded.image?.width == 32)
        #expect(decoded.image?.height == 16)
    }

    @Test func losslessWebPKeepsTransparency() throws {
        let image = TestImages.solid(width: 8, height: 8, color: TestImages.clear)
        let decoded = decode(try ImageEncoder.encode(image, as: .webp, quality: 1.0))
        #expect(decoded.image.map { TestImages.pixel($0, x: 4, y: 4).a } == 0)
    }

    /// Pins the WebP pixel layout: channel order, row order and alpha handling all have to survive the round trip.
    @Test func losslessWebPRoundTripsPixelsExactly() throws {
        // Premultiplied sRGB RGBA, rows top to bottom: red, green / blue, half-alpha red.
        let bytes: [UInt8] = [
            255, 0, 0, 255, /**/ 0, 255, 0, 255,
            0, 0, 255, 255, /**/ 128, 0, 0, 128,
        ]
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                            space: TestImages.srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!

        let decoded = try #require(decode(try ImageEncoder.encode(image, as: .webp, quality: 1.0)).image)

        #expect(TestImages.pixel(decoded, x: 0, y: 0) == TestImages.RGBA(r: 255, g: 0, b: 0, a: 255))
        #expect(TestImages.pixel(decoded, x: 1, y: 0) == TestImages.RGBA(r: 0, g: 255, b: 0, a: 255))
        #expect(TestImages.pixel(decoded, x: 0, y: 1) == TestImages.RGBA(r: 0, g: 0, b: 255, a: 255))
        #expect(TestImages.pixel(decoded, x: 1, y: 1) == TestImages.RGBA(r: 128, g: 0, b: 0, a: 128))
    }

    @Test func jpegFlattensTransparencyOntoWhite() throws {
        // JPEG has no alpha, so a half-transparent red has to come out as what shows on white: opaque pink. ImageIO does
        // that for ordinary bitmaps; an HDR one (float extended sRGB) comes out dark, its alpha just dropped.
        let halfRed = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)
        let ordinary = TestImages.solid(width: 16, height: 16, color: halfRed)
        let hdr = TestImages.extendedRange(width: 16, height: 16, color: halfRed)
        for (name, image) in [("8-bit", ordinary), ("extended range", hdr)] {
            let decoded = try #require(decode(try ImageEncoder.encode(image, as: .jpeg, quality: 1.0)).image)
            let pixel = TestImages.pixel(decoded, x: 8, y: 8)
            #expect(pixel.a == 255, "\(name)")
            #expect(abs(Int(pixel.r) - 255) <= 4, "\(name)")
            #expect(abs(Int(pixel.g) - 127) <= 4, "\(name)")
            #expect(abs(Int(pixel.b) - 127) <= 4, "\(name)")
            // Nothing see-through at all comes out white, not black.
            let clear = try #require(decode(try ImageEncoder.encode(
                name == "8-bit" ? TestImages.solid(width: 8, height: 8, color: TestImages.clear)
                    : TestImages.extendedRange(width: 8, height: 8, color: TestImages.clear), as: .jpeg, quality: 1.0)).image)
            let white = TestImages.pixel(clear, x: 4, y: 4)
            #expect(white.r >= 251 && white.g >= 251 && white.b >= 251, "\(name)")
        }
    }

    @Test func opaqueImagesEncodeAsJPEGUnchanged() throws {
        let image = TestImages.solid(width: 16, height: 16, color: TestImages.blue)
        let decoded = try #require(decode(try ImageEncoder.encode(image, as: .jpeg, quality: 1.0)).image)
        let pixel = TestImages.pixel(decoded, x: 8, y: 8)
        #expect(pixel.b >= 251 && pixel.r <= 4 && pixel.g <= 4)
    }

    @Test func formatsWithAlphaKeepTheirTransparency() throws {
        let halfRed = TestImages.solid(width: 16, height: 16, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        for format in [ImageFormat.png, .heic] {
            let decoded = try #require(decode(try ImageEncoder.encode(halfRed, as: format, quality: 1.0)).image)
            let alpha = TestImages.pixel(decoded, x: 8, y: 8).a
            #expect(abs(Int(alpha) - 128) <= 4, "\(format)")
        }
    }

    @Test func withoutAScaleNoDensityIsRecorded() throws {
        let image = TestImages.solid(width: 8, height: 8, color: TestImages.red)
        func dpi(_ data: Data) -> Any? {
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyDPIWidth]
        }
        for scale in [nil, 0, -2, .nan, .infinity] as [Double?] {
            #expect(dpi(try ImageEncoder.encode(image, as: .png, quality: 1, pixelsPerPoint: scale)) == nil, "\(String(describing: scale))")
        }
        // WebP has nowhere to keep one; asking for it still encodes.
        #expect(decode(try ImageEncoder.encode(image, as: .webp, quality: 1, pixelsPerPoint: 2)).image?.width == 8)
    }

    @Test func lowerQualityMakesASmallerJPEG() throws {
        let image = TestImages.noise(width: 128, height: 128)
        let low = try ImageEncoder.encode(image, as: .jpeg, quality: 0.3)
        let high = try ImageEncoder.encode(image, as: .jpeg, quality: 1.0)
        #expect(low.count < high.count)
    }
}
