/// Turns an ARGB pixel array into the symbols of a lossless stream: literals, colour-cache indices and LZ77 copies of
/// earlier pixels (RFC 9649, sections 3.6.2.2 and 3.6.2.3).
///
/// Two steps, kept apart:
/// 1. `findMatches` looks for copies. It does not depend on the colour cache.
/// 2. `forEachSymbol` walks the pixels, writes a copy where there is one, and writes every other pixel as a cache index
///    when the cache holds it and as a literal when not, keeping a model of the decoder's cache up to date as it goes.
///
/// The split lets the choice of cache size reuse one search for every size it tries. The second step hands each symbol
/// to its caller as it is made, so a stream can be counted or written without being kept: a symbol is 8 bytes, and a
/// stream of a large capture is one per pixel at worst.
enum BackwardReferences {
    // MARK: Parameters

    /// The shortest copy worth writing. A copy of fewer pixels costs about as much as the pixels themselves.
    static let minimumLength = 3
    /// The longest copy the format has a code for (RFC 9649, section 3.6.2.2).
    static let maximumLength = EntropyImageWriter.maxLength
    /// How many earlier places with the same hash are compared before the search gives up: 64. Measured on the
    /// screenshot-like fixture (1001 x 999, bytes of the whole file) a depth of 4, 8, 16, 32, 64 and 128 gave 45 560,
    /// 42 060, 39 962, 38 212, 37 328 and 36 934, and on the repeated tiles (400 x 300) 2 208, 2 200, 2 084, 2 040,
    /// 1 660 and 1 660. Past 64 the gain is about one percent and the search time keeps growing; in flat areas every
    /// position hashes alike, so the cost of a deep chain is paid there first.
    static let chainDepth = 64
    /// A copy this long is taken at once, without looking for a better one.
    static let niceLength = 256
    /// A copy shorter than this is checked against what starts one pixel later (see `findMatches`); a long copy is
    /// not, since one more pixel could hardly beat it. The look-ahead is worth about two percent of the file on the
    /// screenshot-like fixtures (37 328 against 38 006 bytes at 1001 x 999 without it).
    static let lazyLimit = 128
    /// How much longer the copy one pixel later must be for the pixel in between to be left to a literal. Margins of
    /// 1, 2 and 3 differ by less than half a percent; 2 is the one that a literal's cost makes break even.
    static let lazyMargin = 2

    /// The colour-cache sizes (in bits; 0 for no cache) that `chooseCoding` tries.
    static let cacheBitsCandidates = [0, 2, 4, 6, 8, 10]
    /// The most pixels the choice of cache size looks at; a larger image is judged on bands of rows.
    static let sampleLimit = 1 << 18
    /// How many bands of rows a larger image's sample is made of.
    private static let sampleBands = 4

    // MARK: Copies

    /// A copy: `length` pixels from `position`, each taken from `distance` pixels earlier. The source may overlap the
    /// copy (`distance < length`), which is how a run is coded.
    struct Match: Equatable {
        var position: Int
        var length: Int
        var distance: Int
    }

    /// The copies for `pixels`, in order and not overlapping: lengths 3 to 4096 and distances up to the largest the
    /// format can name (`DistanceCodes.maxDistance`).
    ///
    /// The search is greedy with a one-step look-ahead. A hash of three pixels names a chain of earlier places that
    /// start alike; at each pixel the nearest `chainDepth` of them are compared (plus the pixel straight above, whose
    /// distance has the cheapest code, and which is worth about a tenth of the file on the screenshot-like fixtures)
    /// and the longest copy wins, the first one compared on a tie. If the copy found is shorter than `lazyLimit` and
    /// the one starting at the next pixel is longer by `lazyMargin` or more, the pixel in between is left unmatched,
    /// to become a literal or a cache index. A copy of `niceLength` or more ends the search at once.
    static func findMatches(pixels: [UInt32], width: Int) -> [Match] {
        precondition(width >= 1)
        let count = pixels.count
        guard count >= minimumLength else { return [] }
        var matches: [Match] = []
        pixels.withUnsafeBufferPointer { buffer in
            let chains = HashChains(pixels: buffer, width: width)
            defer { chains.release() }
            var position = 0
            var pending: (length: Int, distance: Int)?
            while position < count {
                // The chains hold the positions before `position`, whether `pending` was found for it earlier (when
                // the chains held exactly those) or is searched now.
                let found = pending ?? chains.search(at: position)
                pending = nil
                chains.insert(position)
                if found.length >= minimumLength {
                    if found.length < lazyLimit, position + 1 < count {
                        let next = chains.search(at: position + 1)
                        if next.length >= found.length + lazyMargin {
                            pending = next
                            position += 1
                            continue
                        }
                    }
                    matches.append(Match(position: position, length: found.length, distance: found.distance))
                    for offset in 1..<found.length { chains.insert(position + offset) }
                    position += found.length
                } else {
                    position += 1
                }
            }
        }
        return matches
    }

