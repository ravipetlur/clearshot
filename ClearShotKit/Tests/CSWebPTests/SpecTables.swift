import Foundation

/// Tables and rules of the lossless format, held here as the RFC states them so that the unit tests do not lean on
/// the encoder's own copies. The decoder model in `SymbolReplay.swift` and the tests of `DistanceCodes`, `PrefixCoding`
/// and `ColorCache` all read from this file.
enum SpecTables {
    /// RFC 9649, section 3.6.2.2.1, Figure 20, as printed: the neighbouring-pixel offset (xi, yi) of each distance
    /// code from 1 to 120, in code order. Kept as text and parsed, so a transcription slip shows up as a count or
    /// structure failure rather than being copied into two places.
    static let figure20 = """
    (0, 1),  (1, 0),  (1, 1),  (-1, 1), (0, 2),  (2, 0),  (1, 2),
    (-1, 2), (2, 1),  (-2, 1), (2, 2),  (-2, 2), (0, 3),  (3, 0),
    (1, 3),  (-1, 3), (3, 1),  (-3, 1), (2, 3),  (-2, 3), (3, 2),
    (-3, 2), (0, 4),  (4, 0),  (1, 4),  (-1, 4), (4, 1),  (-4, 1),
    (3, 3),  (-3, 3), (2, 4),  (-2, 4), (4, 2),  (-4, 2), (0, 5),
    (3, 4),  (-3, 4), (4, 3),  (-4, 3), (5, 0),  (1, 5),  (-1, 5),
    (5, 1),  (-5, 1), (2, 5),  (-2, 5), (5, 2),  (-5, 2), (4, 4),
    (-4, 4), (3, 5),  (-3, 5), (5, 3),  (-5, 3), (0, 6),  (6, 0),
    (1, 6),  (-1, 6), (6, 1),  (-6, 1), (2, 6),  (-2, 6), (6, 2),
    (-6, 2), (4, 5),  (-4, 5), (5, 4),  (-5, 4), (3, 6),  (-3, 6),
    (6, 3),  (-6, 3), (0, 7),  (7, 0),  (1, 7),  (-1, 7), (5, 5),
    (-5, 5), (7, 1),  (-7, 1), (4, 6),  (-4, 6), (6, 4),  (-6, 4),
    (2, 7),  (-2, 7), (7, 2),  (-7, 2), (3, 7),  (-3, 7), (7, 3),
    (-7, 3), (5, 6),  (-5, 6), (6, 5),  (-6, 5), (8, 0),  (4, 7),
    (-4, 7), (7, 4),  (-7, 4), (8, 1),  (8, 2),  (6, 6),  (-6, 6),
    (8, 3),  (5, 7),  (-5, 7), (7, 5),  (-7, 5), (8, 4),  (6, 7),
    (-6, 7), (7, 6),  (-7, 6), (8, 5),  (7, 7),  (-7, 7), (8, 6),
    (8, 7)
    """

    /// The 120 offsets of `figure20`, code 1 first.
    static let distanceMap: [(x: Int, y: Int)] = {
        var offsets: [(x: Int, y: Int)] = []
        var rest = Substring(figure20)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let parts = rest[rest.index(after: open)..<close].split(separator: ",")
            offsets.append((x: Int(parts[0].trimmingCharacters(in: .whitespaces))!,
                            y: Int(parts[1].trimmingCharacters(in: .whitespaces))!))
            rest = rest[rest.index(after: close)...]
        }
        return offsets
    }()

    /// The scan-line distance a distance code stands for (RFC 9649, sections 3.6.2.2 and 3.6.2.2.1): above 120 the
    /// distance plus 120, otherwise the map entry's `xi + yi * width`, never less than 1.
    static func distance(forCode code: Int, width: Int) -> Int {
        if code > 120 { return code - 120 }
        let (xi, yi) = distanceMap[code - 1]
        return max(1, xi + yi * width)
    }

    /// The value for an LZ77 prefix code and its extra bits (RFC 9649, section 3.6.2.2, the pseudocode after Table 4).
    static func lz77Value(prefix: Int, extraValue: Int) -> Int {
        if prefix < 4 { return prefix + 1 }
        let extraBits = (prefix - 2) >> 1
        let offset = (2 + (prefix & 1)) << extraBits
        return offset + extraValue + 1
    }

    /// The colour cache's slot for a colour (RFC 9649, section 3.6.2.3): `(0x1e35a7bd * color) >> (32 - bits)` on
    /// 32-bit values.
    static func cacheIndex(_ argb: UInt32, bits: Int) -> Int {
        Int((0x1e35_a7bd &* argb) >> UInt32(32 - bits))
    }
}
