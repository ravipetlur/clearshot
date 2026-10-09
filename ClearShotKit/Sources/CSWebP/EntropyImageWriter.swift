/// Writes an ARGB pixel stream as the entropy-coded part of a WebP lossless stream (RFC 9649, section 3.7): the
/// colour-cache and meta-prefix fields, one group of five prefix codes, then the symbols.
///
/// The five codes of a group, in the order they are written:
/// 1. green, the length prefixes and colour-cache indices: 256 + 24 + the cache size symbols;
/// 2. red, 256 symbols;
/// 3. blue, 256 symbols;
/// 4. alpha, 256 symbols;
/// 5. distance, 40 symbols.
///
/// A stream is a sequence of `Symbol`s: pixels written out, colour-cache indices and copies of earlier pixels.
enum EntropyImageWriter {
    /// One entry of the stream: a pixel written out, a colour-cache index, or a copy of earlier pixels.
    ///
    /// A stream holds one symbol per pixel at worst, and a photo-sized capture is some 15 million pixels, so the symbol
    /// is kept to 8 bytes: a `UInt64` with a 2-bit kind on top. A literal keeps its ARGB colour in the low 32 bits; a
    /// cache index keeps the slot there; a copy keeps its distance code in the low 32 bits and its length in 13 bits
    /// from bit 32. Make one with `literal`, `cacheIndex` or `backref`, and look inside with `form`.
    struct Symbol: Equatable, Sendable {
        /// What a symbol is, unpacked, for a `switch`.
        enum Form: Equatable {
            /// A pixel written out: ARGB packed as `alpha << 24 | red << 16 | green << 8 | blue`.
            case literal(UInt32)
            /// A colour-cache index: the pixel is what the cache holds at that slot. Only valid when the stream has a
            /// colour cache, and then below its size.
            case cacheIndex(Int)
            /// A copy of `length` pixels (1 to 4096) from `distanceCode` (the format's distance code, 1 to 1 048 576,
            /// not the plain distance: see `DistanceCodes`). The source may overlap the pixels being written.
            case backref(length: Int, distanceCode: Int)
        }

        private let bits: UInt64
        private static let kindShift: UInt64 = 62
        private static let literalKind: UInt64 = 0
        private static let cacheIndexKind: UInt64 = 1
        private static let backrefKind: UInt64 = 2
        private static let lengthShift: UInt64 = 32
        private static let lengthMask: UInt64 = 0x1FFF
        private static let lowMask: UInt64 = 0xFFFF_FFFF

        private init(bits: UInt64) {
            self.bits = bits
        }

        /// A pixel written out in full.
        @inline(__always)
        static func literal(_ argb: UInt32) -> Symbol {
            Symbol(bits: literalKind << kindShift | UInt64(argb))
        }

        /// The colour at `index` of the colour cache.
        @inline(__always)
        static func cacheIndex(_ index: Int) -> Symbol {
            precondition(index >= 0 && index < 1 << ColorCache.maxBits, "cache index \(index) out of range")
            return Symbol(bits: cacheIndexKind << kindShift | UInt64(index))
        }

        /// A copy of `length` pixels (1 to 4096) from `distanceCode` (1 to 1 048 576).
        @inline(__always)
        static func backref(length: Int, distanceCode: Int) -> Symbol {
            precondition((1...EntropyImageWriter.maxLength).contains(length), "a copy is 1 to 4096 pixels")
            precondition((1...DistanceCodes.maxCode).contains(distanceCode), "distance code \(distanceCode)")
            return Symbol(bits: backrefKind << kindShift | UInt64(length) << lengthShift | UInt64(distanceCode))
        }

        var form: Form {
            @inline(__always)
            get {
                switch bits >> Self.kindShift {
                case Self.literalKind: .literal(UInt32(truncatingIfNeeded: bits))
                case Self.cacheIndexKind: .cacheIndex(Int(bits & Self.lowMask))
                default: .backref(length: Int((bits >> Self.lengthShift) & Self.lengthMask),
                                  distanceCode: Int(bits & Self.lowMask))
                }
            }
        }
    }

    /// Where the stream sits, which decides whether a meta-prefix field is present.
    enum Kind {
        /// The main image: colour-cache info, then the meta-prefix field (0: one prefix code group), then the data.
        case spatiallyCoded
        /// An image inside a transform: colour-cache info, then the data, without the meta-prefix field.
        case entropyCoded
    }

    static let lengthPrefixSymbols = 24
    static let distanceAlphabetSize = 40
    /// The longest copy: 4 096 pixels (RFC 9649, section 3.6.2.2).
    static let maxLength = 4096

    /// The size of the green alphabet: the 256 literal values, the 24 length prefixes, and one symbol per cache slot.
    static func greenAlphabetSize(cacheBits: Int) -> Int {
        256 + lengthPrefixSymbols + (cacheBits > 0 ? 1 << cacheBits : 0)
    }

    // MARK: Counting