    /// The hash chains of the search: for each hash of three pixels, the latest position that had it, and for each
    /// position, the one before it with the same hash. The links are kept in a ring of the window's size (2^20), so a
    /// position's link is overwritten once the search is a window ahead of it; the search never reads a link from a
    /// position farther back than the largest distance, so it never reads one that has been overwritten.
    private struct HashChains {
        let pixels: UnsafeBufferPointer<UInt32>
        let width: Int
        let hashShift: UInt32
        let ringMask: Int
        let head: UnsafeMutablePointer<Int32>
        let previous: UnsafeMutablePointer<Int32>

        init(pixels: UnsafeBufferPointer<UInt32>, width: Int) {
            self.pixels = pixels
            self.width = width
            let hashBits = min(18, max(8, Int.bitWidth - pixels.count.leadingZeroBitCount))
            hashShift = UInt32(32 - hashBits)
            head = .allocate(capacity: 1 << hashBits)
            head.initialize(repeating: -1, count: 1 << hashBits)
            // The window is 2^20 pixels, more than the largest distance; a smaller image needs no more than its own
            // size, rounded up to a power of two.
            let ringSize = min(1 << 20, 1 << (Int.bitWidth - max(1, pixels.count - 1).leadingZeroBitCount))
            ringMask = ringSize - 1
            previous = .allocate(capacity: ringSize)
            previous.initialize(repeating: -1, count: ringSize)
        }

        func release() {
            head.deallocate()
            previous.deallocate()
        }

        @inline(__always)
        private func hash(at position: Int) -> Int {
            var h = pixels[position] &* 0x9E37_79B1
            h = (h &+ pixels[position + 1]) &* 0x85EB_CA6B
            h = (h &+ pixels[position + 2]) &* 0xC2B2_AE35
            return Int(h >> hashShift)
        }

        /// Makes `position` the latest place with its hash. A position too close to the end to start a copy of three
        /// pixels is left out.
        @inline(__always)
        func insert(_ position: Int) {
            guard position + 2 < pixels.count else { return }
            let slot = hash(at: position)
            previous[position & ringMask] = head[slot]
            head[slot] = Int32(truncatingIfNeeded: position)
        }

        /// The longest copy that can start at `position` from the positions in the chains (all of them before it),
        /// as a length and a distance; length 0 for none. Its length is 3 or more, at most 4096 and at most what is
        /// left of the image.
        func search(at position: Int) -> (length: Int, distance: Int) {
            let limit = min(BackwardReferences.maximumLength, pixels.count - position)
            guard limit >= BackwardReferences.minimumLength else { return (0, 0) }

            var bestLength = 0
            var bestDistance = 0

            // Compares the pixels at `source` with those at `position`; takes the copy when it is the longest so far.
            @inline(__always)
            func consider(_ source: Int) {
                // A copy as long as the image allows cannot be beaten; and when one exists, a candidate that differs
                // at its end cannot beat it, which saves comparing the pixels before.
                if bestLength >= limit { return }
                if bestLength > 0, pixels[source + bestLength] != pixels[position + bestLength] { return }
                var length = 0
                while length < limit, pixels[source + length] == pixels[position + length] { length += 1 }
                if length > bestLength, length >= BackwardReferences.minimumLength {
                    bestLength = length
                    bestDistance = position - source
                }
            }

            // The pixel straight above has the cheapest distance code, so it is the first to be tried.
            if width <= position { consider(position - width) }

            var depth = BackwardReferences.chainDepth
            var candidate = Int(head[hash(at: position)])
            let enough = min(BackwardReferences.niceLength, limit)
            while candidate >= 0, depth > 0, bestLength < enough {
                let distance = position - candidate
                if distance > DistanceCodes.maxDistance { break }
                consider(candidate)
                depth -= 1
                let older = Int(previous[candidate & ringMask])
                if older >= candidate { break }  // a link leads backwards; this guards against a corrupt chain
                candidate = older
            }
            return (bestLength, bestDistance)
        }
    }

    // MARK: Symbols

