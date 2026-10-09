import Testing
@testable import CSWebP

/// The subtract-green transform (RFC 9649, section 3.5.3): the encoder takes the green from the red and the blue of
/// each pixel, modulo 256; the decoder adds it back.
struct SubtractGreenTests {
    @Test func aPixelLosesItsGreenFromRedAndBlueModulo256() {
        // Red 0x10 less green 0x80 is 0x90; blue 0x30 less 0x80 is 0xB0; alpha and green stay.
        #expect(SubtractGreenTransform.apply(0xFF10_8030) == 0xFF90_80B0)
        // No green, no change.
        #expect(SubtractGreenTransform.apply(0x7F12_0034) == 0x7F12_0034)
        // Green 0xFF: red 0 becomes 1 (0 - 255 mod 256), blue 0xFF becomes 0.
        #expect(SubtractGreenTransform.apply(0xFF00_FFFF) == 0xFF01_FF00)
        // Red equal to green goes to zero, and so does blue.
        #expect(SubtractGreenTransform.apply(0x0042_4242) == 0x0000_4200)
    }

    @Test func everyRedGreenAndBlueIsRightAndAlphaAndGreenAreKept() {
        for green in 0..<256 {
            for value in 0..<256 {
                let pixel = UInt32(0xA5) << 24 | UInt32(value) << 16 | UInt32(green) << 8 | UInt32((value * 7) & 255)
                let out = SubtractGreenTransform.apply(pixel)
                #expect(out >> 24 == 0xA5)
                #expect((out >> 8) & 0xFF == UInt32(green))
                #expect((out >> 16) & 0xFF == UInt32((value - green) & 255))
                #expect(out & 0xFF == UInt32(((value * 7) - green) & 255))
            }
        }
    }

    static let images: [Fixture] = [
        Fixture("noise") { Fixtures.noise(60, 40, seed: 1) }, Fixture("random") { Fixtures.randomNoise(60, 40, seed: 2) },
        Fixture("ui") { Fixtures.uiScreenshot(200, 120) }, Fixture("alpha") { Fixtures.alphaGradient(70, 20) },
    ]

    @Test(arguments: images)
    func theDecodersAdditionUndoesIt(_ fixture: Fixture) {
        let original = fixture.make().argbPixels
        var pixels = original
        SubtractGreenTransform.apply(to: &pixels)
        #expect(pixels != original, "\(fixture.name): something changed")
        #expect(TransformModels.inverseSubtractGreen(pixels) == original, "\(fixture.name)")
    }

    @Test func applyToAnArrayIsApplyToEachPixel() {
        let original = Fixtures.noise(30, 30, seed: 4).argbPixels
        var pixels = original
        SubtractGreenTransform.apply(to: &pixels)
        #expect(pixels == original.map(SubtractGreenTransform.apply))
    }
}
