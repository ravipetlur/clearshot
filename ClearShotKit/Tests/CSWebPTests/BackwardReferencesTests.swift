import Testing
@testable import CSWebP

struct BackwardReferencesTests {
    typealias Symbol = EntropyImageWriter.Symbol

    // MARK: Helpers

    /// What the matches claim must be true of the pixels themselves, with no decoder in between: sorted, apart,
    /// 3 to 4096 long, within the window, and each copy equal to its source (reading an overlapping source as the
    /// decoder does, pixel by pixel from the pixels already made).
    private static func problem(in matches: [BackwardReferences.Match], pixels: [UInt32]) -> String? {
        var end = 0
        for match in matches {
            guard match.position >= end else { return "match at \(match.position) overlaps the one before" }
            guard (3...4096).contains(match.length) else { return "length \(match.length) at \(match.position)" }
            guard match.distance >= 1, match.distance <= match.position,
                  match.distance <= DistanceCodes.maxDistance else {
                return "distance \(match.distance) at \(match.position)"
            }
            guard match.position + match.length <= pixels.count else {
                return "match at \(match.position) past the end"
            }
            for offset in 0..<match.length
            where pixels[match.position + offset] != pixels[match.position + offset - match.distance] {
                return "pixel \(match.position + offset) differs from the one \(match.distance) back"
            }
            end = match.position + match.length
        }
        return nil
    }

    private static func replay(_ symbols: [Symbol], pixels: [UInt32], width: Int, cacheBits: Int) throws -> [UInt32] {
        try SymbolReplay.pixels(of: symbols, width: width, count: pixels.count, cacheBits: cacheBits)
    }

    // MARK: Runs

    @Test func aRunLongerThan4096SplitsIntoMaximumLengthReferences() throws {
        let pixels = [UInt32](repeating: 0xFF20_4060, count: 10_000)
        let symbols = BackwardReferences.find(pixels: pixels, width: 100, cacheBits: 0)
        // The first pixel is a literal; the other 9 999 are copies, 4 096 at a time, then what is left.
        #expect(symbols.count == 4)
        #expect(symbols.first == .literal(0xFF20_4060))
        let lengths = symbols.dropFirst().map { symbol -> Int in
            guard case .backref(let length, let code) = symbol.form else { return -1 }
            // The source is the pixel before or the one above, both of the same colour.
            #expect([1, 100].contains(DistanceCodes.distance(forCode: code, width: 100)))
            return length
        }
        #expect(lengths == [4096, 4096, 1807])
        #expect(try Self.replay(symbols, pixels: pixels, width: 100, cacheBits: 0) == pixels)
    }

    @Test func aReferenceMayOverlapItsOwnSource() throws {
        // Distance 1, length 7: the copy reads pixels the same copy has just written.
        let pixels = [UInt32](repeating: 0xFFAA_BBCC, count: 8)
        let matches = BackwardReferences.findMatches(pixels: pixels, width: 8)
        #expect(matches == [BackwardReferences.Match(position: 1, length: 7, distance: 1)])
        // And a two-colour stripe, whose source starts 2 back: distance 2, length 8.
        let stripes: [UInt32] = [1, 2, 1, 2, 1, 2, 1, 2, 1, 2]
        let stripeMatches = BackwardReferences.findMatches(pixels: stripes, width: 10)
        #expect(stripeMatches == [BackwardReferences.Match(position: 2, length: 8, distance: 2)])
    }

    @Test func noMatchIsShorterThanThree() {
        let pixels: [UInt32] = [5, 6, 5, 6, 9, 5, 6, 8, 1, 5, 6, 3]
        #expect(BackwardReferences.findMatches(pixels: pixels, width: 12).isEmpty)
        #expect(BackwardReferences.findMatches(pixels: [], width: 1).isEmpty)
        #expect(BackwardReferences.findMatches(pixels: [7], width: 1).isEmpty)
        #expect(BackwardReferences.findMatches(pixels: [7, 7], width: 2).isEmpty)
    }

    // MARK: Search quality

