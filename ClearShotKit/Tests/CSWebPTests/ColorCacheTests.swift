import Testing
@testable import CSWebP

struct ColorCacheTests {
    // MARK: The hash

    @Test func theHashMatchesValuesWorkedOutByHand() {
        // (0x1e35a7bd * color) mod 2^32, then the top `bits` bits.
        //   color 0x00000001: product 0x1e35a7bd = 0001 1110 0011 0101 ...   top 4 bits 0001, top 10 bits 0001111000
        //   color 0xff102030: product 0x1dd71370 = 0001 1101 1101 0111 ...   top 4 bits 0001, top 10 bits 0001110111
        //   color 0x80ff0000: product 0x95430000 = 1001 0101 0100 0011 ...   top 4 bits 1001, top 10 bits 1001010101
        let cases: [(color: UInt32, atFourBits: Int, atTenBits: Int)] = [
            (0x0000_0001, 0b0001, 0b00_0111_1000),
            (0xFF10_2030, 0b0001, 0b00_0111_0111),
            (0x80FF_0000, 0b1001, 0b10_0101_0101),
        ]
        for entry in cases {
            #expect(ColorCache.hash(entry.color, bits: 4) == entry.atFourBits, "color \(entry.color) at 4 bits")
            #expect(ColorCache.hash(entry.color, bits: 10) == entry.atTenBits, "color \(entry.color) at 10 bits")
        }
        #expect(ColorCache.hash(0, bits: 7) == 0)
    }

    @Test func theHashWrapsAt32Bits() {
        // 0xffffffff * 0x1e35a7bd mod 2^32 is 0xe1ca5843 (the multiplier's two's complement).
        #expect(ColorCache.hash(0xFFFF_FFFF, bits: 4) == 0xE)
        #expect(ColorCache.hash(0xFFFF_FFFF, bits: 10) == 0b11_1000_0111)
    }

    @Test(arguments: 1...11)
    func theHashAgreesWithTheRFCExpressionAndStaysInRange(_ bits: Int) {
        var rng = SeededGenerator(seed: UInt64(bits))
        for _ in 0..<2000 {
            let color = UInt32.random(in: 0...UInt32.max, using: &rng)
            let index = ColorCache.hash(color, bits: bits)
            #expect(index == SpecTables.cacheIndex(color, bits: bits))
            #expect(index >= 0 && index < 1 << bits)
        }
    }

    // MARK: The state

    @Test func aNewCacheHoldsZeroInEverySlot() {
        let cache = ColorCache(bits: 4)
        #expect(cache.size == 16)
        for index in 0..<16 { #expect(cache.color(at: index) == 0) }
        // The all-zero colour hashes to slot 0 and is found there before anything is inserted: the RFC initialises
        // every entry to zero.
        #expect(cache.lookup(0) == 0)
        #expect(cache.lookup(0x1234_5678) == nil)
    }

    @Test func aColourIsFoundAtItsSlotOnceInserted() throws {
        var cache = ColorCache(bits: 6)
        let color: UInt32 = 0xFF33_66CC
        #expect(cache.lookup(color) == nil)
        cache.insert(color)
        let index = try #require(cache.lookup(color))
        #expect(index == ColorCache.hash(color, bits: 6))
        #expect(cache.color(at: index) == color)
    }

    @Test func aLaterColourInTheSameSlotReplacesTheEarlierOne() {
        var cache = ColorCache(bits: 2)
        // Find two colours that share a slot.
        let first: UInt32 = 0xFF00_0001
        let slot = ColorCache.hash(first, bits: 2)
        let second = (0xFF00_0002...0xFF00_1388).first { ColorCache.hash($0, bits: 2) == slot } ?? first
        #expect(second != first)
        cache.insert(first)
        #expect(cache.lookup(first) != nil)
        cache.insert(second)
        #expect(cache.lookup(second) != nil)
        #expect(cache.lookup(first) == nil, "there is no conflict resolution: one slot, one colour")
    }

    @Test func theSizeIsTwoToTheBits() {
        for bits in 1...11 { #expect(ColorCache(bits: bits).size == 1 << bits) }
    }

    // MARK: Against a decoder model

    @Test(arguments: [1, 2, 4, 6, 8, 10, 11])
    func insertAndLookupMatchADecoderModelReplayingTheSameSymbols(_ bits: Int) {
        // A stream with plenty of repeats and collisions: drawn from a small palette, so every colour recurs.
        var rng = SeededGenerator(seed: UInt64(100 + bits))
        let palette = (0..<40).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) } + [0]
        var cache = ColorCache(bits: bits)
        var model = [UInt32](repeating: 0, count: 1 << bits)
        var hits = 0
        for step in 0..<6000 {
            let color = palette[Int.random(in: 0..<palette.count, using: &rng)]
            // The encoder asks the cache; the model says what a decoder would hold in the slot.
            let slot = SpecTables.cacheIndex(color, bits: bits)
            let modelHit = model[slot] == color
            let index = cache.lookup(color)
            #expect((index != nil) == modelHit, "step \(step)")
            if let index {
                hits += 1
                #expect(index == slot, "step \(step)")
                // What the decoder reads for that index is the colour.
                #expect(model[index] == color && cache.color(at: index) == color, "step \(step)")
            }
            cache.insert(color)
            model[slot] = color
        }
        #expect(hits > 0)
        for slot in 0..<(1 << bits) { #expect(cache.color(at: slot) == model[slot]) }
    }
}