    /// How often a stream uses each symbol of its five codes, and how many extra bits ride along with its lengths and
    /// distance codes.
    struct Histograms {
        let cacheBits: Int
        var green: [Int]
        var red = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        var alpha = [Int](repeating: 0, count: 256)
        var distance = [Int](repeating: 0, count: EntropyImageWriter.distanceAlphabetSize)
        /// Extra bits of all the lengths and distance codes: written as they are, not through a prefix code.
        private(set) var extraBits = 0

        init(cacheBits: Int) {
            precondition(cacheBits == 0 || (1...ColorCache.maxBits).contains(cacheBits))
            self.cacheBits = cacheBits
            green = [Int](repeating: 0, count: EntropyImageWriter.greenAlphabetSize(cacheBits: cacheBits))
        }

        /// The counts of a whole stream.
        init<Symbols: Sequence>(counting symbols: Symbols, cacheBits: Int) where Symbols.Element == Symbol {
            self.init(cacheBits: cacheBits)
            for symbol in symbols { add(symbol) }
        }

        /// The five histograms in the order of the codes: green, red, blue, alpha, distance.
        var all: [[Int]] { [green, red, blue, alpha, distance] }

        mutating func add(_ symbol: Symbol) {
            switch symbol.form {
            case .literal(let argb):
                green[Int((argb >> 8) & 0xFF)] += 1
                red[Int((argb >> 16) & 0xFF)] += 1
                blue[Int(argb & 0xFF)] += 1
                alpha[Int(argb >> 24)] += 1
            case .cacheIndex(let index):
                precondition(cacheBits > 0 && index < 1 << cacheBits, "cache index \(index) out of range")
                green[256 + EntropyImageWriter.lengthPrefixSymbols + index] += 1
            case .backref(let length, let distanceCode):
                let lengthCode = PrefixCoding.encode(value: length)
                let distanceCoding = PrefixCoding.encode(value: distanceCode)
                green[256 + lengthCode.prefix] += 1
                distance[distanceCoding.prefix] += 1
                extraBits += lengthCode.extraBits + distanceCoding.extraBits
            }
        }
    }

    // MARK: Writing

    /// What writes the symbols of a stream, one at a time, once `begin` has written everything before them: the five
    /// codes of the stream's group, made from the counts.
    struct SymbolWriter {
        private let writer: BitWriter
        private let greenCode: PrefixCode.Encoder
        private let redCode: PrefixCode.Encoder
        private let blueCode: PrefixCode.Encoder
        private let alphaCode: PrefixCode.Encoder
        private let distanceCode: PrefixCode.Encoder

        fileprivate init(codes: [PrefixCode.Encoder], writer: BitWriter) {
            self.writer = writer
            greenCode = codes[0]
            redCode = codes[1]
            blueCode = codes[2]
            alphaCode = codes[3]
            distanceCode = codes[4]
        }

        /// Writes one symbol. It must be one of those the counts the writer was begun with counted: a symbol with no
        /// code stops the program.
        @inline(__always)
        func write(_ symbol: Symbol) {
            let cacheBase = 256 + EntropyImageWriter.lengthPrefixSymbols
            switch symbol.form {
            case .literal(let argb):
                // A literal pixel is its green, red, blue and alpha codes, in that order.
                greenCode.emit(Int((argb >> 8) & 0xFF), to: writer)
                redCode.emit(Int((argb >> 16) & 0xFF), to: writer)
                blueCode.emit(Int(argb & 0xFF), to: writer)
                alphaCode.emit(Int(argb >> 24), to: writer)
            case .cacheIndex(let index):
                greenCode.emit(cacheBase + index, to: writer)
            case .backref(let length, let code):
                // The length's prefix (a green symbol) and extra bits, then the distance code's prefix and extra bits.
                let lengthCoding = PrefixCoding.encode(value: length)
                greenCode.emit(256 + lengthCoding.prefix, to: writer)
                if lengthCoding.extraBits > 0 {
                    writer.write(UInt32(lengthCoding.extraValue), bits: lengthCoding.extraBits)
                }
                let distanceCoding = PrefixCoding.encode(value: code)
                distanceCode.emit(distanceCoding.prefix, to: writer)
                if distanceCoding.extraBits > 0 {
                    writer.write(UInt32(distanceCoding.extraValue), bits: distanceCoding.extraBits)
                }
            }
        }
    }