    /// Calls `body` with each symbol of the stream for `pixels` with the copies in `matches` (from `findMatches` for the
    /// same pixels and width), in order, with a colour cache of `cacheBits` bits (0 for none).
    ///
    /// A copy is written with the distance code `DistanceCodes.code(forDistance:width:)` gives. Any other pixel is a
    /// cache index when the cache holds exactly that colour in its slot, and a literal when not. The cache model is
    /// kept as a decoder keeps it: every pixel, whether a literal, a cache hit or one of those a copy produces, is
    /// inserted after it is written.
    ///
    /// The stream is a function of its arguments alone, so making it again gives the same symbols.
    @inline(__always)
    static func forEachSymbol(
        pixels: [UInt32], width: Int, matches: [Match], cacheBits: Int, _ body: (EntropyImageWriter.Symbol) -> Void
    ) {
        precondition(cacheBits == 0 || (1...ColorCache.maxBits).contains(cacheBits))
        var cache = ColorCache(bits: max(cacheBits, 1))
        let useCache = cacheBits > 0

        var position = 0
        @inline(__always)
        func writePixels(upTo end: Int) {
            while position < end {
                let argb = pixels[position]
                if useCache {
                    if let index = cache.lookup(argb) {
                        body(.cacheIndex(index))
                    } else {
                        body(.literal(argb))
                    }
                    cache.insert(argb)
                } else {
                    body(.literal(argb))
                }
                position += 1
            }
        }
        for match in matches {
            precondition(match.position >= position, "matches must be in order and apart")
            writePixels(upTo: match.position)
            body(.backref(length: match.length,
                          distanceCode: DistanceCodes.code(forDistance: match.distance, width: width)))
            if useCache {
                for offset in 0..<match.length { cache.insert(pixels[match.position + offset]) }
            }
            position = match.position + match.length
        }
        writePixels(upTo: pixels.count)
    }

    /// The symbol stream for `pixels` with the copies in `matches` and a colour cache of `cacheBits` bits (0 for none),
    /// as an array: what `forEachSymbol` makes, kept.
    static func symbols(pixels: [UInt32], width: Int, matches: [Match], cacheBits: Int) -> [EntropyImageWriter.Symbol] {
        let covered = matches.reduce(0) { $0 + $1.length }
        var symbols: [EntropyImageWriter.Symbol] = []
        symbols.reserveCapacity(pixels.count - covered + matches.count)
        forEachSymbol(pixels: pixels, width: width, matches: matches, cacheBits: cacheBits) { symbols.append($0) }
        return symbols
    }

    /// The counts of the symbols `forEachSymbol` makes for these arguments, counted as they are made.
    static func histograms(
        pixels: [UInt32], width: Int, matches: [Match], cacheBits: Int
    ) -> EntropyImageWriter.Histograms {
        var histograms = EntropyImageWriter.Histograms(cacheBits: cacheBits)
        forEachSymbol(pixels: pixels, width: width, matches: matches, cacheBits: cacheBits) { histograms.add($0) }
        return histograms
    }

    /// The symbols for `pixels` with copies found by `findMatches` and a colour cache of `cacheBits` bits.
    static func find(pixels: [UInt32], width: Int, cacheBits: Int) -> [EntropyImageWriter.Symbol] {
        symbols(pixels: pixels, width: width, matches: findMatches(pixels: pixels, width: width), cacheBits: cacheBits)
    }

    // MARK: The cache size

    /// A stream costed as the main image and ready to be written: the colour-cache size and the copies it is made with,
    /// the counts of each symbol (which `EntropyImageWriter.write` takes to skip counting again) and the bits `write`
    /// spends on them (`EntropyImageWriter.cost`, exact).
    ///
    /// The symbols are not kept. A stream has one per pixel at worst, 8 bytes each, which on a large capture is more
    /// than the pixels themselves, and two are made to be compared. They are made again from the pixels when the image
    /// is written (`EntropyImageWriter.write(_:pixels:width:kind:to:)`); the copies are kept because finding them is
    /// the costly part, and there are few next to the pixels.
    struct Coded {
        var cacheBits: Int
        var matches: [Match]
        var histograms: EntropyImageWriter.Histograms
        var bits: Int
    }

