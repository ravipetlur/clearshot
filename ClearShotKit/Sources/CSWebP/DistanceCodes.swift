/// The 2-D distance codes of a WebP lossless stream (RFC 9649, section 3.6.2.2.1), and the prefix coding that lengths
/// and distance codes go through (section 3.6.2.2).
///
/// A back-reference names its source by a distance *code*. A code above 120 is the plain distance, in pixels along the
/// scan line, plus 120. The first 120 codes stand for the pixels in a small neighbourhood above and to the side of the
/// current pixel, each by an offset `(xi, yi)`: `xi` pixels to the left (negative: to the right) in the row `yi` above.
/// A decoder turns the offset into a scan-line distance by `xi + yi * width`, never less than 1.
enum DistanceCodes {
    /// The largest distance code, the last of prefix code 39 with its 18 extra bits: 1 048 576 (RFC 9649, Table 4).
    static let maxCode = 1_048_576
    /// The largest distance a reference can have: the largest code, less the 120 the plain codes are offset by.
    static let maxDistance = maxCode - 120

    /// The neighbourhood offsets `(xi, yi)` of the codes 1 to 120, in the RFC's order (Figure 20); entry `n` is the
    /// offset of code `n + 1`.
    static let neighbourhood: [(x: Int, y: Int)] = [
        (x: 0, y: 1), (x: 1, y: 0), (x: 1, y: 1), (x: -1, y: 1),
        (x: 0, y: 2), (x: 2, y: 0), (x: 1, y: 2), (x: -1, y: 2),
        (x: 2, y: 1), (x: -2, y: 1), (x: 2, y: 2), (x: -2, y: 2),
        (x: 0, y: 3), (x: 3, y: 0), (x: 1, y: 3), (x: -1, y: 3),
        (x: 3, y: 1), (x: -3, y: 1), (x: 2, y: 3), (x: -2, y: 3),
        (x: 3, y: 2), (x: -3, y: 2), (x: 0, y: 4), (x: 4, y: 0),
        (x: 1, y: 4), (x: -1, y: 4), (x: 4, y: 1), (x: -4, y: 1),
        (x: 3, y: 3), (x: -3, y: 3), (x: 2, y: 4), (x: -2, y: 4),
        (x: 4, y: 2), (x: -4, y: 2), (x: 0, y: 5), (x: 3, y: 4),
        (x: -3, y: 4), (x: 4, y: 3), (x: -4, y: 3), (x: 5, y: 0),
        (x: 1, y: 5), (x: -1, y: 5), (x: 5, y: 1), (x: -5, y: 1),
        (x: 2, y: 5), (x: -2, y: 5), (x: 5, y: 2), (x: -5, y: 2),
        (x: 4, y: 4), (x: -4, y: 4), (x: 3, y: 5), (x: -3, y: 5),
        (x: 5, y: 3), (x: -5, y: 3), (x: 0, y: 6), (x: 6, y: 0),
        (x: 1, y: 6), (x: -1, y: 6), (x: 6, y: 1), (x: -6, y: 1),
        (x: 2, y: 6), (x: -2, y: 6), (x: 6, y: 2), (x: -6, y: 2),
        (x: 4, y: 5), (x: -4, y: 5), (x: 5, y: 4), (x: -5, y: 4),
        (x: 3, y: 6), (x: -3, y: 6), (x: 6, y: 3), (x: -6, y: 3),
        (x: 0, y: 7), (x: 7, y: 0), (x: 1, y: 7), (x: -1, y: 7),
        (x: 5, y: 5), (x: -5, y: 5), (x: 7, y: 1), (x: -7, y: 1),
        (x: 4, y: 6), (x: -4, y: 6), (x: 6, y: 4), (x: -6, y: 4),
        (x: 2, y: 7), (x: -2, y: 7), (x: 7, y: 2), (x: -7, y: 2),
        (x: 3, y: 7), (x: -3, y: 7), (x: 7, y: 3), (x: -7, y: 3),
        (x: 5, y: 6), (x: -5, y: 6), (x: 6, y: 5), (x: -6, y: 5),
        (x: 8, y: 0), (x: 4, y: 7), (x: -4, y: 7), (x: 7, y: 4),
        (x: -7, y: 4), (x: 8, y: 1), (x: 8, y: 2), (x: 6, y: 6),
        (x: -6, y: 6), (x: 8, y: 3), (x: 5, y: 7), (x: -5, y: 7),
        (x: 7, y: 5), (x: -7, y: 5), (x: 8, y: 4), (x: 6, y: 7),
        (x: -6, y: 7), (x: 7, y: 6), (x: -7, y: 6), (x: 8, y: 5),
        (x: 7, y: 7), (x: -7, y: 7), (x: 8, y: 6), (x: 8, y: 7),
    ]

