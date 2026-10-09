import Foundation
import Testing
@testable import CSWebP

/// The files with back-references and the colour cache, through ImageIO (the one independent decoder), and what the
/// two buy in size.
struct BackReferenceRoundTripTests {
    /// Small images that between them use runs, repeats, a few colours, many colours, translucency and the narrowest
    /// widths: the ones a cache of any size and any distance code can go wrong on.
    private static let sampler: [Fixture] = [
        Fixture("ui 160x90") { Fixtures.uiScreenshot(160, 90) },
        Fixture("noise 40x30") { Fixtures.noise(40, 30, seed: 4) },
        Fixture("random noise 40x30") { Fixtures.randomNoise(40, 30, seed: 4) },
        Fixture("alpha gradient 70x12") { Fixtures.alphaGradient(70, 12) },
        Fixture("binary alpha 50x40") { Fixtures.binaryAlpha(50, 40) },
        Fixture("all transparent 33x17") { Fixtures.allTransparent(33, 17) },
        Fixture("palette 17 40x30") { Fixtures.palette(17, 40, 30) },
        Fixture("palette 257 40x30") { Fixtures.palette(257, 40, 30) },
        Fixture("runs 100x80") { Fixtures.runs(100, 80) },
        Fixture("tiles 1x60") { Fixtures.repeatedTiles(1, 60) },
        Fixture("tiles 2x60") { Fixtures.repeatedTiles(2, 60) },
        Fixture("tiles 3x60") { Fixtures.repeatedTiles(3, 60) },
        Fixture("tiles 8x60") { Fixtures.repeatedTiles(8, 60) },
        Fixture("tiles 120x60") { Fixtures.repeatedTiles(120, 60) },
        Fixture("1x1 transparent") { Fixtures.allTransparent(1, 1) },
        Fixture("1x1 opaque") { Fixtures.noise(1, 1, seed: 2) },
    ]

    @Test(arguments: 1...11)
    func everyCacheSizeRoundTripsThroughImageIO(_ bits: Int) throws {
        for fixture in Self.sampler {
            try RoundTrip.expectRoundTrip(fixture.make(), coding: .backReferences(cacheBits: bits))
        }
    }

    @Test func noCacheRoundTripsThroughImageIO() throws {
        for fixture in Self.sampler {
            try RoundTrip.expectRoundTrip(fixture.make(), coding: .backReferences(cacheBits: 0))
        }
    }

    @Test func theLiteralsOnlyPathStillRoundTrips() throws {
        for fixture in Self.sampler { try RoundTrip.expectRoundTrip(fixture.make(), coding: .literalsOnly) }
    }

    @Test func theDefaultEncodeUsesBackReferencesAndTheCache() throws {
        let image = Fixtures.uiScreenshot(300, 200)
        let byDefault = try WebPLosslessEncoder.encode(rgba: image.rgba, width: 300, height: 200)
        let chosen = try WebPLosslessEncoder.encode(rgba: image.rgba, width: 300, height: 200,
                                                    coding: .backReferences(cacheBits: nil), transforms: .automatic)
        #expect(byDefault == chosen)
        let literals = try WebPLosslessEncoder.encode(rgba: image.rgba, width: 300, height: 200, coding: .literalsOnly)
        #expect(byDefault.count < literals.count)
    }

    // MARK: Transparent black and the cache's initial state

    @Test func aTransparentBlackPixelIsRightWhenTheCacheStartsOutHoldingIt() throws {
        // Colour 0 is in every slot 0 of a new cache, so a pixel of it can be sent as an index before it was ever
        // written; ImageIO must read that the way the RFC says.
        var image = Fixtures.noise(30, 4, seed: 9)
        for x in stride(from: 0, to: 30, by: 3) { image[x, 0] = Pixel(0, 0, 0, 0) }
        for bits in [1, 4, 11] { try RoundTrip.expectRoundTrip(image, coding: .backReferences(cacheBits: bits)) }
        let transparent = Fixtures.allTransparent(33, 17)
        for bits in [1, 4, 11] { try RoundTrip.expectRoundTrip(transparent, coding: .backReferences(cacheBits: bits)) }
    }

