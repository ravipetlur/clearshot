import Testing
@testable import CSWebP

/// `Symbol` is the unit a whole image is held in while it is being coded: one per pixel at worst, so its size is the
/// size of the encoder's working memory. A photo-sized capture is some 15 million of them.
struct SymbolTests {
    typealias Symbol = EntropyImageWriter.Symbol

    @Test func aSymbolIsEightBytes() {
        #expect(MemoryLayout<Symbol>.size == 8)
        #expect(MemoryLayout<Symbol>.stride == 8)
    }

    @Test(arguments: [0, 1, 0x0000_00FF, 0x8000_0000, 0xFF20_4060, 0xFFFF_FFFF] as [UInt32])
    func aLiteralKeepsEveryBitOfItsColour(_ argb: UInt32) {
        let symbol = Symbol.literal(argb)
        guard case .literal(let back) = symbol.form else {
            Issue.record("a literal reads back as \(symbol.form)")
            return
        }
        #expect(back == argb)
    }

    @Test(arguments: [0, 1, 63, 1024, 2047])
    func aCacheIndexKeepsItsValue(_ index: Int) {
        guard case .cacheIndex(let back) = Symbol.cacheIndex(index).form else {
            Issue.record("a cache index reads back as something else")
            return
        }
        #expect(back == index)
    }

    @Test(arguments: [(1, 1), (1, 120), (1, 121), (3, 40), (4095, 7), (4096, 1_048_576), (2, 1_048_576), (4096, 1)])
    func aBackReferenceKeepsItsLengthAndDistanceCode(_ length: Int, _ code: Int) {
        guard case .backref(let backLength, let backCode) = Symbol.backref(length: length, distanceCode: code).form else {
            Issue.record("a back-reference reads back as something else")
            return
        }
        #expect(backLength == length)
        #expect(backCode == code)
    }

    @Test func theThreeKindsNeverCompareEqual() {
        // The same number in three roles: only the same role with the same value is the same symbol.
        let symbols = [Symbol.literal(5), .cacheIndex(5), .backref(length: 5, distanceCode: 5), .literal(6),
                       .cacheIndex(6), .backref(length: 5, distanceCode: 6), .backref(length: 6, distanceCode: 5)]
        for (a, left) in symbols.enumerated() {
            for (b, right) in symbols.enumerated() { #expect((left == right) == (a == b), "\(a) and \(b)") }
        }
    }

    @Test func aLiteralWithTheTopBitsSetIsStillALiteral() {
        // The kind is not stored in the colour's own bits: alpha 0xFF, and 0xC0 in the top byte, are plain colours.
        for argb: UInt32 in [0xFF00_0000, 0xC000_0000, 0x8000_0000, 0x4000_0000] {
            guard case .literal(let back) = Symbol.literal(argb).form else {
                Issue.record("\(argb) did not stay a literal")
                continue
            }
            #expect(back == argb)
        }
    }

    @Test func theSymbolsOfAFindHoldNoMoreMemoryThanTheyUse() {
        // A stream of a few million symbols must not reserve more than it needs: one slot per symbol, give or take
        // what the allocator rounds up.
        let pixels = Fixtures.uiScreenshot(300, 200).argbPixels
        let matches = BackwardReferences.findMatches(pixels: pixels, width: 300)
        for bits in [0, 6] {
            let symbols = BackwardReferences.symbols(pixels: pixels, width: 300, matches: matches, cacheBits: bits)
            #expect(symbols.capacity >= symbols.count)
            #expect(symbols.capacity <= symbols.count + symbols.count / 50 + 64,
                    "\(symbols.count) symbols in a capacity of \(symbols.capacity)")
        }
    }
}