    /// For each offset `(xi, yi)`, its code: `planeCode[yi * 16 + xi + 7]`, or 0 where the neighbourhood has no such
    /// offset. `xi` runs from -7 to 8 and `yi` from 0 to 7.
    private static let planeCode: [Int] = {
        var table = [Int](repeating: 0, count: 8 * 16)
        for (index, offset) in neighbourhood.enumerated() { table[offset.y * 16 + offset.x + 7] = index + 1 }
        return table
    }()

    /// The scan-line distance code `code` stands for in an image `width` pixels wide.
    static func distance(forCode code: Int, width: Int) -> Int {
        precondition((1...maxCode).contains(code), "distance codes run from 1 to \(maxCode)")
        if code > 120 { return code - 120 }
        let offset = neighbourhood[code - 1]
        return max(1, offset.x + offset.y * width)
    }

    /// The distance code to write for a reference `distance` pixels back in an image `width` pixels wide: the lowest
    /// code in 1...120 that a decoder turns into exactly `distance`, or else `distance + 120`. Narrow images make
    /// several codes land on one distance (and the clamp to 1 makes several land on 1); the lowest is the one with the
    /// shortest prefix and fewest extra bits, and picking the same one every time keeps the code's histogram tight.
    static func code(forDistance distance: Int, width: Int) -> Int {
        precondition(distance >= 1 && distance <= maxDistance, "a distance is 1 to \(maxDistance)")
        var best = distance + 120
        // Row `yi` above holds the distance when xi = distance - yi * width falls in that row's range.
        for row in 0...7 {
            let xi = distance - row * width
            if xi < -7 { break }
            if xi <= 8 {
                let code = planeCode[row * 16 + xi + 7]
                if code != 0, code < best { best = code }
            }
        }
        // Nothing more is needed for a distance of 1: code 2, the offset (1, 0), decodes to exactly 1 at every width (and
        // at width 1 code 1 does), so the loop above has found a code of 2 or less; the codes that the clamp turns into
        // 1 for a narrow image are all 4 or more.
        return best
    }
}

/// LZ77 prefix coding (RFC 9649, section 3.6.2.2, Table 4): a value is stored as a prefix code, which is entropy coded,
/// and some extra bits, which are not.
enum PrefixCoding {
    /// The prefix code, the number of extra bits and the extra bits' value for `value`, which is at least 1. It
    /// inverts the RFC's reading: below 5, `value - 1` is the prefix and there are no extra bits; above, with
    /// `d = value - 1` and `h` the position of its highest set bit, the prefix is `2h` plus the bit below the highest,
    /// there are `h - 1` extra bits, and they are the bits of `d` under the top two.
    static func encode(value: Int) -> (prefix: Int, extraBits: Int, extraValue: Int) {
        precondition(value >= 1, "values start at 1")
        let d = value - 1
        if d < 4 { return (prefix: d, extraBits: 0, extraValue: 0) }
        let highest = Int.bitWidth - 1 - d.leadingZeroBitCount
        let extraBits = highest - 1
        let belowHighest = (d >> extraBits) & 1
        return (prefix: 2 * highest + belowHighest, extraBits: extraBits, extraValue: d & ((1 << extraBits) - 1))
    }
}
