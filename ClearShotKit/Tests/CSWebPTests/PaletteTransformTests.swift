import Foundation
import Testing
@testable import CSWebP

/// The colour indexing transform (RFC 9649, section 3.5.4): the colour table, its subtraction coding, and the bundling
/// of several indices into one pixel.
struct PaletteTransformTests {
    // MARK: Bundling

    @Test func theBundledWidthFollowsTable3() {
        for count in 1...256 {
            let expected = count <= 2 ? 3 : count <= 4 ? 2 : count <= 16 ? 1 : 0
            #expect(PaletteTransform.widthBits(forColorCount: count) == expected, "\(count) colours")
        }
        // The colour counts at each edge of a bundle width, once more by name.
        #expect([1, 2, 3, 4, 5, 16, 17, 256].map(PaletteTransform.widthBits(forColorCount:)) == [3, 3, 2, 2, 1, 1, 0, 0])
    }

    @Test func thePackedWidthIsTheWidthDividedByTheBundleRoundedUp() {
        // Width 17 with 2 colours: eight to a pixel, so 3 pixels (8 + 8 + 1).
        #expect(PaletteTransform.packedWidth(forWidth: 17, widthBits: 3) == 3)
        #expect(PaletteTransform.packedWidth(forWidth: 16, widthBits: 3) == 2)
        #expect(PaletteTransform.packedWidth(forWidth: 1, widthBits: 3) == 1)
        #expect(PaletteTransform.packedWidth(forWidth: 17, widthBits: 2) == 5)
        #expect(PaletteTransform.packedWidth(forWidth: 17, widthBits: 1) == 9)
        #expect(PaletteTransform.packedWidth(forWidth: 17, widthBits: 0) == 17)
        #expect(PaletteTransform.packedWidth(forWidth: 16383, widthBits: 3) == 2048)
        for widthBits in 0...3 {
            for width in 1...70 {
                let bundle = 1 << widthBits
                #expect(PaletteTransform.packedWidth(forWidth: width, widthBits: widthBits) == (width + bundle - 1) / bundle)
            }
        }
    }

    // MARK: The colours and their order

