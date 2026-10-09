import Testing
@testable import CSWebP

/// Every fixture is encoded, decoded by ImageIO and compared with the source under the comparison rule in
/// `RoundTrip.swift`.
struct EncoderRoundTripTests {
    @Test(arguments: Fixtures.catalogue)
    func theDecodedImageMatchesTheSource(_ fixture: Fixture) throws {
        try RoundTrip.expectRoundTrip(fixture.make())
    }

    @Test(arguments: Fixtures.shapes)
    func everyShapeRoundTripsIncludingTheLongestSides(_ fixture: Fixture) throws {
        try RoundTrip.expectRoundTrip(fixture.make())
    }

    @Test func aFullyTransparentImageKeepsItsAlpha() throws {
        let image = Fixtures.allTransparent(33, 17)
        let file = try WebPLosslessEncoder.encode(rgba: image.rgba, width: 33, height: 17)
        let decoded = try RoundTrip.decode(file).image
        #expect(decoded.width == 33 && decoded.height == 17)
        for y in 0..<17 { for x in 0..<33 { #expect(decoded[x, y].a == 0) } }
    }

    @Test func theComparisonNamesTheFirstMismatchingPixel() throws {
        // The helper itself: a corrupted source must be reported at the right pixel with both values.
        var image = Fixtures.noise(8, 4, seed: 3)
        let file = try WebPLosslessEncoder.encode(rgba: image.rgba, width: 8, height: 4)
        let decoded = try RoundTrip.decode(file)
        #expect(RoundTrip.firstMismatch(source: image, decoded: decoded) == nil)
        let original = image[5, 2]
        image[5, 2] = Pixel(original.r &+ 1, original.g, original.b, 255)
        let message = try #require(RoundTrip.firstMismatch(source: image, decoded: decoded))
        #expect(message.contains("(5, 2)"))
        #expect(message.contains("expected \(image[5, 2])"))
        #expect(message.contains("got \(original)"))
    }

    @Test func theComparisonIgnoresTheColourOfInvisiblePixelsButNotTheirAlpha() throws {
        var image = Fixtures.binaryAlpha(12, 12)
        let file = try WebPLosslessEncoder.encode(rgba: image.rgba, width: 12, height: 12)
        let decoded = try RoundTrip.decode(file)
        var invisible: (Int, Int)?
        for y in 0..<12 { for x in 0..<12 where image[x, y].a == 0 { invisible = (x, y) } }
        let (x, y) = try #require(invisible)
        image[x, y] = Pixel(1, 2, 3, 0)
        #expect(RoundTrip.firstMismatch(source: image, decoded: decoded) == nil)
        image[x, y] = Pixel(1, 2, 3, 9)
        #expect(RoundTrip.firstMismatch(source: image, decoded: decoded)?.contains("alpha differs") == true)
    }

    @Test func invisiblePixelsComeBackBlack() throws {
        // The encoder does not keep the colour of a fully transparent pixel; ImageIO returns un-premultiplied pixels,
        // so that is visible in the decoded bytes. The sources here do carry colour at alpha 0.
        for image in [Fixtures.binaryAlpha(40, 30), Fixtures.allTransparent(33, 17)] {
            let invisibleWithColour = image.distinctColors.filter { $0.a == 0 && ($0.r != 0 || $0.g != 0 || $0.b != 0) }
            #expect(!invisibleWithColour.isEmpty, "the source carries colour at alpha 0")
            let file = try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height)
            let decoded = try RoundTrip.decode(file)
            #expect(RoundTrip.firstColouredTransparentPixel(in: decoded) == nil)
            var sawTransparent = false
            for y in 0..<image.height {
                for x in 0..<image.width where decoded.image[x, y].a == 0 {
                    sawTransparent = true
                    #expect(decoded.image[x, y] == Pixel(0, 0, 0, 0), "pixel (\(x), \(y))")
                }
            }
            #expect(sawTransparent)
        }
    }

    @Test func theTransparentColourCheckNamesThePixel() throws {
        // The check itself: a decoded image with colour at alpha 0 is reported at its place.
        var image = RGBAImage(width: 4, height: 3, fill: Pixel(10, 20, 30, 255))
        image[2, 1] = Pixel(0, 0, 0, 0)
        let clean = RoundTrip.Decoded(image: image, premultiplied: false)
        #expect(RoundTrip.firstColouredTransparentPixel(in: clean) == nil)
        image[3, 2] = Pixel(0, 9, 0, 0)
        let dirty = RoundTrip.Decoded(image: image, premultiplied: false)
        #expect(RoundTrip.firstColouredTransparentPixel(in: dirty)?.contains("(3, 2)") == true)
    }
}
