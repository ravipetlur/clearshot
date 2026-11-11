import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// The two main colors of a pixel selection and their contrast.
struct SelectionContrastTests {
    private func sampler(_ width: Int, _ height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> PixelSampler {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let index = (y * width + x) * 4
                bytes[index] = r; bytes[index + 1] = g; bytes[index + 2] = b
            }
        }
        return PixelSampler(width: width, height: height, premultipliedRGBA: bytes)!
    }

    @Test func blackOnWhiteIsTwentyOneToOne() throws {
        // A little black "text" on white: 10% of the pixels.
        let picture = sampler(20, 20) { _, y in y < 2 ? (0, 0, 0) : (255, 255, 255) }
        let contrast = try #require(SelectionContrast(in: picture.bounds, of: picture))
        #expect(contrast.background == .white)
        #expect(contrast.foreground == RGBAColor(red: 0, green: 0, blue: 0))
        #expect(abs(contrast.ratio - 21) < 0.001)
        #expect(contrast.ratioText == "21:1")
        #expect(contrast.level == .aaa)
        #expect(contrast.apca > 100)
        #expect(contrast.apcaText.hasPrefix("Lc 10"))
    }

    @Test func theLargerAreaIsTheBackgroundWhateverItsLightness() throws {
        // White text on a black panel: the black is the background, and APCA reads light on dark (negative).
        let picture = sampler(20, 20) { _, y in y < 2 ? (255, 255, 255) : (0, 0, 0) }
        let contrast = try #require(SelectionContrast(in: picture.bounds, of: picture))
        #expect(contrast.background == RGBAColor(red: 0, green: 0, blue: 0))
        #expect(contrast.foreground == .white)
        #expect(contrast.apca < 0)
        #expect(abs(contrast.ratio - 21) < 0.001)
    }

    @Test func aTieMakesTheLighterTheBackground() throws {
        let picture = sampler(10, 10) { x, _ in x < 5 ? (0, 0, 0) : (255, 255, 255) }
        let contrast = try #require(SelectionContrast(in: picture.bounds, of: picture))
        #expect(contrast.background == .white)
        #expect(contrast.apca > 0)
    }

    @Test func aUniformAreaHasNoContrast() {
        let picture = sampler(10, 10) { _, _ in (40, 80, 120) }
        #expect(SelectionContrast(in: picture.bounds, of: picture) == nil)
    }

    @Test func nearbyShadesAreOneColor() {
        // Neighbouring shades of one grey (a gradient step, or compression noise) are not a second color.
        let picture = sampler(10, 10) { x, y in
            let shade = UInt8(200 + (x + y) % 3)
            return (shade, shade, shade)
        }
        #expect(SelectionContrast(in: picture.bounds, of: picture) == nil)
    }

    @Test func aSpeckBelowHalfAPercentIsIgnored() {
        let picture = sampler(100, 100) { x, y in x == 0 && y == 0 ? (0, 0, 0) : (255, 255, 255) }
        #expect(SelectionContrast(in: picture.bounds, of: picture) == nil)
    }

    @Test func readsOnlyTheSelectedArea() {
        let picture = sampler(20, 10) { x, _ in x < 10 ? (255, 255, 255) : (0, 0, 0) }
        #expect(SelectionContrast(in: CGRect(x: 0, y: 0, width: 10, height: 10), of: picture) == nil)
        #expect(SelectionContrast(in: CGRect(x: 5, y: 0, width: 10, height: 10), of: picture) != nil)
        #expect(SelectionContrast(in: CGRect(x: 100, y: 100, width: 5, height: 5), of: picture) == nil)
    }

    @Test func transparentPixelsAreLeftOut() {
        // White opaque pixels, and the first half transparent black: only the white ones count, so it is uniform.
        var bytes = [UInt8](repeating: 255, count: 4 * 4 * 4)
        for i in stride(from: 0, to: bytes.count / 2, by: 4) { bytes[i] = 0; bytes[i + 1] = 0; bytes[i + 2] = 0; bytes[i + 3] = 0 }
        let picture = PixelSampler(width: 4, height: 4, premultipliedRGBA: bytes)!
        #expect(SelectionContrast(in: picture.bounds, of: picture) == nil)
    }

    @Test func levelsFollowTheThresholds() {
        #expect(SelectionContrast.Level(ratio: 7) == .aaa)
        #expect(SelectionContrast.Level(ratio: 6.99) == .aa)
        #expect(SelectionContrast.Level(ratio: 4.5) == .aa)
        #expect(SelectionContrast.Level(ratio: 4.49) == .aaLarge)
        #expect(SelectionContrast.Level(ratio: 3) == .aaLarge)
        #expect(SelectionContrast.Level(ratio: 2.99) == .fail)
        #expect(!SelectionContrast.Level.fail.passes)
    }

    @Test func theRatioIsCutNotRounded() throws {
        // Grey 118 on white is about 4.5:1: whatever side of the line it falls, the text and the level agree.
        let picture = sampler(20, 20) { _, y in y < 2 ? (118, 118, 118) : (255, 255, 255) }
        let contrast = try #require(SelectionContrast(in: picture.bounds, of: picture))
        let shown = Double(contrast.ratioText.dropLast(2))!
        #expect(shown <= contrast.ratio)
        #expect((shown >= 4.5) == contrast.level.passes || contrast.level == .aaLarge)
        #expect(contrast.level == .aaLarge ? shown < 4.5 : shown >= 4.5)
    }

    @Test func aLargeAreaIsSampled() throws {
        let picture = sampler(2500, 1000) { x, _ in x < 1000 ? (0, 0, 0) : (255, 255, 255) }
        let contrast = try #require(SelectionContrast(in: picture.bounds, of: picture))
        #expect(contrast.background == .white)
        #expect(abs(contrast.ratio - 21) < 0.001)
    }
}
