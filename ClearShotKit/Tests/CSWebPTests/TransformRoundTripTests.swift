import Foundation
import Testing
@testable import CSWebP

/// The transforms through ImageIO, the one independent decoder: every transform alone and together, on every kind of
/// image, and what the encoder chooses by itself.
struct TransformRoundTripTests {
    typealias Transforms = WebPLosslessEncoder.Transforms

    private static func choices(for image: RGBAImage) -> [Transforms] {
        var list: [Transforms] = [.none, .subtractGreen, .predictor, .subtractGreenAndPredictor]
        if PaletteTransform(pixels: image.argbPixels) != nil { list.append(.palette) }
        return list
    }

    @Test(arguments: Fixtures.catalogue)
    func everyTransformChoiceRoundTripsEveryFixture(_ fixture: Fixture) throws {
        let image = fixture.make()
        for choice in Self.choices(for: image) { try RoundTrip.expectRoundTrip(image, transforms: choice) }
    }

    @Test(arguments: Fixtures.shapes)
    func theLongestAndSmallestShapesRoundTripThroughThePredictorAndThePalette(_ fixture: Fixture) throws {
        let image = fixture.make()
        try RoundTrip.expectRoundTrip(image, transforms: .subtractGreenAndPredictor)
        if PaletteTransform(pixels: image.argbPixels) != nil { try RoundTrip.expectRoundTrip(image, transforms: .palette) }
    }

    @Test(arguments: [0, 1, 4, 8])
    func theTransformsAndAColourCacheOfAnySizeGoTogether(_ bits: Int) throws {
        for image in [Fixtures.uiScreenshot(160, 90), Fixtures.noise(70, 40, seed: 3), Fixtures.palette(17, 40, 30),
                      Fixtures.palette(3, 40, 30), Fixtures.alphaGradient(70, 12)] {
            for choice in Self.choices(for: image) {
                try RoundTrip.expectRoundTrip(image, coding: .backReferences(cacheBits: bits), transforms: choice)
            }
        }
    }

    @Test func literalsOnlyAfterTheTransformsRoundTrips() throws {
        for image in [Fixtures.uiScreenshot(100, 60), Fixtures.palette(5, 20, 20), Fixtures.noise(33, 33, seed: 1)] {
            for choice in Self.choices(for: image) { try RoundTrip.expectRoundTrip(image, coding: .literalsOnly, transforms: choice) }
        }
    }

    // MARK: What the encoder chooses