    @Test func moreThan256ColoursMakeNoPalette() {
        #expect(PaletteTransform(pixels: Fixtures.palette(257, 40, 30).argbPixels) == nil)
        #expect(PaletteTransform(pixels: Fixtures.noise(40, 40, seed: 1).argbPixels) == nil)
        let image = Fixtures.palette(256, 40, 30)
        #expect(PaletteTransform(pixels: image.argbPixels)?.colors.count == 256)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 16, 17, 256])
    func thePaletteHoldsExactlyTheImagesColours(_ count: Int) throws {
        let pixels = Fixtures.palette(count, 40, 30).argbPixels
        let palette = try #require(PaletteTransform(pixels: pixels))
        #expect(palette.colors.count == count)
        #expect(Set(palette.colors) == Set(pixels))
        #expect(Set(palette.colors).count == count, "no colour twice")
        #expect(palette.widthBits == PaletteTransform.widthBits(forColorCount: count))
    }

    @Test func theMostUsedColourComesFirstAndTiesGoByColourValue() throws {
        // 0xFF000003 x5, 0xFF000001 x3, 0xFF000009 x3, 0xFF000002 x1.
        let pixels: [UInt32] = [3, 1, 9, 3, 2, 9, 3, 1, 3, 9, 1, 3].map { 0xFF00_0000 | $0 }
        let palette = try #require(PaletteTransform(pixels: pixels))
        #expect(palette.colors == [0xFF00_0003, 0xFF00_0001, 0xFF00_0009, 0xFF00_0002])
    }

    @Test func theOrderIsTheSameWhateverOrderThePixelsAreIn() throws {
        var pixels = Fixtures.palette(40, 50, 40).argbPixels
        let first = try #require(PaletteTransform(pixels: pixels))
        var rng = SeededGenerator(seed: 3)
        pixels.shuffle(using: &rng)
        let shuffled = try #require(PaletteTransform(pixels: pixels))
        #expect(first.colors == shuffled.colors)
    }

    @Test func theInvisibleColourIsOneColour() throws {
        // The encoder zeroes the colour of a fully transparent pixel before anything else, so all of them are one
        // palette entry, whatever colour they were given.
        var image = RGBAImage(width: 20, height: 10, fill: Pixel(10, 20, 30))
        for y in 0..<10 { for x in 0..<20 where (x + y) % 3 == 0 { image[x, y] = Pixel(UInt8(x), UInt8(y), 7, 0) } }
        let palette = try #require(PaletteTransform(pixels: image.argbPixels))
        #expect(palette.colors.count == 2)
        #expect(palette.colors.filter { $0 >> 24 == 0 } == [0])
    }

    // MARK: The colour table is subtraction-coded

    @Test func theTableIsEachColourLessTheOneBeforeChannelByChannel() {
        let colors: [UInt32] = [0xFF10_2030, 0x80FF_0000, 0x0000_0000, 0xFF10_2030]
        // 0x80FF0000 - 0xFF102030: alpha 0x81, red 0xEF, green 0xE0, blue 0xD0; 0 - 0x80FF0000: 0x80, 0x01, 0, 0;
        // 0xFF102030 - 0.
        let expected: [UInt32] = [0xFF10_2030, 0x81EF_E0D0, 0x8001_0000, 0xFF10_2030]
        #expect(PaletteTransform.subtractionCoded(colors) == expected)
        #expect(PaletteTransform.subtractionCoded([]) == [])
        #expect(PaletteTransform.subtractionCoded([0xAABB_CCDD]) == [0xAABB_CCDD])
    }

    @Test func theDecodersAdditionRecoversTheColours() {
        for count in [1, 2, 3, 5, 17, 256] {
            let colors = Array(Set(Fixtures.palette(count, 40, 30).argbPixels))
            #expect(TransformModels.undoSubtractionCoding(PaletteTransform.subtractionCoded(colors)) == colors, "\(count)")
        }
    }

    // MARK: Packing

    @Test func eightTwoColourIndicesShareAPixelFirstInTheLowestBit() throws {
        // Colours 0xFF000000 and 0xFFFFFFFF, equally common; indices 1, 0, 1, 1, 0, 1, 0, 0 then 1.
        let a: UInt32 = 0xFF00_0000, b: UInt32 = 0xFFFF_FFFF
        let bits = [1, 0, 1, 1, 0, 1, 0, 0, 1]
        let pixels = bits.map { $0 == 0 ? a : b }
        let palette = try #require(PaletteTransform(colors: [a, b]))
        let packed = palette.packed(pixels: pixels, width: 9, height: 1)
        // 1 + 4 + 8 + 32 = 0b00101101 = 0x2D in the first pixel; the ninth index alone in the second.
        #expect(packed == [0xFF00_2D00, 0xFF00_0100])
    }

    @Test func fourFourColourIndicesShareAPixelTwoBitsEach() throws {
        let colors: [UInt32] = [0xFF00_0001, 0xFF00_0002, 0xFF00_0003, 0xFF00_0004]
        let palette = try #require(PaletteTransform(colors: colors))
        // Indices 3, 0, 2, 1 then 1: 3 | 0 << 2 | 2 << 4 | 1 << 6 = 0x63, and 1.
        let pixels = [3, 0, 2, 1, 1].map { colors[$0] }
        #expect(palette.packed(pixels: pixels, width: 5, height: 1) == [0xFF00_6300, 0xFF00_0100])
    }

    @Test func twoSixteenColourIndicesShareAPixelFourBitsEach() throws {
        let colors: [UInt32] = (0..<16).map { 0xFF00_0000 | UInt32($0) }
        let palette = try #require(PaletteTransform(colors: colors))
        // Indices 15, 2, 7: 15 | 2 << 4 = 0x2F, and 7.
        let pixels = [15, 2, 7].map { colors[$0] }
        #expect(palette.packed(pixels: pixels, width: 3, height: 1) == [0xFF00_2F00, 0xFF00_0700])
    }

    @Test func aTableOfMoreThan16ColoursPutsEachIndexInItsOwnPixel() throws {
        let colors: [UInt32] = (0..<40).map { 0xFF00_0000 | UInt32($0) }
        let palette = try #require(PaletteTransform(colors: colors))
        let pixels = [39, 0, 17, 17].map { colors[$0] }
        #expect(palette.packed(pixels: pixels, width: 4, height: 1) == [0xFF00_2700, 0xFF00_0000, 0xFF00_1100, 0xFF00_1100])
    }

    @Test func eachRowIsPackedOnItsOwn() throws {
        // Width 3, two to a pixel: a row's last pixel holds one index, and the next row starts a new pixel.
        let colors: [UInt32] = (0..<5).map { 0xFF00_0000 | UInt32($0) }
        let palette = try #require(PaletteTransform(colors: colors))
        let indices = [[1, 2, 3], [4, 0, 1]]
        let pixels = indices.flatMap { $0 }.map { colors[$0] }
        let packed = palette.packed(pixels: pixels, width: 3, height: 2)
        #expect(packed == [0xFF00_2100, 0xFF00_0300, 0xFF00_0400, 0xFF00_0100])
        #expect(packed.count == PaletteTransform.packedWidth(forWidth: 3, widthBits: 1) * 2)
    }

    @Test func everyPackedPixelIsOpaqueWithNoRedOrBlue() throws {
        for count in [2, 4, 16, 200] {
            let image = Fixtures.palette(count, 41, 13)
            let palette = try #require(PaletteTransform(pixels: image.argbPixels))
            for pixel in palette.packed(pixels: image.argbPixels, width: 41, height: 13) {
                #expect(pixel & 0xFF00_00FF == 0xFF00_0000, "\(count) colours")
            }
        }
    }

    @Test(arguments: [(1, 1), (1, 9), (9, 1), (7, 5), (17, 3), (40, 30), (33, 33), (257, 2)])
    func packingThenTheDecodersUnpackingIsTheIdentity(_ size: (Int, Int)) throws {
        let (width, height) = size
        for count in [1, 2, 3, 4, 5, 16, 17, 256] where count <= width * height {
            let image = Fixtures.palette(count, width, height)
            let pixels = image.argbPixels
            let palette = try #require(PaletteTransform(pixels: pixels))
            let packed = palette.packed(pixels: pixels, width: width, height: height)
            let table = TransformModels.undoSubtractionCoding(palette.subtractionCodedColors)
            #expect(table == palette.colors)
            let back = TransformModels.unpackPalette(packed: packed, width: width, height: height,
                                                     widthBits: palette.widthBits, colors: table)
            #expect(back == pixels, "\(count) colours, \(width)x\(height)")
        }
    }

    @Test func aPaletteFromChosenColoursKeepsTheirOrder() throws {
        // Colours not in the image are allowed (a decoder maps by index only); the order given is the table.
        let palette = try #require(PaletteTransform(colors: [5, 4, 3]))
        #expect(palette.colors == [5, 4, 3])
        #expect(PaletteTransform(colors: []) == nil)
        #expect(PaletteTransform(colors: Array(repeating: 1, count: 257)) == nil)
    }
}
