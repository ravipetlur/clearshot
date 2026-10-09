/// The prefix (Huffman) codes of a WebP lossless stream, RFC 9649 section 3.7.2: choosing code lengths, assigning
/// canonical codes, and writing a code's description into the stream.
enum PrefixCode {
    /// Longest code a symbol may have in the main codes.
    static let maxLength = 15
    /// Longest code in the code-length code: its lengths are stored in 3 bits each.
    static let maxCodeLengthCodeLength = 7
    /// The order in which the code-length code's own lengths are stored (RFC 9649, section 3.7.2.1.2).
    static let codeLengthCodeOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    // MARK: Code lengths

    /// The length of each symbol's code for `histogram`, none longer than `maxLength` bits; 0 for a symbol that never
    /// occurs.
    ///
    /// The limit is enforced by the package-merge method (Larmore and Hirschberg), which yields the cheapest code of
    /// at most `maxLength` bits rather than adjusting an unlimited Huffman code after the fact. With two or more used
    /// symbols the lengths form a complete tree (the Kraft sum is exactly one), as the format requires.
    ///
    /// A histogram with one used symbol gives that symbol length 1 (RFC 9649, section 3.7.2.1): a single leaf, which
    /// counts as a complete tree and takes zero bits per occurrence. An empty histogram gives all zeros.
    static func lengths(for histogram: [Int], maxLength: Int) -> [UInt8] {
        precondition((1...15).contains(maxLength), "code lengths are 1 to 15 bits")
        var lengths = [UInt8](repeating: 0, count: histogram.count)
        // The used symbols from the rarest up (ties by symbol number): the order the leaves are merged in.
        let used = histogram.indices.filter { histogram[$0] > 0 }.sorted { (histogram[$0], $0) < (histogram[$1], $1) }
        precondition(used.count <= 1 << maxLength, "\(used.count) symbols don't fit codes of \(maxLength) bits")
        switch used.count {
        case 0:
            return lengths
        case 1:
            lengths[used[0]] = 1
            return lengths
        default:
            break
        }

        let leafCount = used.count
        let leafWeights = used.map { histogram[$0] }

        // One list per length level. Level 0 is the leaves alone; each later level merges the leaves with the
        // packages made by pairing off the list below it. `isPackage[level][i]` tells whether item `i` is a package.
        var isPackage: [[Bool]] = [[Bool](repeating: false, count: leafCount)]
        var below = leafWeights
        for _ in 1..<maxLength {
            var packages: [Int] = []
            packages.reserveCapacity(below.count / 2)
            var index = 0
            while index + 1 < below.count {
                packages.append(below[index] + below[index + 1])
                index += 2
            }
            var merged: [Int] = []
            var flags: [Bool] = []
            merged.reserveCapacity(leafCount + packages.count)
            flags.reserveCapacity(leafCount + packages.count)
            var leaf = 0, package = 0
            while leaf < leafCount || package < packages.count {
                if package == packages.count || (leaf < leafCount && leafWeights[leaf] <= packages[package]) {
                    merged.append(leafWeights[leaf])
                    flags.append(false)
                    leaf += 1
                } else {
                    merged.append(packages[package])
                    flags.append(true)
                    package += 1
                }
            }
            isPackage.append(flags)
            below = merged
        }

        // The cheapest 2n - 2 items of the top list are the code; a leaf's length is how many selected items, at
        // any level, contain it. Selecting items at one level selects the first 2 * (packages taken) at the next.
        var depth = [Int](repeating: 0, count: leafCount)
        var take = 2 * leafCount - 2
        for level in stride(from: maxLength - 1, through: 0, by: -1) {
            let flags = isPackage[level]
            precondition(take <= flags.count)
            var packagesTaken = 0
            for index in 0..<take where flags[index] { packagesTaken += 1 }
            // The leaves in a prefix of a merged list are the rarest ones, in order.
            for leaf in 0..<(take - packagesTaken) { depth[leaf] += 1 }
            take = 2 * packagesTaken
        }
        for (leaf, symbol) in used.enumerated() { lengths[symbol] = UInt8(depth[leaf]) }
        return lengths
    }

