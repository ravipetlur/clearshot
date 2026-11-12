import Foundation
import Testing
@testable import CSWebP

/// How big the files are, against the system's PNG of the same pixels.
struct EncoderSizeTests {
    /// The screenshot two tests start from, made once.
    private static let screenshot1440x900 = Fixtures.uiScreenshot(1440, 900)

    private static func sizes(_ image: RGBAImage) throws -> (webp: Int, png: Int) {
        let file = try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height)
        return (file.count, try PNGReference.data(for: image).count)
    }

    /// Like `sizes`, and the file measured is the one the round trip checks, so the image is encoded once for both.
    private static func sizesAfterRoundTrip(_ image: RGBAImage, sourceLocation: SourceLocation = #_sourceLocation)
        throws -> (webp: Int, png: Int) {
        let file = try RoundTrip.expectRoundTrip(image, sourceLocation: sourceLocation)
        return (file.count, try PNGReference.data(for: image).count)
    }

    private static func size(_ image: RGBAImage, _ transforms: WebPLosslessEncoder.Transforms) throws -> Int {
        try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height,
                                       transforms: transforms).count
    }

    /// `image` softened by a 3 x 3 average, as anti-aliasing softens text and edges. A pixel at the border averages the
    /// neighbours inside the image. Worked on the bytes directly, since this is a large image.
    private static func blurred(_ image: RGBAImage) -> RGBAImage {
        let width = image.width, height = image.height
        var bytes = image.rgba
        image.rgba.withUnsafeBufferPointer { source in
            for y in 0..<height {
                for x in 0..<width {
                    var r = 0, g = 0, b = 0, count = 0
                    for ny in max(0, y - 1)...min(height - 1, y + 1) {
                        for nx in max(0, x - 1)...min(width - 1, x + 1) {
                            let offset = (ny * width + nx) * 4
                            r += Int(source[offset])
                            g += Int(source[offset + 1])
                            b += Int(source[offset + 2])
                            count += 1
                        }
                    }
                    let offset = (y * width + x) * 4
                    bytes[offset] = UInt8(r / count)
                    bytes[offset + 1] = UInt8(g / count)
                    bytes[offset + 2] = UInt8(b / count)
                    bytes[offset + 3] = 255
                }
            }
        }
        return RGBAImage(width: width, height: height, rgba: bytes)
    }

    @Test func aScreenshotWithAGradientIsNoLargerThanWithoutTransformsAndSmallerThanItsPNG() throws {
        let image = Self.screenshot1440x900
        #expect(image.distinctColors.count > 256, "it is judged for the predictor, which does not pay here")
        let (webp, png) = try Self.sizesAfterRoundTrip(image)
        // The encoder's own no-transform path is the baseline; prediction must not make a screenshot bigger than
        // that.
        let untransformed = try Self.size(image, .none)
        #expect(webp <= untransformed, "ui screenshot 1440x900: \(webp) bytes, without transforms \(untransformed)")
        #expect(webp < png, "ui screenshot 1440x900: WebP \(webp) bytes, PNG \(png) bytes")
    }

    @Test func aFlatScreenshotIsSmallerThanItsPNG() throws {
        let image = Fixtures.uiScreenshotFlat(1440, 900)
        #expect(image.distinctColors.count <= 256, "it takes the palette path")
        let (webp, png) = try Self.sizesAfterRoundTrip(image)
        #expect(webp < png, "flat ui screenshot 1440x900: WebP \(webp) bytes, PNG \(png) bytes")
        #expect(try webp <= Self.size(image, .none))
    }

    @Test func anAntiAliasedScreenshotIsNoLargerThanWithoutTransforms() throws {
        // Many more colours than the sharp screenshot and the same repeated shapes.
        let soft = Self.blurred(Self.screenshot1440x900)
        let (webp, png) = try Self.sizes(soft)
        let untransformed = try Self.size(soft, .none)
        #expect(webp <= untransformed, "soft ui screenshot: \(webp) bytes, without transforms \(untransformed)")
        #expect(webp < png, "soft ui screenshot: WebP \(webp) bytes, PNG \(png) bytes")
    }

    @Test func aPhotoLikeImageIsNoLargerThanItsPNGAndRecordsTheRatio() throws {
        let image = Fixtures.noise(1440, 900, seed: 1)
        let (webp, png) = try Self.sizesAfterRoundTrip(image)
        Attachment.record("photo-like noise 1440x900: WebP \(webp) bytes, PNG \(png) bytes, ratio \(Double(webp) / Double(png))",
                          named: "noise-vs-png")
        #expect(webp <= png, "photo-like noise 1440x900: WebP \(webp) bytes, PNG \(png) bytes")
    }

    @Test func theTransformsEarnTheirPlace() throws {
        // Few colours: the palette, with its indices bundled, beats the colours written out.
        let flat = Fixtures.uiScreenshotFlat(640, 360)
        #expect(try Self.size(flat, .automatic) < Self.size(flat, .none))
        // Photo-like content is what subtract green and the predictor are for.
        let photo = Fixtures.noise(300, 200, seed: 4)
        let withTransforms = try Self.size(photo, .automatic), without = try Self.size(photo, .none)
        #expect(withTransforms * 10 < without * 7, "photo-like 300x200: \(withTransforms) bytes against \(without)")
        #expect(try Self.size(photo, .subtractGreenAndPredictor) < Self.size(photo, .predictor),
                "the channels move together, so taking the green out of red and blue helps")
    }

    // MARK: A photograph where an estimate would not look

    /// The choice is made on the whole image, so the file is as small as the better of the two forced ways, and it
    /// beats PNG. The automatic file is the one the round trip checks.
    private static func expectTheBetterWayAndSmallerThanPNG(_ image: RGBAImage, _ name: String,
                                                            sourceLocation: SourceLocation = #_sourceLocation) throws {
        let automatic = try RoundTrip.expectRoundTrip(image, sourceLocation: sourceLocation).count
        let untransformed = try size(image, .none), predicted = try size(image, .subtractGreenAndPredictor)
        let png = try PNGReference.data(for: image).count
        Attachment.record("\(name): WebP \(automatic) bytes (no transform \(untransformed), predictor \(predicted)), PNG \(png) bytes",
                          named: name)
        #expect(automatic <= min(untransformed, predicted),
                "\(name): \(automatic) bytes, no transform \(untransformed), predictor \(predicted)")
        #expect(automatic < png, "\(name): WebP \(automatic) bytes, PNG \(png) bytes")
        #expect(predicted < untransformed, "\(name): the photograph is what makes the predictor pay (\(predicted) against \(untransformed))")
    }

    @Test func aBannerPhotographBetweenTheRowsAnEstimateWouldSeeIsFound() throws {
        try Self.expectTheBetterWayAndSmallerThanPNG(Fixtures.uiScreenshotWithPhoto(1200, 800),
                                                     "ui with a banner photograph 1200x800")
    }

    @Test func aTallArticleWithPhotographsIsFound() throws {
        try Self.expectTheBetterWayAndSmallerThanPNG(Fixtures.articleWithPhotos(400, 3200),
                                                     "article with photographs 400x3200")
    }
}