    private static func listedTransforms(_ image: RGBAImage) throws -> [Int] {
        let file = try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height)
        return StreamPeek.firstTransforms(of: file)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 16, 17, 256])
    func anImageOfAtMost256ColoursTakesThePaletteAlone(_ count: Int) throws {
        let image = Fixtures.palette(count, 40, 30)
        let file = try RoundTrip.expectRoundTrip(image)
        #expect(StreamPeek.firstTransforms(of: file) == [3], "\(count) colours")
        #expect(StreamPeek.paletteColorCount(of: file) == count)
    }

    @Test func moreThan256ColoursTakeSubtractGreenAndThenThePredictorWherePredictionPays() throws {
        // Type 2 is subtract green and type 0 the predictor; the stream lists them in that order, once each. Smooth
        // content, photo-like or gradient, is predicted.
        #expect(try Self.listedTransforms(Fixtures.noise(100, 80, seed: 1)) == [2, 0])
        #expect(try Self.listedTransforms(Fixtures.noise(300, 200, seed: 4)) == [2, 0])
        #expect(try Self.listedTransforms(Fixtures.alphaGradient(256, 64)) == [2, 0])
    }

    @Test func contentThatPredictionDoesNotShrinkIsLeftAsItIs() throws {
        // Hard-edged flat content with repeated shapes is matched better as it is; so is random noise, where
        // prediction has nothing to model. No transform is listed at all.
        #expect(try Self.listedTransforms(Fixtures.palette(257, 40, 30)) == [])
        #expect(try Self.listedTransforms(Fixtures.randomNoise(100, 80, seed: 1)) == [])
        #expect(try Self.listedTransforms(Fixtures.uiScreenshot(640, 360)) == [])
    }

    @Test(arguments: Fixtures.catalogue + Fixtures.shapes)
    func theEncodersChoiceIsTheSmallerOfTheTwoWaysAndNoTransformOnATie(_ fixture: Fixture) throws {
        // The choice is made on the whole image with the real costs, and the winner is written as it is: so the file
        // is byte for byte the no-transform file or the subtract-green-and-predictor file, whichever is smaller, and
        // the no-transform one on a tie. (An image of at most 256 colours takes the palette, which is not a choice.)
        let image = fixture.make()
        guard PaletteTransform(pixels: image.argbPixels) == nil else { return }
        func file(_ transforms: Transforms) throws -> Data {
            try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height,
                                           transforms: transforms)
        }
        let none = try file(.none), predicted = try file(.subtractGreenAndPredictor)
        let automatic = try file(.automatic)
        #expect(automatic == (predicted.count < none.count ? predicted : none), "\(fixture.name)")
    }

    @Test func theFlatScreenshotAndABinaryAlphaImageHaveFewColoursAndTakeThePalette() throws {
        #expect(try Self.listedTransforms(Fixtures.uiScreenshotFlat(640, 360)) == [3])
        // Invisible pixels are one colour once their colour is zeroed, so this one has few.
        var image = RGBAImage(width: 30, height: 20, fill: Pixel(10, 20, 30))
        for y in 0..<20 { for x in 0..<30 where (x * y) % 4 == 0 { image[x, y] = Pixel(UInt8(x * 7), UInt8(y), 9, 0) } }
        #expect(try Self.listedTransforms(image) == [3])
    }

    @Test func aSmallNoisyImageHasFewEnoughPixelsToTakeThePalette() throws {
        // 256 pixels or fewer can never have more than 256 colours.
        #expect(try Self.listedTransforms(Fixtures.randomNoise(16, 16, seed: 3)) == [3])
        #expect(try Self.listedTransforms(Fixtures.randomNoise(1, 1, seed: 3)) == [3])
        // One pixel more and it has more than 256 colours; random noise has nothing to predict, so it is left alone.
        #expect(try Self.listedTransforms(Fixtures.randomNoise(17, 16, seed: 3)) == [])
    }

    @Test(arguments: [Transforms.none, .subtractGreen, .predictor, .subtractGreenAndPredictor, .palette])
    func eachTransformIsListedOnceAndInTheOrderTheyAreApplied(_ choice: Transforms) throws {
        let image = Fixtures.palette(9, 30, 20)
        let file = try RoundTrip.expectRoundTrip(image, transforms: choice)
        let expected: [Int] = switch choice {
        case .none: []
        case .subtractGreen: [2]
        case .predictor: [0]
        case .subtractGreenAndPredictor: [2, 0]
        case .palette: [3]
        case .automatic: [3]
        }
        #expect(StreamPeek.firstTransforms(of: file) == expected)
    }

    @Test func theAlphaHintFollowsTheOriginalPixelsWhateverTheTransform() throws {
        func hint(_ image: RGBAImage) throws -> Int {
            StreamPeek.bit(try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height), 36)
        }
        #expect(try hint(Fixtures.palette(1, 5, 5)) == 0)  // one opaque colour (palette 1 is opaque)
        #expect(try hint(Fixtures.palette(5, 20, 20)) == 1)  // translucent colours
        #expect(try hint(Fixtures.allTransparent(10, 10)) == 1)
        #expect(try hint(Fixtures.uiScreenshot(300, 200)) == 0)  // predictor path, opaque
        #expect(try hint(Fixtures.alphaGradient(100, 10)) == 1)  // predictor path, translucent
        #expect(try hint(Fixtures.noise(40, 40, seed: 1)) == 0)
    }

    @Test func aTranslucentPaletteKeepsItsAlphaAndItsColours() throws {
        let image = Fixtures.palette(40, 50, 50)
        #expect(image.distinctColors.contains { $0.a < 255 })
        try RoundTrip.expectRoundTrip(image)
    }
}
