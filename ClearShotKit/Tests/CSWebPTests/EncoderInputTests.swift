import Foundation
import Testing
@testable import CSWebP

struct EncoderInputTests {
    private static func opaque(_ width: Int, _ height: Int) -> [UInt8] {
        [UInt8](repeating: 255, count: width * height * 4)
    }

    private static func le32(_ data: Data, at offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << (8 * $1) }
    }

    // MARK: Dimensions and buffers

    @Test func sidesOutsideOneThrough16383AreRejected() {
        #expect(WebPLosslessEncoder.maxSide == 16383)
        #expect(throws: WebPEncodeError.invalidDimensions(width: 0, height: 1)) {
            try WebPLosslessEncoder.encode(rgba: [], width: 0, height: 1)
        }
        #expect(throws: WebPEncodeError.invalidDimensions(width: 1, height: 0)) {
            try WebPLosslessEncoder.encode(rgba: [], width: 1, height: 0)
        }
        // 16 384 fits the format's 14-bit fields, but macOS can't open it, so the encoder doesn't write it.
        #expect(throws: WebPEncodeError.invalidDimensions(width: 16384, height: 1)) {
            try WebPLosslessEncoder.encode(rgba: Self.opaque(16384, 1), width: 16384, height: 1)
        }
        #expect(throws: WebPEncodeError.invalidDimensions(width: 1, height: 16384)) {
            try WebPLosslessEncoder.encode(rgba: Self.opaque(1, 16384), width: 1, height: 16384)
        }
        #expect(throws: WebPEncodeError.invalidDimensions(width: 16385, height: 1)) {
            try WebPLosslessEncoder.encode(rgba: Self.opaque(16385, 1), width: 16385, height: 1)
        }
        #expect(throws: WebPEncodeError.invalidDimensions(width: 1, height: 16385)) {
            try WebPLosslessEncoder.encode(rgba: Self.opaque(1, 16385), width: 1, height: 16385)
        }
        #expect(throws: WebPEncodeError.invalidDimensions(width: -3, height: 2)) {
            try WebPLosslessEncoder.encode(rgba: Self.opaque(1, 2), width: -3, height: 2)
        }
    }

    @Test func aBufferOfTheWrongLengthIsRejected() {
        let right = Self.opaque(4, 3)
        #expect(throws: WebPEncodeError.bufferSizeMismatch(expected: 48, actual: 47)) {
            try WebPLosslessEncoder.encode(rgba: Array(right.dropLast()), width: 4, height: 3)
        }
        #expect(throws: WebPEncodeError.bufferSizeMismatch(expected: 48, actual: 49)) {
            try WebPLosslessEncoder.encode(rgba: right + [0], width: 4, height: 3)
        }
        #expect(throws: WebPEncodeError.bufferSizeMismatch(expected: 48, actual: 0)) {
            try WebPLosslessEncoder.encode(rgba: [], width: 4, height: 3)
        }
    }

    @Test func theLongestSidesEncodeAndRoundTrip() throws {
        // 16 383 is the encoder's limit and the longest side ImageIO decodes.
        try RoundTrip.expectRoundTrip(RGBAImage(width: 16383, height: 1, fill: Pixel(10, 20, 30)))
        try RoundTrip.expectRoundTrip(RGBAImage(width: 1, height: 16383, fill: Pixel(10, 20, 30, 77)))
        try RoundTrip.expectRoundTrip(Fixtures.noise(16383, 1, seed: 1))
        try RoundTrip.expectRoundTrip(Fixtures.noise(1, 16383, seed: 2))
        try RoundTrip.expectRoundTrip(Fixtures.alphaGradient(16383, 2))
    }

    // MARK: The VP8L header

    /// The header's 32 bits after the signature byte: width - 1 (14 bits), height - 1 (14), alpha_is_used (1) and the
    /// version (3), least-significant bit first.
    private struct Header {
        var signature: UInt8
        var width: Int
        var height: Int
        var alphaIsUsed: Int
        var version: Int

        init(_ file: Data) {
            signature = file[file.startIndex + 20]
            let word = EncoderInputTests.le32(file, at: 21)
            width = (word & 0x3FFF) + 1
            height = ((word >> 14) & 0x3FFF) + 1
            alphaIsUsed = (word >> 28) & 1
            version = word >> 29
        }
    }

    @Test func theHeaderCarriesTheSignatureSizeAndVersion() throws {
        let file = try WebPLosslessEncoder.encode(rgba: Self.opaque(300, 17), width: 300, height: 17)
        let header = Header(file)
        #expect(header.signature == 0x2F)
        #expect(header.width == 300 && header.height == 17)
        #expect(header.version == 0)
        let big = Header(try WebPLosslessEncoder.encode(rgba: Self.opaque(16383, 1), width: 16383, height: 1))
        #expect(big.width == 16383 && big.height == 1)
    }

    @Test func alphaIsUsedIsZeroForOpaqueImagesAndOneOtherwise() throws {
        func hint(_ rgba: [UInt8], _ width: Int, _ height: Int) throws -> Int {
            Header(try WebPLosslessEncoder.encode(rgba: rgba, width: width, height: height)).alphaIsUsed
        }
        #expect(try hint(Self.opaque(5, 5), 5, 5) == 0)
        let noise = Fixtures.noise(20, 20, seed: 1)
        #expect(try hint(noise.rgba, 20, 20) == 0)

        // One pixel at alpha 254 is enough.
        var almost = Self.opaque(5, 5)
        almost[3 * 4 + 3] = 254
        #expect(try hint(almost, 5, 5) == 1)

        // One fully transparent pixel, and an image of nothing else.
        var hole = Self.opaque(5, 5)
        hole[24 * 4 + 3] = 0
        #expect(try hint(hole, 5, 5) == 1)
        let transparent = Fixtures.allTransparent(5, 5)
        #expect(try hint(transparent.rgba, 5, 5) == 1)
        let gradient = Fixtures.alphaGradient(40, 4)
        #expect(try hint(gradient.rgba, 40, 4) == 1)
    }

    // MARK: The container

    @Test func theContainerSizesAreConsistent() throws {
        var sawOddChunk = false, sawEvenChunk = false
        for (width, height) in [(1, 1), (1, 2), (2, 1), (3, 3), (5, 2), (7, 7), (16, 9), (33, 17), (100, 3)] {
            let image = Fixtures.noise(width, height, seed: UInt64(width * 100 + height))
            let file = try WebPLosslessEncoder.encode(rgba: image.rgba, width: width, height: height)
            let name = "\(width)x\(height)"

            #expect(Array(file[0..<4]) == Array("RIFF".utf8), Comment(rawValue: name))
            #expect(Array(file[8..<12]) == Array("WEBP".utf8), Comment(rawValue: name))
            #expect(Array(file[12..<16]) == Array("VP8L".utf8), Comment(rawValue: name))
            // The RIFF size counts everything after its own field.
            #expect(Self.le32(file, at: 4) == file.count - 8, Comment(rawValue: name))
            // The chunk size is the payload alone: no header, no pad byte.
            let chunkSize = Self.le32(file, at: 16)
            let padded = chunkSize + (chunkSize & 1)
            #expect(file.count == 20 + padded, Comment(rawValue: name))
            #expect(file.count % 2 == 0, Comment(rawValue: name))
            if chunkSize & 1 == 1 {
                sawOddChunk = true
                #expect(file[file.count - 1] == 0, "the pad byte is zero")
            } else {
                sawEvenChunk = true
            }
        }
        #expect(sawOddChunk && sawEvenChunk, "the sizes above cover both an odd and an even payload")
    }
}