    /// The colour-cache size to write `pixels` with and the copies to take, chosen from `cacheBitsCandidates`.
    ///
    /// For each size, with the copies and then without them, the symbols are counted and their coded size is estimated,
    /// and the cheapest wins; on a tie the one with copies and then the smaller cache. Copies are worth leaving out
    /// where a cache that holds every colour says a pixel in a few bits and a copy of three or four pixels costs more
    /// than they would (few colours in no order). An image of up to `sampleLimit` pixels is judged whole. A larger one
    /// is judged on a sample (see `chooseCoding`) and then coded whole with the choice, and its counts and cost are
    /// taken once from the whole stream.
    static func codedWithBestCache(pixels: [UInt32], width: Int) -> Coded {
        if pixels.count <= sampleLimit {
            let matches = findMatches(pixels: pixels, width: width)
            let best = bestCoding(pixels: pixels, width: width, matches: matches, imagePixels: pixels.count)
            return Coded(cacheBits: best.cacheBits, matches: best.copies ? matches : [], histograms: best.histograms,
                         bits: best.cost)
        }
        let choice = chooseCoding(pixels: pixels, width: width)
        let matches = choice.copies ? findMatches(pixels: pixels, width: width) : []
        return coded(pixels: pixels, width: width, matches: matches, cacheBits: choice.cacheBits)
    }

    /// The stream for `pixels` with the copies in `matches` and a colour cache of `cacheBits` bits, counted and costed
    /// as the main image.
    static func coded(pixels: [UInt32], width: Int, matches: [Match], cacheBits: Int) -> Coded {
        let histograms = self.histograms(pixels: pixels, width: width, matches: matches, cacheBits: cacheBits)
        let bits = EntropyImageWriter.cost(of: histograms, kind: .spatiallyCoded).total()
        return Coded(cacheBits: cacheBits, matches: matches, histograms: histograms, bits: bits)
    }

    /// The colour-cache size, from `cacheBitsCandidates`, and whether to write copies, that are estimated to code
    /// `pixels` in the fewest bits. For an image of more than `sampleLimit` pixels the estimate is made on a sample:
    /// `sampleBands` bands of whole rows, evenly spread down the image and `sampleLimit` pixels in all, with the
    /// symbols' share of the cost scaled up to the full image and the description of the codes (which does not grow
    /// with the image) counted once.
    static func chooseCoding(pixels: [UInt32], width: Int) -> (cacheBits: Int, copies: Bool) {
        let sample = sampleOfRows(of: pixels, width: width)
        let matches = findMatches(pixels: sample, width: width)
        let best = bestCoding(pixels: sample, width: width, matches: matches, imagePixels: pixels.count)
        return (best.cacheBits, best.copies)
    }

    /// The pixels an estimate is made on: the whole image when it has `sampleLimit` pixels or fewer, otherwise
    /// `sampleBands` runs of whole rows, spread evenly from the first rows to the last, `sampleLimit` pixels or a
    /// little fewer in all. The sample is as wide as the image, so it can be coded and costed like an image.
    static func sampleOfRows(of pixels: [UInt32], width: Int) -> [UInt32] {
        if pixels.count <= sampleLimit { return pixels }
        let rows = pixels.count / width
        let rowsPerBand = max(1, sampleLimit / width / sampleBands)
        var sample: [UInt32] = []
        sample.reserveCapacity(rowsPerBand * width * sampleBands)
        for band in 0..<sampleBands {
            let firstRow = (rows - rowsPerBand) * band / (sampleBands - 1)
            sample.append(contentsOf: pixels[(firstRow * width)..<((firstRow + rowsPerBand) * width)])
        }
        return sample
    }

    /// The cheapest cache size for these pixels, with copies or without, and its counts and cost. `imagePixels` is how
    /// many pixels the real image has, which is more than `pixels` when those are a sample. Only the counts are kept:
    /// each candidate's symbols are counted as they are made, and none is stored.
    private static func bestCoding(
        pixels: [UInt32], width: Int, matches: [Match], imagePixels: Int
    ) -> (cacheBits: Int, copies: Bool, histograms: EntropyImageWriter.Histograms, cost: Int) {
        let scale = Double(imagePixels) / Double(max(1, pixels.count))
        var best: (cacheBits: Int, copies: Bool, histograms: EntropyImageWriter.Histograms, cost: Int)?
        for bits in cacheBitsCandidates {
            // Without any copy found, the two forms are the same stream: the second is not made.
            for copies in matches.isEmpty ? [true] : [true, false] {
                let histograms = self.histograms(pixels: pixels, width: width, matches: copies ? matches : [],
                                                 cacheBits: bits)
                let cost = EntropyImageWriter.cost(of: histograms, kind: .spatiallyCoded)
                    .total(symbolBitsScaledBy: scale)
                if best == nil || cost < best!.cost { best = (bits, copies, histograms, cost) }
            }
        }
        return best!
    }
}