    // MARK: Canonical codes

    /// The code for each symbol, ready for `BitWriter`. The codes are canonical: shorter codes sort before longer ones
    /// and codes of one length go in symbol order, as in RFC 1951 section 3.2.2. A decoder reads a code one bit at a
    /// time starting with its most significant bit, while `BitWriter` writes the low bit of a value first, so each
    /// code is stored bit-reversed within its length.
    static func canonicalCodes(lengths: [UInt8]) -> [UInt16] {
        var countAtLength = [Int](repeating: 0, count: maxLength + 1)
        for length in lengths where length > 0 { countAtLength[Int(length)] += 1 }
        var nextCode = [Int](repeating: 0, count: maxLength + 1)
        var code = 0
        for length in 1...maxLength {
            code = (code + countAtLength[length - 1]) << 1
            nextCode[length] = code
        }
        var codes = [UInt16](repeating: 0, count: lengths.count)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            let value = nextCode[Int(length)]
            nextCode[Int(length)] += 1
            assert(value < 1 << Int(length), "the lengths over-subscribe the code space")
            var reversed = 0, remaining = value
            for _ in 0..<Int(length) {
                reversed = (reversed << 1) | (remaining & 1)
                remaining >>= 1
            }
            codes[symbol] = UInt16(reversed)
        }
        return codes
    }

    /// Writes symbols with a code. A code with a single used symbol (or none) is a single leaf: its symbol costs zero
    /// bits, and nothing is written for it. Emitting a symbol the code does not contain is a caller bug and stops the
    /// program, also for a single leaf, where it would otherwise pass without a trace.
    struct Encoder {
        let lengths: [UInt8]
        let codes: [UInt16]
        let isSingleLeaf: Bool

        init(lengths: [UInt8]) {
            self.lengths = lengths
            codes = PrefixCode.canonicalCodes(lengths: lengths)
            isSingleLeaf = lengths.lazy.filter { $0 > 0 }.prefix(2).count < 2
        }

        func emit(_ symbol: Int, to writer: BitWriter) {
            let length = Int(lengths[symbol])
            precondition(length > 0, "symbol \(symbol) has no code")
            if isSingleLeaf { return }
            writer.write(UInt32(codes[symbol]), bits: length)
        }
    }

    // MARK: Writing a code

    /// Writes the description of the code with these lengths (one entry per symbol of the alphabet), in whichever
    /// form the format offers that suits it:
    /// - The simple form, when at most two symbols are used and all are below 256: the symbols themselves. An alphabet
    ///   with no used symbol is written as the one symbol 0, so the group is still valid.
    /// - The normal form otherwise: the lengths, run-length coded with the code-length code.
    ///
    /// A single used symbol is a single leaf (section 3.7.2.1): the simple form when it is below 256, otherwise the
    /// normal form with every length 0 except that symbol's, which is 1. Either way its occurrences take zero bits.
    ///
    /// `lengths` must be what `lengths(for:maxLength:)` returns: a complete code, or a single leaf.
    static func write(lengths: [UInt8], to writer: BitWriter) {
        let used = lengths.indices.filter { lengths[$0] > 0 }
        let fitsSimpleForm = used.count <= 2 && used.allSatisfy { $0 < 256 }
            && (used.count < 2 || used.allSatisfy { lengths[$0] == 1 })
        if fitsSimpleForm {
            writeSimple(symbols: used.isEmpty ? [0] : used, to: writer)
        } else {
            writeNormal(lengths: lengths, to: writer)
        }
    }

    /// RFC 9649, section 3.7.2.1.1: `is_simple`, `num_symbols - 1`, `is_first_8bits`, the first symbol in 1 or 8 bits,
    /// the second symbol, if any, in 8 bits. Every listed symbol has length 1. The smaller symbol goes first, which is
    /// also the one the canonical assignment gives the code 0.
    private static func writeSimple(symbols: [Int], to writer: BitWriter) {
        writer.write(1, bits: 1)
        writer.write(UInt32(symbols.count - 1), bits: 1)
        let first = symbols[0]
        if first < 2 {
            writer.write(0, bits: 1)
            writer.write(UInt32(first), bits: 1)
        } else {
            writer.write(1, bits: 1)
            writer.write(UInt32(first), bits: 8)
        }
        if symbols.count == 2 { writer.write(UInt32(symbols[1]), bits: 8) }
    }

    /// One run-length token of the lengths of a normal code: a code-length-code symbol and its extra bits.
    private struct Token {
        var symbol: Int
        var extraBits: Int = 0
        var extraValue: Int = 0
    }

    /// The tokens for a list of code lengths. Literals 0 to 15 are the lengths themselves; 16 repeats the previous
    /// non-zero length 3 to 6 times, 17 is 3 to 10 zeros and 18 is 11 to 138 zeros. A repeat (16) is only ever used
    /// straight after a literal or another 16 of the same length, so it means the same under any reading of
    /// "previous non-zero length". Runs are cut so that no 1 or 2 left over remain after a repeat token.
    private static func tokens(for lengths: [UInt8]) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        while index < lengths.count {
            let value = lengths[index]
            var run = 1
            while index + run < lengths.count, lengths[index + run] == value { run += 1 }
            index += run

            if value == 0 {
                var remaining = run
                while remaining >= 11 {
                    var count = min(remaining, 138)
                    if (1...2).contains(remaining - count) { count = remaining - 3 }
                    tokens.append(Token(symbol: 18, extraBits: 7, extraValue: count - 11))
                    remaining -= count
                }
                if remaining >= 3 {
                    tokens.append(Token(symbol: 17, extraBits: 3, extraValue: remaining - 3))
                    remaining = 0
                }
                for _ in 0..<remaining { tokens.append(Token(symbol: 0)) }
            } else {
                tokens.append(Token(symbol: Int(value)))
                var remaining = run - 1
                while remaining >= 3 {
                    var count = min(remaining, 6)
                    if (1...2).contains(remaining - count) { count = remaining - 3 }
                    tokens.append(Token(symbol: 16, extraBits: 2, extraValue: count - 3))
                    remaining -= count
                }
                for _ in 0..<remaining { tokens.append(Token(symbol: Int(value))) }
            }
        }
        return tokens
    }

    /// RFC 9649, section 3.7.2.1.2: `is_simple` 0, `num_code_lengths - 4` in 4 bits, the code-length code's lengths in
    /// 3 bits each in `codeLengthCodeOrder` (trailing zeros dropped, at least 4 written), the bit for "use every
    /// symbol" (`max_symbol` is the alphabet size), then the tokens.
    static func writeNormal(lengths: [UInt8], to writer: BitWriter) {
        let used = lengths.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        if used == 1 {
            precondition(lengths.contains(1), "a single leaf is marked with the length 1")
        } else {
            precondition(
                lengths.reduce(0, { $0 + ($1 > 0 ? 1 << (maxLength - Int($1)) : 0) }) == 1 << maxLength,
                "the lengths are not a complete code")
        }

        let runTokens = PrefixCode.tokens(for: lengths)
        var histogram = [Int](repeating: 0, count: codeLengthCodeOrder.count)
        for token in runTokens { histogram[token.symbol] += 1 }
        // The code-length code is itself a prefix code: with one kind of token it is a single leaf, and the tokens
        // take zero bits (the `Encoder` writes none).
        let codeLengthLengths = PrefixCode.lengths(for: histogram, maxLength: maxCodeLengthCodeLength)
        let codeLengthCode = Encoder(lengths: codeLengthLengths)

        var count = codeLengthCodeOrder.count
        while count > 4, codeLengthLengths[codeLengthCodeOrder[count - 1]] == 0 { count -= 1 }

        writer.write(0, bits: 1)
        writer.write(UInt32(count - 4), bits: 4)
        for position in 0..<count { writer.write(UInt32(codeLengthLengths[codeLengthCodeOrder[position]]), bits: 3) }
        writer.write(0, bits: 1)
        for token in runTokens {
            codeLengthCode.emit(token.symbol, to: writer)
            if token.extraBits > 0 { writer.write(UInt32(token.extraValue), bits: token.extraBits) }
        }
    }
}