    @Test func theLongestCandidateInTheChainIsChosenNotTheNewestOne() {
        // The same four pixels start three earlier places; only the oldest continues for long.
        let head: [UInt32] = [10, 11, 12]
        var pixels: [UInt32] = []
        pixels += head + [20, 21, 22, 23, 24, 25]  // 0..8: the long one
        pixels += [90, 91, 92, 93]
        pixels += head + [70, 71]  // 13..17: a short one
        pixels += [94, 95, 96, 97]
        pixels += head + [80, 81]  // 22..26: a shorter one, the newest
        pixels += [98, 99, 100, 101]
        let target = pixels.count
        pixels += head + [20, 21, 22, 23, 24, 25]
        let matches = BackwardReferences.findMatches(pixels: pixels, width: 1000)
        let last = matches.last
        #expect(last == BackwardReferences.Match(position: target, length: 9, distance: target))
        #expect(Self.problem(in: matches, pixels: pixels) == nil)
    }

    @Test func aLongerMatchOneLaterBeatsAShorterOneNow() {
        // At `target`, a b c has an earlier copy that stops after 3 pixels; one pixel on, b c x0..x7 has an earlier
        // copy 10 long. Taking the second saves more than the first: the pixel at `target` is left to a literal.
        let a: UInt32 = 1000, b: UInt32 = 1001, c: UInt32 = 1002
        let x: [UInt32] = (0..<8).map { 2000 + $0 }
        var pixels: [UInt32] = [a, b, c, 7000]
        pixels += [b, c] + x
        pixels += (0..<30).map { 3000 + $0 }
        let target = pixels.count
        pixels += [a, b, c] + x
        let matches = BackwardReferences.findMatches(pixels: pixels, width: 1000)
        let atTarget = matches.filter { $0.position >= target }
        #expect(atTarget.count == 1)
        #expect(atTarget.first?.position == target + 1)
        #expect(atTarget.first?.length == 10)
        #expect(Self.problem(in: matches, pixels: pixels) == nil)
    }

