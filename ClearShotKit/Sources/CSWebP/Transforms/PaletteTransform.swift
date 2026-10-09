/// The colour indexing transform (RFC 9649, section 3.5.4), for an image of at most 256 colours: a table of the colours,
/// and an image of indices into it.
///
/// The table is ordered by how often a colour is used, the most used first (colours used equally often by their ARGB
/// value, lowest first, so the order depends on the pixels and not on how they were found). A small index is cheap to
/// write, and the commonest colours, which are most of the pixels, get the smallest.
///
/// The index goes in the green channel of a pixel whose alpha is 255 and whose red and blue are 0. With 16 colours or
/// fewer, several indices are bundled into one pixel, which makes the image narrower and lets the prefix code see
/// neighbouring indices together; the first index sits in the lowest bits.
struct PaletteTransform {
    /// The most colours a palette holds: an index is one byte.
    static let maxColors = 256

    /// The colours in table order, each at its index.
    let colors: [UInt32]

    /// The colour of each index, by `lookup`: an open-addressing hash from a colour to its index.
    private static let slotCount = 1024
    private let slotColors: [UInt32]
    private let slotIndices: [Int16]

    // MARK: Bundling

    /// How many bits the width is shifted down by, from Table 3: 3 for 1 or 2 colours (eight indices to a pixel), 2 for
    /// 3 or 4, 1 for 5 to 16, 0 above.
    static func widthBits(forColorCount count: Int) -> Int {
        count <= 2 ? 3 : count <= 4 ? 2 : count <= 16 ? 1 : 0
    }

    /// The width of the image after bundling: `width` divided by the bundle size, rounded up.
    static func packedWidth(forWidth width: Int, widthBits: Int) -> Int {
        (width + (1 << widthBits) - 1) >> widthBits
    }

    var widthBits: Int { Self.widthBits(forColorCount: colors.count) }

    // MARK: Making a palette

    /// A palette of exactly these colours, in this order: 1 to 256 different ones.
    init?(colors: [UInt32]) {
        guard (1...Self.maxColors).contains(colors.count) else { return nil }
        self.colors = colors
        var slotColors = [UInt32](repeating: 0, count: Self.slotCount)
        var slotIndices = [Int16](repeating: -1, count: Self.slotCount)
        for (index, color) in colors.enumerated() {
            var slot = Self.slot(of: color, mask: Self.slotCount - 1)
            while slotIndices[slot] >= 0 {
                precondition(slotColors[slot] != color, "a palette's colours are all different")
                slot = (slot + 1) & (Self.slotCount - 1)
            }
            slotColors[slot] = color
            slotIndices[slot] = Int16(index)
        }
        self.slotColors = slotColors
        self.slotIndices = slotIndices
    }

    /// The palette of an image's pixels, most used colour first, or nil when the pixels have more than 256 colours.
    init?(pixels: [UInt32]) {
        let slotCount = Self.slotCount  // a quarter full at most
        var keys = [UInt32](repeating: 0, count: slotCount)
        var counts = [Int](repeating: 0, count: slotCount)  // 0: the slot is free
        var distinct = 0
        let fits = pixels.withUnsafeBufferPointer { buffer -> Bool in
            var previous: UInt32 = 0, previousSlot = -1
            for pixel in buffer {
                // A run of one colour is counted without looking it up again.
                if previousSlot >= 0, pixel == previous {
                    counts[previousSlot] += 1
                    continue
                }
                var slot = Self.slot(of: pixel, mask: slotCount - 1)
                while counts[slot] != 0, keys[slot] != pixel { slot = (slot + 1) & (slotCount - 1) }
                if counts[slot] == 0 {
                    if distinct == Self.maxColors { return false }
                    keys[slot] = pixel
                    distinct += 1
                }
                counts[slot] += 1
                previous = pixel
                previousSlot = slot
            }
            return true
        }
        guard fits, distinct > 0 else { return nil }
        let used = (0..<slotCount).filter { counts[$0] != 0 }
        let ordered = used.sorted { counts[$0] != counts[$1] ? counts[$0] > counts[$1] : keys[$0] < keys[$1] }
        self.init(colors: ordered.map { keys[$0] })
    }

    @inline(__always)
    private static func slot(of color: UInt32, mask: Int) -> Int {
        Int((color &* 0x9E37_79B1) >> 22) & mask
    }

    // MARK: The table as written

    /// Each colour less the one before it, per channel, modulo 256 (the first less nothing): the colour table is
    /// stored this way because the steps carry much less entropy than the colours do.
    static func subtractionCoded(_ colors: [UInt32]) -> [UInt32] {
        var previous: UInt32 = 0
        return colors.map { color in
            defer { previous = color }
            var step: UInt32 = 0
            for shift in stride(from: 0, to: 32, by: 8) {
                step |= (((color >> UInt32(shift)) &- (previous >> UInt32(shift))) & 0xFF) << UInt32(shift)
            }
            return step
        }
    }

    var subtractionCodedColors: [UInt32] { Self.subtractionCoded(colors) }

    // MARK: The index image

    /// The index of `color` in the table. The colour has to be in it.
    @inline(__always)
    func index(of color: UInt32) -> Int {
        var slot = Self.slot(of: color, mask: Self.slotCount - 1)
        while true {
            let index = slotIndices[slot]
            precondition(index >= 0, "the colour \(color) is not in the palette")
            if slotColors[slot] == color { return Int(index) }
            slot = (slot + 1) & (Self.slotCount - 1)
        }
    }

    /// The pixels of an image of `width` x `height` as indices into the table, bundled: one pixel per `1 << widthBits`
    /// across, the rows packed apart, so that a row of width 17 with two colours is 3 pixels wide.
    func packed(pixels: [UInt32], width: Int, height: Int) -> [UInt32] {
        precondition(pixels.count == width * height)
        let bits = widthBits
        let packedWidth = Self.packedWidth(forWidth: width, widthBits: bits)
        let bitsPerIndex = 8 >> bits
        let slotMask = (1 << bits) - 1
        var out = [UInt32](repeating: 0xFF00_0000, count: packedWidth * height)
        pixels.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                var previous: UInt32 = 0, previousIndex = -1
                for y in 0..<height {
                    for x in 0..<width {
                        let color = source[y * width + x]
                        if previousIndex < 0 || color != previous {
                            previousIndex = index(of: color)
                            previous = color
                        }
                        let shift = UInt32(8 + bitsPerIndex * (x & slotMask))
                        target[y * packedWidth + (x >> bits)] |= UInt32(previousIndex) << shift
                    }
                }
            }
        }
        return out
    }
}
