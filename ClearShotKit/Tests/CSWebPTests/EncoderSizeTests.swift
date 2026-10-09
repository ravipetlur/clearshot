import Foundation
import Testing
@testable import CSWebP

/// How big the files are, against the system's PNG of the same pixels.
struct EncoderSizeTests {
    private static func sizes(_ image: RGBAImage) throws -> (webp: Int, png: Int) {
        let file = try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height)
        return (file.count, try PNGReference.data(for: image).count)
    }

    private static func size(_ image: RGBAImage, _ transforms: WebPLosslessEncoder.Transforms) throws -> Int {
        try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height,
                                       transforms: transforms).count
    }

    @Test func aScreenshotWithAGradientIsNoLargerThanWithoutTransformsAndSmallerThanItsPNG() throws {
        let image = Fixtures.uiScreenshot(1440, 900)
        #expect(image.distinctColors.count > 256, "it is judged for the predictor, which does not pay here")
        let (webp, png) = try Self.sizes(image)
        // The encoder's own no-transform path is the baseline; prediction must not make a screenshot bigger than
        // that.
        let untransformed = try Self.size(image, .none)
        #expect(webp <= untransformed, "ui screenshot 1440x900: \(webp) bytes, without transforms \(untransformed)")
        #expect(webp < png, "ui screenshot 1440x900: WebP \(webp) bytes, PNG \(png) bytes")
        try RoundTrip.expectRoundTrip(image)
    }

    @Test func aFlatScreenshotIsSmallerThanItsPNG() throws {
        let image = Fixtures.uiScreenshotFlat(1440, 900)
        #expect(image.distinctColors.count <= 256, "it takes the palette path")
        let (webp, png) = try Self.sizes(image)
        #expect(webp < png, "flat ui screenshot 1440x900: WebP \(webp) bytes, PNG \(png) bytes")
        #expect(try webp <= Self.size(image, .none))
        try RoundTrip.expectRoundTrip(image)
    }

    @Test func anAntiAliasedScreenshotIsNoLargerThanWithoutTransforms() throws {
        // The text and edges of the screenshot softened by a 3 x 3 average, as anti-aliasing makes them: many more
        // colours and the same repeated shapes.
        let sharp = Fixtures.uiScreenshot(1440, 900)
        var soft = sharp
        for y in 0..<sharp.height {
            for x in 0..<sharp.width {
                var sums = [0, 0, 0], count = 0
                for dy in -1...1 {
                    for dx in -1...1 where (0..<sharp.width).contains(x + dx) && (0..<sharp.height).contains(y + dy) {
                        let pixel = sharp[x + dx, y + dy]
                        sums[0] += Int(pixel.r); sums[1] += Int(pixel.g); sums[2] += Int(pixel.b)
                        count += 1
                    }
                }
                soft[x, y] = Pixel(UInt8(sums[0] / count), UInt8(sums[1] / count), UInt8(sums[2] / count))
            }
        }
        let (webp, png) = try Self.sizes(soft)
        let untransformed = try Self.size(soft, .none)
        #expect(webp <= untransformed, "soft ui screenshot: \(webp) bytes, without transforms \(untransformed)")
        #expect(webp < png, "soft ui screenshot: WebP \(webp) bytes, PNG \(png) bytes")
    }

    @Test func aPhotoLikeImageIsNoLargerThanItsPNGAndRecordsTheRatio() throws {
        let image = Fixtures.noise(1440, 900, seed: 1)
        let (webp, png) = try Self.sizes(image)
        Attachment.record("photo-like noise 1440x900: WebP \(webp) bytes, PNG \(png) bytes, ratio \(Double(webp) / Double(png))",
                          named: "noise-vs-png")
        #expect(webp <= png, "photo-like noise 1440x900: WebP \(webp) bytes, PNG \(png) bytes")
        try RoundTrip.expectRoundTrip(image)
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
    /// beats PNG.
    private static func expectTheBetterWayAndSmallerThanPNG(_ image: RGBAImage, _ name: String) throws {
        let automatic = try size(image, .automatic)
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
        let image = Fixtures.uiScreenshotWithPhoto(1200, 800)
        try Self.expectTheBetterWayAndSmallerThanPNG(image, "ui with a banner photograph 1200x800")
        try RoundTrip.expectRoundTrip(image)
    }

    @Test func aTallArticleWithPhotographsIsFound() throws {
        let image = Fixtures.articleWithPhotos(400, 3200)
        try Self.expectTheBetterWayAndSmallerThanPNG(image, "article with photographs 400x3200")
        try RoundTrip.expectRoundTrip(image)
    }
}
