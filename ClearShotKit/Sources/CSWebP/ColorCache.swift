/// The colour cache of a WebP lossless stream (RFC 9649, section 3.6.2.3): a table of `1 << bits` colours, the recently
/// used ones, each kept at the slot its hash names. A pixel that is in the cache can be written as that slot's index,
/// a symbol of the green code, instead of as four channels.
///
/// The cache has to be exactly the decoder's. A decoder starts with every slot 0 and inserts every pixel it produces,
/// in order: pixels it reads as literals, pixels it copies for a back-reference (each one, as it copies it), and
/// pixels it reads from the cache. The encoder runs the same cache over the same pixels, so that a slot means the same
/// colour to both when an index is written. There is no conflict resolution: a colour that hashes to a taken slot
/// replaces what was there.
struct ColorCache {
    /// The most bits the format allows (the cache then has 2048 slots); the fewest is 1.
    static let maxBits = 11

    let bits: Int
    private var table: [UInt32]

    /// A cache of `1 << bits` slots, all 0.
    init(bits: Int) {
        precondition((1...Self.maxBits).contains(bits), "a colour cache has 1 to \(Self.maxBits) bits")
        self.bits = bits
        table = [UInt32](repeating: 0, count: 1 << bits)
    }

    var size: Int { table.count }

    /// The slot for a colour: `(0x1e35a7bd * argb) >> (32 - bits)`, on 32-bit values (the product wraps).
    static func hash(_ argb: UInt32, bits: Int) -> Int {
        Int((0x1e35_a7bd &* argb) >> UInt32(32 - bits))
    }

    /// The index to write for `argb`, when the cache holds it at its slot; nil when the slot holds something else.
    func lookup(_ argb: UInt32) -> Int? {
        let slot = Self.hash(argb, bits: bits)
        return table[slot] == argb ? slot : nil
    }

    /// What a decoder reads for `index`.
    func color(at index: Int) -> UInt32 {
        table[index]
    }

    /// Puts `argb` into its slot, replacing the colour there.
    mutating func insert(_ argb: UInt32) {
        table[Self.hash(argb, bits: bits)] = argb
    }
}