    // MARK: The largest distance code

    @Test func theLargestDistanceCodeRoundTripsThroughImageIO() throws {
        // 1024 x 1100 noise with a block repeated exactly the largest distance apart: a reference with code 1 048 576
        // (prefix 39, 18 extra bits), which has to be read back as the same pixels.
        let width = 1024, height = 1100
        var image = Fixtures.randomNoise(width, height, seed: 31)
        let start = 100, far = start + DistanceCodes.maxDistance
        for offset in 0..<40 {
            let source = start + offset, target = far + offset
            image[target % width, target / width] = image[source % width, source / width]
        }
        let pixels = image.argbPixels
        let symbols = BackwardReferences.find(pixels: pixels, width: width, cacheBits: 0)
        #expect(symbols.contains(.backref(length: 40, distanceCode: 1_048_576)))
        try RoundTrip.expectRoundTrip(image)
    }

    @Test func aReferenceFarAcrossARealImageRoundTrips() throws {
        // The same screenshot twice, 600 rows apart, with white between: the second is one long run of far references.
        let screenshot = Fixtures.uiScreenshot(900, 300)
        var tall = RGBAImage(width: 900, height: 900, fill: Pixel(255, 255, 255))
        for y in 0..<300 {
            for x in 0..<900 {
                tall[x, y] = screenshot[x, y]
                tall[x, y + 600] = screenshot[x, y]
            }
        }
        try RoundTrip.expectRoundTrip(tall)
    }

    // MARK: Size

    /// The size of the file with `coding` and no transform: these tests are about what references and the cache buy.
    private static func fileSize(_ image: RGBAImage, _ coding: WebPLosslessEncoder.PixelCoding) throws -> Int {
        try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height, coding: coding,
                                       transforms: .none).count
    }

    @Test func runsAreAtLeastFiveTimesSmallerThanLiteralsOnly() throws {
        let image = Fixtures.runs(300, 200)
        let literals = try Self.fileSize(image, .literalsOnly)
        let packed = try Self.fileSize(image, .backReferences(cacheBits: nil))
        #expect(packed * 5 <= literals, "runs: \(literals) bytes as literals, \(packed) with references")
        try RoundTrip.expectRoundTrip(image)
    }

    @Test func repeatedTilesAreAtLeastFiveTimesSmallerThanLiteralsOnly() throws {
        let image = Fixtures.repeatedTiles(400, 300)
        let literals = try Self.fileSize(image, .literalsOnly)
        let packed = try Self.fileSize(image, .backReferences(cacheBits: nil))
        #expect(packed * 5 <= literals, "tiles: \(literals) bytes as literals, \(packed) with references")
        try RoundTrip.expectRoundTrip(image)
    }

    @Test func theScreenshotShrinksAndNoiseDoesNotGrow() throws {
        let screenshot = Fixtures.uiScreenshot(640, 360)
        let screenshotLiterals = try Self.fileSize(screenshot, .literalsOnly)
        let screenshotPacked = try Self.fileSize(screenshot, .backReferences(cacheBits: nil))
        #expect(screenshotPacked < screenshotLiterals)

        // Noise has nothing to refer back to and no colour twice: the cache stays off, and the cost of looking is a
        // handful of bytes at most, in the length of the code descriptions.
        let noise = Fixtures.randomNoise(200, 150, seed: 6)
        let noiseLiterals = try Self.fileSize(noise, .literalsOnly)
        let noisePacked = try Self.fileSize(noise, .backReferences(cacheBits: nil))
        #expect(noisePacked <= noiseLiterals + noiseLiterals / 100,
                "noise 200x150: \(noiseLiterals) bytes as literals, \(noisePacked) with references")
    }
}
