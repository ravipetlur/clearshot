import Testing
@testable import CSRecording

/// The palette: at most 255 colours plus the transparent index, exact when an image has fewer.
struct GIFQuantizerTests {
    func fullDiff(_ frame: GIFFrame) -> GIFDiff {
        GIFDiff(rect: GIFRect(x: 0, y: 0, width: frame.width, height: frame.height),
                changed: Array(repeating: true, count: frame.width * frame.height))
    }

    @Test func atMost255ColoursPlusTransparent() {
        var generator = SeededGenerator(seed: 11)
        let noise = GIFFixtures.frame(width: 64, height: 64) { _, _ in UInt32.random(in: 0...0xFF_FFFF, using: &generator) }
        let palette = GIFQuantizer.palette(from: [noise], colors: 255)
        #expect(palette.colors.count == 255)
        #expect(palette.transparentIndex == 255)
        let indices = GIFQuantizer.indices(for: noise, diff: fullDiff(noise), palette: palette, dither: false)
        #expect(indices.count == 64 * 64)
        #expect(indices.allSatisfy { $0 < 255 })
        // Asked for fewer, it gives no more.
        let small = GIFQuantizer.palette(from: [noise], colors: 64)
        #expect(small.colors.count == 64)
        #expect(small.transparentIndex == 64)
        // The tests' scene, which has more than 255 colours.
        let scene = GIFQuantizer.palette(from: [GIFFixtures.scene(0)], colors: 255)
        #expect(scene.colors.count <= 255)
        #expect(scene.transparentIndex == scene.colors.count)
    }

    /// An exact palette's order is fixed: by how much each cell holds, ties by colour, a cell's second colour after
    /// them; never the order a `Set` happens to iterate in, so the same frames always make the same bytes.
    @Test func exactPalettesAreInAFixedOrder() {
        // A and B tie, and their cells come in the other order from their colours; D shares C's cell.
        let (a, b, c, d): (UInt32, UInt32, UInt32, UInt32) = (0x11_0000, 0x10_4000, 0x80_8080, 0x81_8080)
        let frame = GIFFixtures.frame(width: 40, height: 30) { _, y in [c, a, b, d][y / 8 % 4] }
        let palette = GIFQuantizer.palette(from: [frame], colors: 255)
        #expect(palette.colors == [c, b, a, d])
    }

    /// 16 colours (two of them one level apart) round-trip losslessly.
    @Test func fewerColoursThanThePaletteAreKeptExactly() {
        var colors: [UInt32] = (0..<14).map { (index: Int) -> UInt32 in
            let red = UInt32(index * 18) << 16
            let green = UInt32(255 - index * 18) << 8
            return red | green | UInt32(index * 7)
        }
        colors += [0x64_6464, 0x65_6464]
        let frame = GIFFixtures.frame(width: 40, height: 40) { x, y in colors[(x / 3 + y * 7) % 16] }
        let palette = GIFQuantizer.palette(from: [frame], colors: 255)
        #expect(Set(palette.colors) == Set(colors))
        #expect(palette.transparentIndex == 16)
        let indices = GIFQuantizer.indices(for: frame, diff: fullDiff(frame), palette: palette, dither: true)
        for y in 0..<40 {
            for x in 0..<40 {
                #expect(palette.colors[Int(indices[y * 40 + x])] == frame.color(x: x, y: y))
            }
        }
    }
}