    /// Writes what comes before the symbols of a stream of `kind` with a colour cache of `cacheBits` bits (0 for none):
    /// the colour-cache field, for the main image the meta-prefix field, and the description of each of the five codes
    /// that `histograms` (the counts of the symbols to come) call for. The returned writer then writes the symbols.
    static func begin(cacheBits: Int, kind: Kind, histograms: Histograms, to writer: BitWriter) -> SymbolWriter {
        precondition(histograms.cacheBits == cacheBits, "the counts are of a stream with another colour cache")
        if cacheBits > 0 {
            writer.write(1, bits: 1)  // color_cache_info: a colour cache follows,
            writer.write(UInt32(cacheBits), bits: 4)  // of 1 << cacheBits slots
        } else {
            writer.write(0, bits: 1)  // color_cache_info: no colour cache
        }
        if kind == .spatiallyCoded { writer.write(0, bits: 1) }  // meta prefix: a single prefix code group

        // Writing each code's description also leaves the encoder that writes its symbols.
        let codes = histograms.all.map { histogram in
            let lengths = PrefixCode.lengths(for: histogram, maxLength: PrefixCode.maxLength)
            PrefixCode.write(lengths: lengths, to: writer)
            return PrefixCode.Encoder(lengths: lengths)
        }
        return SymbolWriter(codes: codes, writer: writer)
    }

    /// Writes `symbols` as `kind`, with a colour cache of `cacheBits` bits (0 for none; the symbols must then hold no
    /// cache index). The collection is read twice, once to count the symbols and once to write them; a caller that has
    /// the counts already (they were made to cost the stream) passes them as `histograms` and the first pass is
    /// skipped.
    static func write<Symbols: Collection>(
        _ symbols: Symbols, cacheBits: Int = 0, kind: Kind, histograms counted: Histograms? = nil,
        to writer: BitWriter
    ) where Symbols.Element == Symbol {
        let histograms = counted ?? Histograms(counting: symbols, cacheBits: cacheBits)
        let symbolWriter = begin(cacheBits: cacheBits, kind: kind, histograms: histograms, to: writer)
        for symbol in symbols { symbolWriter.write(symbol) }
    }

    /// Writes a stream costed by `BackwardReferences` (`coded`) as `kind`, making its symbols again from `pixels`, the
    /// ones it was made from (`width` across), and writing each as it is made: the stream is never held in memory. The
    /// counts the codes are built from are those of the symbols made, since a stream is the same every time it is made.
    static func write(
        _ coded: BackwardReferences.Coded, pixels: [UInt32], width: Int, kind: Kind, to writer: BitWriter
    ) {
        let symbolWriter = begin(cacheBits: coded.cacheBits, kind: kind, histograms: coded.histograms, to: writer)
        BackwardReferences.forEachSymbol(pixels: pixels, width: width, matches: coded.matches,
                                         cacheBits: coded.cacheBits) { symbolWriter.write($0) }
    }

    /// Writes the pixels of a small image that lives inside a transform (the palette's colour table, the predictor's
    /// tile image) as an entropy-coded image, in as few bits as the encoder's own choices give: copies or none, and the
    /// colour-cache size that `BackwardReferences.codedWithBestCache` estimates to be cheapest. `width` is the image's
    /// width in pixels, which the 2-D distance codes need; the pixels are `width` across and as many rows as they fill.
    static func writeSubImage(_ pixels: [UInt32], width: Int, to writer: BitWriter) {
        let coded = BackwardReferences.codedWithBestCache(pixels: pixels, width: width)
        write(coded, pixels: pixels, width: width, kind: .entropyCoded, to: writer)
    }

    // MARK: Estimating

    /// What `write` would spend on a stream, in bits, split into what does not depend on how many pixels there are
    /// (the field bits and the descriptions of the five codes) and what grows with the symbols (their codes and extra
    /// bits). It writes the descriptions for real into a scratch writer, so the first part is exact, and the second is
    /// exact too: a symbol of a code with one used symbol costs nothing, as in `write`.
    struct Cost {
        var fixedBits: Int
        var symbolBits: Int

        /// The total when the symbol part is scaled, as when the cost of a sample stands for the whole image.
        func total(symbolBitsScaledBy scale: Double = 1) -> Int {
            fixedBits + Int((Double(symbolBits) * scale).rounded())
        }
    }

    static func cost<Symbols: Sequence>(of symbols: Symbols, cacheBits: Int, kind: Kind) -> Cost
    where Symbols.Element == Symbol {
        cost(of: Histograms(counting: symbols, cacheBits: cacheBits), kind: kind)
    }

    /// The cost of a stream from its counts.
    static func cost(of histograms: Histograms, kind: Kind) -> Cost {
        let cacheBits = histograms.cacheBits
        let scratch = BitWriter()
        var symbolBits = histograms.extraBits
        for histogram in histograms.all {
            let lengths = PrefixCode.lengths(for: histogram, maxLength: PrefixCode.maxLength)
            PrefixCode.write(lengths: lengths, to: scratch)
            if lengths.lazy.filter({ $0 > 0 }).prefix(2).count == 2 {
                for (symbol, length) in lengths.enumerated() { symbolBits += histogram[symbol] * Int(length) }
            }
        }
        let header = (cacheBits > 0 ? 5 : 1) + (kind == .spatiallyCoded ? 1 : 0)
        return Cost(fixedBits: header + scratch.bitCount, symbolBits: symbolBits)
    }
}
