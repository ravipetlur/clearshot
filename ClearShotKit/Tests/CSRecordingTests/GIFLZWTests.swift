import Foundation
import ImageIO
import Testing
@testable import CSRecording

/// GIF's LZW, with ImageIO as the decoder: every code size, past the 4 096-code reset.
struct GIFLZWTests {
    @Test(arguments: 1...8)
    func imageIODecodesWhatTheLZWWrote(bits: Int) throws {
        let (width, height) = (512, 256)
        let tableSize = 1 << bits
        // Distinct colours for every index, so each decoded pixel names its index.
        let colors = (0..<tableSize).map { UInt32($0) << 16 | UInt32(255 - $0) << 8 | UInt32(($0 * 37) & 0xFF) }
        let palette = GIFPalette(colors: colors, transparentIndex: nil)
        var generator = SeededGenerator(seed: UInt64(bits))
        // Random indices with runs, so codes both repeat and miss.
        var indices: [UInt8] = []
        while indices.count < width * height {
            let index = UInt8(Int.random(in: 0..<tableSize, using: &generator))
            indices += Array(repeating: index, count: min(Int.random(in: 1...4, using: &generator), width * height - indices.count))
        }

        // The stream alone: more than 4 096 codes of at most 12 bits, so the table was reset along the way.
        var lzw = GIFLZW()
        var stream: [UInt8] = []
        indices.withUnsafeBufferPointer { lzw.encode($0, minimumCodeSize: max(2, bits), into: &stream) }
        #expect(stream.count * 8 / 12 > 4096)

        var writer = try GIFWriter(sink: MemorySink(), width: width, height: height, globalPalette: palette)
        try writer.add(GIFDiff(rect: GIFRect(x: 0, y: 0, width: width, height: height),
                               changed: Array(repeating: true, count: width * height)),
                       indices: indices, localPalette: nil, delayCentiseconds: 10)
        let data = Data(try writer.finish().bytes)

        let source = GIFFixtures.source(data)
        #expect(CGImageSourceGetCount(source) == 1)
        let decoded = GIFFixtures.decoded(source, at: 0)
        #expect(decoded.width == width)
        #expect(decoded.height == height)
        let byColor = Dictionary(uniqueKeysWithValues: colors.enumerated().map { ($0.element, UInt8($0.offset)) })
        var mismatches = 0
        for pixel in 0..<(width * height) {
            let rgba = Array(decoded.rgba[(pixel * 4)..<(pixel * 4 + 3)])
            let color = UInt32(rgba[0]) << 16 | UInt32(rgba[1]) << 8 | UInt32(rgba[2])
            if byColor[color] != indices[pixel] { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }

    /// Sub-blocks are at most 255 bytes, each after its length, and the data ends with the terminator.
    @Test func theCodeStreamIsInSubBlocks() {
        var lzw = GIFLZW()
        var stream: [UInt8] = []
        let indices = (0..<5000).map { UInt8(($0 * 7919) % 256) }
        indices.withUnsafeBufferPointer { lzw.encode($0, minimumCodeSize: 8, into: &stream) }
        var offset = 0
        var lengths: [Int] = []
        while stream[offset] != 0 {
            lengths.append(Int(stream[offset]))
            offset += Int(stream[offset]) + 1
        }
        #expect(offset == stream.count - 1)
        #expect(lengths.count > 1)
        // Every sub-block but the last is full.
        #expect(lengths.dropLast().allSatisfy { $0 == 255 })
        #expect((1...255).contains(lengths.last ?? 0))
    }
}