    @Test func aMatchAtTheLargestDistanceIsUsedAndOneFurtherIsNot() throws {
        // A 1 126 400-pixel image of noise, with a 40-pixel block repeated exactly `maxDistance` and `maxDistance + 1`
        // after it. Only the first copy can be a reference: the largest distance code is 1 048 576, distance 1 048 456.
        let width = 1024
        let count = 1100 * width
        var rng = SeededGenerator(seed: 21)
        var base = (0..<count).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) }
        let block = Array(base[100..<140])
        for (offset, value) in block.enumerated() {
            base[100 + DistanceCodes.maxDistance + offset] = value
        }
        let matches = BackwardReferences.findMatches(pixels: base, width: width)
        #expect(Self.problem(in: matches, pixels: base) == nil)
        let farthest = BackwardReferences.Match(position: 100 + DistanceCodes.maxDistance, length: 40,
                                                distance: DistanceCodes.maxDistance)
        #expect(matches.contains(farthest))
        let symbols = BackwardReferences.symbols(pixels: base, width: width, matches: matches, cacheBits: 0)
        #expect(symbols.contains(.backref(length: 40, distanceCode: 1_048_576)))
        #expect(try Self.replay(symbols, pixels: base, width: width, cacheBits: 0) == base)

        var farther = (0..<count).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) }
        for (offset, value) in farther[100..<140].enumerated() {
            farther[100 + DistanceCodes.maxDistance + 1 + offset] = value
        }
        #expect(BackwardReferences.findMatches(pixels: farther, width: width).isEmpty)
    }

    // MARK: Plane codes

    @Test func repeatedTilesProduceReferencesWithPlaneCodes() throws {
        let image = Fixtures.repeatedTiles(120, 60)
        let pixels = image.argbPixels
        let symbols = BackwardReferences.find(pixels: pixels, width: 120, cacheBits: 0)
        let planeCoded = symbols.filter { if case .backref(_, let code) = $0.form { code <= 120 } else { false } }
        let plain = symbols.filter { if case .backref(_, let code) = $0.form { code > 120 } else { false } }
        #expect(planeCoded.count > 10, "references to the neighbourhood use the 1 to 120 codes")
        #expect(!plain.isEmpty, "and the farther ones the offset codes")
        #expect(try Self.replay(symbols, pixels: pixels, width: 120, cacheBits: 0) == pixels)
    }

    @Test(arguments: [1, 2, 3, 8])
    func tilesInNarrowImagesReplayToTheExactPixels(_ width: Int) throws {
        let pixels = Fixtures.repeatedTiles(width, 60).argbPixels
        let symbols = BackwardReferences.find(pixels: pixels, width: width, cacheBits: 0)
        #expect(try Self.replay(symbols, pixels: pixels, width: width, cacheBits: 0) == pixels)
    }

    // MARK: The cache

    @Test func withoutACacheNoCacheSymbolIsMade() {
        let pixels = Fixtures.palette(16, 60, 40).argbPixels
        for symbol in BackwardReferences.find(pixels: pixels, width: 60, cacheBits: 0) {
            if case .cacheIndex = symbol.form { Issue.record("a cache index without a cache") }
        }
    }

    @Test(arguments: [2, 4, 6, 8, 10])
    func withACacheRepeatedColoursBecomeIndicesInRange(_ bits: Int) throws {
        // Colours drawn at random from a dozen: no long repeats, so the pixels that are not references are mostly hits.
        var rng = SeededGenerator(seed: UInt64(bits))
        let colours = (0..<12).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) | 0xFF00_0000 }
        let pixels = (0..<3000).map { _ in colours[Int.random(in: 0..<colours.count, using: &rng)] }
        let symbols = BackwardReferences.find(pixels: pixels, width: 60, cacheBits: bits)
        var indices = 0
        for symbol in symbols {
            if case .cacheIndex(let index) = symbol.form {
                #expect(index >= 0 && index < 1 << bits)
                indices += 1
            }
        }
        #expect(indices > 200)
        #expect(try Self.replay(symbols, pixels: pixels, width: 60, cacheBits: bits) == pixels)
    }

    @Test func aTransparentBlackFirstPixelMayBeACacheHit() throws {
        // The cache starts out all zero, so colour 0 is "in" it before anything is inserted (RFC 9649, 3.6.2.3).
        let pixels: [UInt32] = [0, 0xFF11_2233, 0, 0xFF11_2233, 0]
        let symbols = BackwardReferences.find(pixels: pixels, width: 5, cacheBits: 3)
        #expect(symbols.first == .cacheIndex(ColorCache.hash(0, bits: 3)))
        #expect(try Self.replay(symbols, pixels: pixels, width: 5, cacheBits: 3) == pixels)
    }

    @Test func theCacheIsUpdatedWithEveryPixelACopyProduces() throws {
        // R, then S (whose colours push some of R's out of the 64 slots), then a copy of R (which pushes some of S's
        // out again), then S in a new order. An encoder that forgot to put the copied pixels into the cache would still
        // believe those S colours are in their slots and send indices that a decoder resolves to R's colours.
        var rng = SeededGenerator(seed: 5)
        let r = (0..<100).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) | 0xFF00_0000 }
        let s = (0..<100).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) | 0xFF00_0000 }
        let pixels = r + s + r + s.shuffled(using: &rng)
        let symbols = BackwardReferences.find(pixels: pixels, width: 40, cacheBits: 6)
        #expect(symbols.contains(.backref(length: 100, distanceCode: DistanceCodes.code(forDistance: 200, width: 40))))
        #expect(symbols.contains { if case .cacheIndex = $0.form { true } else { false } })
        #expect(try Self.replay(symbols, pixels: pixels, width: 40, cacheBits: 6) == pixels)
    }

    // MARK: The cache size

    @Test func noiseGetsNoCache() {
        let pixels = Fixtures.randomNoise(64, 64, seed: 3).argbPixels
        #expect(BackwardReferences.chooseCacheBits(pixels: pixels, width: 64) == 0)
    }

    @Test func aFewRepeatingColoursGetACache() {
        var rng = SeededGenerator(seed: 8)
        let colours = (0..<20).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) | 0xFF00_0000 }
        let pixels = (0..<8000).map { _ in colours[Int.random(in: 0..<colours.count, using: &rng)] }
        let bits = BackwardReferences.chooseCacheBits(pixels: pixels, width: 100)
        #expect(BackwardReferences.cacheBitsCandidates.contains(bits))
        #expect(bits >= 4, "20 colours want at least 16 slots, got \(bits) bits")
    }

    @Test(arguments: [3, 12, 20])
    func fewRandomColoursAreCodedNoWorseThanEitherWithCopiesOrWithTheCacheAlone(_ colourCount: Int) {
        // Few colours in no order: the cache says each pixel in a few bits, while a copy of three or four pixels costs
        // a length, a distance and their extra bits. The choice has to be free to leave the copies out.
        var rng = SeededGenerator(seed: UInt64(colourCount))
        let colours = (0..<colourCount).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) | 0xFF00_0000 }
        let pixels = (0..<8000).map { _ in colours[Int.random(in: 0..<colours.count, using: &rng)] }
        func cost(_ symbols: [Symbol], _ bits: Int) -> Int {
            EntropyImageWriter.cost(of: symbols, cacheBits: bits, kind: .spatiallyCoded).total()
        }
        var withCopies = Int.max, cacheAlone = Int.max
        let matches = BackwardReferences.findMatches(pixels: pixels, width: 100)
        for bits in BackwardReferences.cacheBitsCandidates {
            withCopies = min(withCopies, cost(BackwardReferences.symbols(pixels: pixels, width: 100, matches: matches,
                                                                          cacheBits: bits), bits))
            cacheAlone = min(cacheAlone, cost(BackwardReferences.symbols(pixels: pixels, width: 100, matches: [],
                                                                          cacheBits: bits), bits))
        }
        let (symbols, bits) = BackwardReferences.findWithBestCache(pixels: pixels, width: 100)
        let chosen = cost(symbols, bits)
        #expect(chosen == min(withCopies, cacheAlone), "chosen \(chosen), copies \(withCopies), cache alone \(cacheAlone)")
        #expect(cacheAlone < withCopies, "the content is one where the cache alone is cheaper: \(cacheAlone) against \(withCopies)")
        #expect((try? Self.replay(symbols, pixels: pixels, width: 100, cacheBits: bits)) == pixels)
    }

    @Test func theCandidatesAreZeroAndTheEvenNumbersToTen() {
        #expect(BackwardReferences.cacheBitsCandidates == [0, 2, 4, 6, 8, 10])
    }

    @Test func aLargeImageIsJudgedOnASampleButCodedWhole() throws {
        // More pixels than the sample holds: the choice comes from bands of rows, the symbols from the whole image.
        var rng = SeededGenerator(seed: 12)
        let colours = (0..<10).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) | 0xFF00_0000 }
        let width = 700, height = 400
        let pixels = (0..<(width * height)).map { _ in colours[Int.random(in: 0..<colours.count, using: &rng)] }
        #expect(pixels.count > BackwardReferences.sampleLimit)
        let (symbols, bits) = BackwardReferences.findWithBestCache(pixels: pixels, width: width)
        #expect(bits > 0)
        // Ten colours in no order: the sample says the cache alone is cheapest, and the whole image follows it.
        #expect(!BackwardReferences.chooseCoding(pixels: pixels, width: width).copies)
        #expect(!symbols.contains { if case .backref = $0.form { true } else { false } })
        #expect(try Self.replay(symbols, pixels: pixels, width: width, cacheBits: bits) == pixels)
    }

    // MARK: The sample and the estimate

    @Test func anImageUpToTheSampleLimitIsItsOwnSample() {
        let pixels = Fixtures.noise(300, 200, seed: 2).argbPixels
        #expect(BackwardReferences.sampleOfRows(of: pixels, width: 300) == pixels)
    }

    @Test func aLargerImageIsSampledAsBandsOfWholeRowsFromTheFirstToTheLast() {
        let width = 700, height = 400
        let pixels = (0..<(width * height)).map { UInt32($0 / width) }  // every pixel holds its row number
        #expect(pixels.count > BackwardReferences.sampleLimit)
        let sample = BackwardReferences.sampleOfRows(of: pixels, width: width)
        #expect(sample.count <= BackwardReferences.sampleLimit)
        #expect(sample.count % width == 0, "whole rows")
        let rows = (0..<(sample.count / width)).map { sample[$0 * width] }
        for row in 0..<rows.count { #expect(sample[row * width..<(row + 1) * width].allSatisfy { $0 == rows[row] }) }
        #expect(rows.first == 0, "the first rows are in")
        #expect(rows.last == UInt32(height - 1), "and the last")
        #expect(Set(rows).count == rows.count, "bands do not overlap")
        // Four bands: three jumps between bands, the rest of the steps are one row.
        let jumps = zip(rows, rows.dropFirst()).filter { $1 != $0 + 1 }.count
        #expect(jumps == 3)
    }

    @Test func theCodedImageCarriesTheBitsWriteSpendsOnItsSymbols() {
        // Judged whole (a small image) and judged on a sample then coded whole (a larger one): either way the bits
        // are those of the whole stream, so a caller can compare two ways of preparing an image without costing again.
        var rng = SeededGenerator(seed: 4)
        let colours = (0..<10).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) | 0xFF00_0000 }
        let large = (0..<(700 * 400)).map { _ in colours[Int.random(in: 0..<colours.count, using: &rng)] }
        let cases: [(pixels: [UInt32], width: Int)] = [
            (Fixtures.uiScreenshot(200, 120).argbPixels, 200), (Fixtures.palette(20, 60, 40).argbPixels, 60),
            (large, 700),
        ]
        for (pixels, width) in cases {
            let coded = BackwardReferences.codedWithBestCache(pixels: pixels, width: width)
            // The symbols are not kept, so they are made again from the copies and the cache size it carries.
            let symbols = BackwardReferences.symbols(pixels: pixels, width: width, matches: coded.matches,
                                                     cacheBits: coded.cacheBits)
            let spent = EntropyImageWriter.cost(of: symbols, cacheBits: coded.cacheBits, kind: .spatiallyCoded).total()
            #expect(coded.bits == spent, "\(pixels.count) pixels")
            let counted = EntropyImageWriter.Histograms(counting: symbols, cacheBits: coded.cacheBits)
            #expect(coded.histograms.all == counted.all && coded.histograms.extraBits == counted.extraBits)
            #expect(coded.matches.isEmpty || coded.matches == BackwardReferences.findMatches(pixels: pixels, width: width),
                    "the copies are none, or all those found")
            let (hooked, bits) = BackwardReferences.findWithBestCache(pixels: pixels, width: width)
            #expect(hooked == symbols && bits == coded.cacheBits)
        }
    }

    // MARK: Every fixture

    @Test(arguments: Fixtures.catalogue + Fixtures.shapes)
    func theMatchesAreTrueAndTheSymbolsReplayToTheExactPixelsAtEveryCacheSize(_ fixture: Fixture) throws {
        let image = fixture.make()
        let pixels = image.argbPixels
        let matches = BackwardReferences.findMatches(pixels: pixels, width: image.width)
        #expect(Self.problem(in: matches, pixels: pixels) == nil, "\(fixture.name)")
        for bits in [0, 2, 6, 10] {
            let symbols = BackwardReferences.symbols(pixels: pixels, width: image.width, matches: matches,
                                                     cacheBits: bits)
            #expect(try Self.replay(symbols, pixels: pixels, width: image.width, cacheBits: bits) == pixels,
                    "\(fixture.name), \(bits) cache bits")
        }
        let (symbols, bits) = BackwardReferences.findWithBestCache(pixels: pixels, width: image.width)
        #expect(try Self.replay(symbols, pixels: pixels, width: image.width, cacheBits: bits) == pixels,
                "\(fixture.name), chosen cache")
    }

    @Test func findIsTheMatchesTurnedIntoSymbols() {
        let pixels = Fixtures.uiScreenshot(200, 120).argbPixels
        let matches = BackwardReferences.findMatches(pixels: pixels, width: 200)
        #expect(BackwardReferences.find(pixels: pixels, width: 200, cacheBits: 6)
            == BackwardReferences.symbols(pixels: pixels, width: 200, matches: matches, cacheBits: 6))
    }
}
