import Foundation
import Testing
@testable import CSWebP

struct PrefixCodeTests {
    /// The Kraft sum of `lengths` in units of 2^-limit: exactly `1 << limit` for a complete tree.
    private static func kraftSum(_ lengths: [UInt8], limit: Int) -> Int {
        lengths.reduce(0) { $0 + ($1 > 0 ? 1 << (limit - Int($1)) : 0) }
    }

    private static func fibonacciHistogram(count: Int) -> [Int] {
        var histogram = [1, 1]
        while histogram.count < count {
            histogram.append(histogram[histogram.count - 1] + histogram[histogram.count - 2])
        }
        return Array(histogram.prefix(count))
    }

    // MARK: Code lengths

    @Test func lengthsFormACompleteTreeForTwoOrMoreSymbols() {
        var rng = SeededGenerator(seed: 4)
        for round in 0..<300 {
            let alphabet = [19, 40, 256, 280][round % 4]
            let used = Int.random(in: 2...alphabet, using: &rng)
            var histogram = [Int](repeating: 0, count: alphabet)
            for symbol in (0..<alphabet).shuffled(using: &rng).prefix(used) {
                histogram[symbol] = Int.random(in: 1...(round % 2 == 0 ? 5 : 100_000), using: &rng)
            }
            let lengths = PrefixCode.lengths(for: histogram, maxLength: 15)
            #expect(lengths.count == alphabet)
            #expect(PrefixCodeTests.kraftSum(lengths, limit: 15) == 1 << 15, "round \(round)")
            #expect(zip(histogram, lengths).allSatisfy { ($0 > 0) == ($1 > 0) }, "round \(round)")
            #expect((lengths.max() ?? 0) <= 15)
        }
    }

    @Test func aSkewedHistogramGetsShortCodesForFrequentSymbols() {
        let lengths = PrefixCode.lengths(for: [1000, 1, 1, 1, 1], maxLength: 15)
        #expect(lengths[0] == 1)
        #expect(lengths[1...].allSatisfy { $0 >= 3 })
    }

    @Test func aFibonacciHistogramStaysWithinFifteenBits() {
        // Counts 1, 1, 2, 3, 5, ...: an unrestricted Huffman code is 39 bits deep for 40 symbols.
        let histogram = PrefixCodeTests.fibonacciHistogram(count: 40)
        let lengths = PrefixCode.lengths(for: histogram, maxLength: 15)
        #expect(lengths.max() == 15)
        #expect(PrefixCodeTests.kraftSum(lengths, limit: 15) == 1 << 15)
        // The most frequent symbol keeps the shortest code.
        #expect(lengths[39] == lengths.min())
    }

    @Test func aFibonacciHistogramOfTheWholeLargestAlphabetStaysWithinFifteenBits() {
        // 256 + 24 + 2048 symbols, counts growing so fast an unrestricted code would be hundreds of bits deep.
        var histogram = [Int](repeating: 0, count: 2328)
        let fibonacci = PrefixCodeTests.fibonacciHistogram(count: 80)
        for (index, count) in fibonacci.enumerated() { histogram[index * 29] = count }
        for index in 0..<2328 where histogram[index] == 0 { histogram[index] = 1 }
        let lengths = PrefixCode.lengths(for: histogram, maxLength: 15)
        #expect((lengths.max() ?? 0) <= 15)
        #expect(PrefixCodeTests.kraftSum(lengths, limit: 15) == 1 << 15)
    }

    @Test func theCodeLengthCodeStaysWithinSevenBits() {
        // 19 symbols with Fibonacci counts would reach 18 bits unrestricted; the code-length code's own lengths are
        // stored in 3 bits each.
        let histogram = PrefixCodeTests.fibonacciHistogram(count: 19)
        let lengths = PrefixCode.lengths(for: histogram, maxLength: 7)
        #expect(lengths.max() == 7)
        #expect(PrefixCodeTests.kraftSum(lengths, limit: 7) == 1 << 7)
    }

    @Test func theLimitedCodeCostsNoMoreThanAnyOtherLimitedCode() {
        // Brute force: every length assignment on a few symbols that completes the tree within the limit.
        func cheapest(_ histogram: [Int], limit: Int) -> Int {
            var best = Int.max
            func search(_ index: Int, _ kraft: Int, _ cost: Int) {
                if kraft > 1 << limit { return }
                if index == histogram.count {
                    if kraft == 1 << limit { best = min(best, cost) }
                    return
                }
                for length in 1...limit {
                    search(index + 1, kraft + (1 << (limit - length)), cost + histogram[index] * length)
                }
            }
            search(0, 0, 0)
            return best
        }
        var rng = SeededGenerator(seed: 12)
        for round in 0..<60 {
            let symbols = Int.random(in: 2...7, using: &rng)
            let histogram = (0..<symbols).map { _ in Int.random(in: 1...(round % 3 == 0 ? 3 : 40), using: &rng) }
            var smallest = 1
            while 1 << smallest < symbols { smallest += 1 }
            let limit = Int.random(in: smallest...5, using: &rng)
            let lengths = PrefixCode.lengths(for: histogram, maxLength: limit)
            let cost = zip(histogram, lengths).reduce(0) { $0 + $1.0 * Int($1.1) }
            #expect(cost == cheapest(histogram, limit: limit), "histogram \(histogram), limit \(limit)")
            #expect((lengths.max() ?? 0) <= UInt8(limit))
        }
    }

    @Test func twoUsedSymbolsGetOneBitEach() {
        let lengths = PrefixCode.lengths(for: [0, 9, 0, 0, 4], maxLength: 15)
        #expect(lengths == [0, 1, 0, 0, 1])
    }

    @Test func oneUsedSymbolBelow256IsASingleLeaf() {
        let lengths = PrefixCode.lengths(for: [0, 0, 7, 0], maxLength: 15)
        #expect(lengths == [0, 0, 1, 0])
        #expect(PrefixCode.lengths(for: [0, 0, 0, 0], maxLength: 15) == [0, 0, 0, 0])
    }

    @Test func oneUsedSymbolFrom256UpIsAlsoASingleLeaf() {
        // No partner symbol is added: a lone symbol of 300 gets exactly one length, 1.
        var histogram = [Int](repeating: 0, count: 2328)
        histogram[300] = 12
        let lengths = PrefixCode.lengths(for: histogram, maxLength: 15)
        #expect(lengths.filter { $0 > 0 }.count == 1)
        #expect(lengths[300] == 1)
    }

    @Test func anEmptyHistogramGivesNoLengths() {
        #expect(PrefixCode.lengths(for: [], maxLength: 15).isEmpty)
        let nothing = [Int](repeating: 0, count: 40)
        #expect(PrefixCode.lengths(for: nothing, maxLength: 15) == [UInt8](repeating: 0, count: 40))
    }

    // MARK: Canonical codes

    @Test func canonicalCodesFollowTheWorkedExample() {
        // The canonical assignment of RFC 1951 section 3.2.2, which WebP's canonical prefix codes use too: symbols A-H
        // with lengths 3,3,3,3,3,2,4,4 get 010, 011, 100, 101, 110, 00, 1110, 1111 (read from the first bit). The
        // writer emits the first bit of a code first, least-significant first, so each code comes back bit-reversed.
        let codes = PrefixCode.canonicalCodes(lengths: [3, 3, 3, 3, 3, 2, 4, 4])
        #expect(codes == [0b010, 0b110, 0b001, 0b101, 0b011, 0b00, 0b0111, 0b1111])
    }

    @Test func shortCodesComeFirstAndTiesGoBySymbolOrder() {
        // Lengths 2,1,3,3: symbol 1 is "0", symbol 0 is "10", symbol 2 is "110", symbol 3 is "111".
        #expect(PrefixCode.canonicalCodes(lengths: [2, 1, 3, 3]) == [0b01, 0b0, 0b011, 0b111])
    }

    @Test func unusedSymbolsHaveCodeZero() {
        #expect(PrefixCode.canonicalCodes(lengths: [0, 1, 0, 1]) == [0, 0, 0, 1])
    }

    @Test func canonicalCodesArePrefixFreeAndUseTheirLengths() {
        var rng = SeededGenerator(seed: 21)
        for _ in 0..<40 {
            var histogram = [Int](repeating: 0, count: 60)
            for symbol in 0..<60 where Int.random(in: 0..<3, using: &rng) != 0 {
                histogram[symbol] = Int.random(in: 1...500, using: &rng)
            }
            let lengths = PrefixCode.lengths(for: histogram, maxLength: 15)
            guard lengths.filter({ $0 > 0 }).count >= 2 else { continue }
            let codes = PrefixCode.canonicalCodes(lengths: lengths)
            // Compare as bit strings from the first bit: undo the reversal.
            let strings: [String] = lengths.indices.compactMap { symbol in
                let length = Int(lengths[symbol])
                guard length > 0 else { return nil }
                #expect(Int(codes[symbol]) < 1 << length)
                let bits = (0..<length).map { (Int(codes[symbol]) >> $0) & 1 == 1 ? Character("1") : Character("0") }
                return String(bits)
            }
            for (index, code) in strings.enumerated() {
                for other in strings.indices where other != index {
                    #expect(!strings[other].hasPrefix(code), "\(code) is a prefix of \(strings[other])")
                }
            }
        }
    }

    // MARK: Writing a code

    private static func writeAndRead(_ lengths: [UInt8]) throws -> (read: [UInt8], bitsWritten: Int, bitsRead: Int) {
        let writer = BitWriter()
        PrefixCode.write(lengths: lengths, to: writer)
        var reader = SpecBitReader(writer.bytes())
        let read = try SpecPrefixCode.readLengths(&reader, alphabetSize: lengths.count)
        return (read, writer.bitCount, reader.bitsRead)
    }

    @Test func theSimpleFormForAnEmptyAlphabetIsOneSymbolZero() {
        let writer = BitWriter()
        PrefixCode.write(lengths: [UInt8](repeating: 0, count: 40), to: writer)
        // is_simple=1, num_symbols-1=0, is_first_8bits=0, symbol 0 in 1 bit.
        #expect(writer.bitCount == 4)
        #expect(writer.bytes() == [0b0001])
    }

    @Test func theSimpleFormNamesASmallSymbolInOneBitAndALargeOneInEight() {
        let one = BitWriter()
        PrefixCode.write(lengths: [0, 1, 0, 0], to: one)
        // is_simple=1, num_symbols-1=0, is_first_8bits=0, symbol 1.
        #expect(one.bitCount == 4)
        #expect(one.bytes() == [0b1001])

        let large = BitWriter()
        PrefixCode.write(lengths: [UInt8](repeating: 0, count: 5) + [1], to: large)
        // is_simple=1, num_symbols-1=0, is_first_8bits=1, then 5 in 8 bits.
        #expect(large.bitCount == 11)
        #expect(large.bytes() == [0b0010_1101, 0b0])
    }

    @Test func theSimpleFormListsTwoSymbolsSmallestFirst() throws {
        var lengths = [UInt8](repeating: 0, count: 256)
        lengths[200] = 1
        lengths[3] = 1
        let writer = BitWriter()
        PrefixCode.write(lengths: lengths, to: writer)
        // is_simple=1, num_symbols-1=1, is_first_8bits=1, symbol 3 in 8 bits, symbol 200 in 8 bits.
        #expect(writer.bitCount == 19)
        var reader = SpecBitReader(writer.bytes())
        #expect(reader.read(1) == 1)
        #expect(reader.read(1) == 1)
        #expect(reader.read(1) == 1)
        #expect(reader.read(8) == 3)
        #expect(reader.read(8) == 200)
    }

    @Test func aSymbolFrom256UpForcesTheNormalForm() throws {
        var lengths = [UInt8](repeating: 0, count: 280)
        lengths[0] = 1
        lengths[270] = 1
        let writer = BitWriter()
        PrefixCode.write(lengths: lengths, to: writer)
        var reader = SpecBitReader(writer.bytes())
        #expect(reader.read(1) == 0, "the normal form starts with is_simple = 0")
        var again = SpecBitReader(writer.bytes())
        #expect(try SpecPrefixCode.readLengths(&again, alphabetSize: 280) == lengths)
        // Two symbols in a long alphabet are mostly a run of zeros: the repeat codes keep that short.
        #expect(writer.bitCount < 120)
    }

    @Test func normalCodesReadBackToTheLengthsThatWereWritten() throws {
        var rng = SeededGenerator(seed: 33)
        for round in 0..<120 {
            let alphabet = [40, 256, 280, 2328][round % 4]
            let used = Int.random(in: 3...min(alphabet, round % 3 == 0 ? 6 : alphabet), using: &rng)
            var histogram = [Int](repeating: 0, count: alphabet)
            for symbol in (0..<alphabet).shuffled(using: &rng).prefix(used) {
                histogram[symbol] = Int.random(in: 1...(round % 2 == 0 ? 20 : 1_000_000), using: &rng)
            }
            let lengths = PrefixCode.lengths(for: histogram, maxLength: 15)
            let result = try PrefixCodeTests.writeAndRead(lengths)
            #expect(result.read == lengths, "round \(round)")
            #expect(result.bitsRead == result.bitsWritten, "round \(round)")
        }
    }

    @Test func aFlatAlphabetOfSameLengthSymbolsRoundTrips() throws {
        // 256 equally frequent symbols all get length 8: one repeated length, the case for repeat code 16.
        let lengths = PrefixCode.lengths(for: [Int](repeating: 10, count: 256), maxLength: 15)
        #expect(lengths == [UInt8](repeating: 8, count: 256))
        let result = try PrefixCodeTests.writeAndRead(lengths)
        #expect(result.read == lengths)
        #expect(result.bitsRead == result.bitsWritten)
    }

    @Test func manyDistinctLengthsAndLongZeroRunsRoundTrip() throws {
        // Thirty symbols spread over 280, Fibonacci counts: lengths from 1 to 15 with zero runs between them, so
        // the code-length code uses most of its alphabet.
        var spread = [Int](repeating: 0, count: 280)
        for (index, count) in PrefixCodeTests.fibonacciHistogram(count: 30).enumerated() {
            spread[index * 9 + 1] = count
        }
        let lengths = PrefixCode.lengths(for: spread, maxLength: 15)
        #expect(Set(lengths.filter { $0 > 0 }).count >= 10)
        let result = try PrefixCodeTests.writeAndRead(lengths)
        #expect(result.read == lengths)
        #expect(result.bitsRead == result.bitsWritten)
    }

    @Test func aLoneSymbolOf300IsWrittenInTheNormalFormAndCostsNoBitsPerOccurrence() throws {
        // RFC 9649 section 3.7.2.1: a single leaf is a complete tree. The simple form can't name a symbol of 256 or
        // more, so the normal form is used with every length 0 except this symbol's, which is 1.
        var histogram = [Int](repeating: 0, count: 280 + 2048)
        histogram[300] = 1000
        let lengths = PrefixCode.lengths(for: histogram, maxLength: 15)
        #expect(lengths.filter { $0 == 1 }.count == 1 && lengths.filter { $0 > 0 }.count == 1)
        #expect(lengths[300] == 1)

        let writer = BitWriter()
        PrefixCode.write(lengths: lengths, to: writer)
        let headerBits = writer.bitCount
        var reader = SpecBitReader(writer.bytes())
        #expect(reader.read(1) == 0, "the normal form starts with is_simple = 0")
        var again = SpecBitReader(writer.bytes())
        #expect(try SpecPrefixCode.readLengths(&again, alphabetSize: lengths.count) == lengths)
        #expect(again.bitsRead == headerBits)

        let encoder = PrefixCode.Encoder(lengths: lengths)
        #expect(encoder.isSingleLeaf)
        for _ in 0..<10 { encoder.emit(300, to: writer) }
        #expect(writer.bitCount == headerBits, "ten occurrences of a lone symbol emit 0 bits")
    }

    @Test func aLoneSymbolBelow256StaysInTheSimpleFormAndCostsNoBitsPerOccurrence() {
        var histogram = [Int](repeating: 0, count: 280)
        histogram[200] = 5
        let lengths = PrefixCode.lengths(for: histogram, maxLength: 15)
        let writer = BitWriter()
        PrefixCode.write(lengths: lengths, to: writer)
        // is_simple=1, num_symbols-1=0, is_first_8bits=1, then 200 in 8 bits.
        #expect(writer.bitCount == 11)
        let encoder = PrefixCode.Encoder(lengths: lengths)
        for _ in 0..<10 { encoder.emit(200, to: writer) }
        #expect(writer.bitCount == 11)
    }

    @Test func imageIOReadsASingleLeafInTheNormalForm() throws {
        // A 3x2 image of one colour, written by hand: every code is a single leaf, so the pixels take no bits at all.
        // The green code is a single leaf written in the normal form, the others in the simple form.
        func file(greenInNormalForm: Bool) -> Data {
            let writer = BitWriter()
            Container.writeHeader(width: 3, height: 2, alphaIsUsed: false, to: writer)
            writer.write(0, bits: 1)  // no transform
            writer.write(0, bits: 1)  // no colour cache
            writer.write(0, bits: 1)  // one prefix code group
            var green = [UInt8](repeating: 0, count: 280)
            green[7] = 1
            if greenInNormalForm {
                PrefixCode.writeNormal(lengths: green, to: writer)
            } else {
                PrefixCode.write(lengths: green, to: writer)
            }
            for symbol in [200, 9, 255] {
                var lengths = [UInt8](repeating: 0, count: 256)
                lengths[symbol] = 1
                PrefixCode.write(lengths: lengths, to: writer)
            }
            PrefixCode.write(lengths: [UInt8](repeating: 0, count: 40), to: writer)
            return Container.riffFile(payload: writer.bytes())
        }
        for normal in [false, true] {
            let decoded = try RoundTrip.decode(file(greenInNormalForm: normal)).image
            #expect(decoded.width == 3 && decoded.height == 2)
            #expect(decoded.distinctColors == [Pixel(200, 7, 9, 255)], "normal form: \(normal)")
        }
    }

    // MARK: Writing symbols

    @Test func symbolsWrittenWithACodeDecodeBackThroughItsLengths() throws {
        var rng = SeededGenerator(seed: 77)
        for round in 0..<30 {
            let alphabet = [40, 256, 280][round % 3]
            let usedSymbols = Array((0..<alphabet).shuffled(using: &rng).prefix([1, 2, 3, 9, 100][round % 5]))
            let used = usedSymbols.count
            var histogram = [Int](repeating: 0, count: alphabet)
            var stream: [Int] = []
            for _ in 0..<500 {
                let symbol = usedSymbols[Int.random(in: 0..<used, using: &rng)]
                histogram[symbol] += 1
                stream.append(symbol)
            }
            let lengths = PrefixCode.lengths(for: histogram, maxLength: 15)
            let encoder = PrefixCode.Encoder(lengths: lengths)
            let writer = BitWriter()
            PrefixCode.write(lengths: lengths, to: writer)
            for symbol in stream { encoder.emit(symbol, to: writer) }

            var reader = SpecBitReader(writer.bytes())
            let readLengths = try SpecPrefixCode.readLengths(&reader, alphabetSize: alphabet)
            let decoder = try SpecCanonicalCode(lengths: readLengths)
            for (position, expected) in stream.enumerated() {
                let decoded = try decoder.decode(&reader)
                #expect(decoded == expected, "round \(round), symbol \(position)")
                if decoded != expected { break }
            }
        }
    }

    @Test func aCodeWithOneUsedSymbolWritesNoBitsForIt() {
        var histogram = [Int](repeating: 0, count: 256)
        histogram[77] = 1000
        let lengths = PrefixCode.lengths(for: histogram, maxLength: 15)
        let encoder = PrefixCode.Encoder(lengths: lengths)
        let writer = BitWriter()
        PrefixCode.write(lengths: lengths, to: writer)
        let headerBits = writer.bitCount
        for _ in 0..<1000 { encoder.emit(77, to: writer) }
        #expect(writer.bitCount == headerBits)
    }

    @Test func anEmptyCodeNeverWritesASymbol() {
        let encoder = PrefixCode.Encoder(lengths: [UInt8](repeating: 0, count: 40))
        #expect(encoder.isSingleLeaf)
    }

    @Test func emittingASymbolTheCodeDoesNotContainIsRefusedEvenForASingleLeaf() async {
        // A single-leaf code writes no bits for its one symbol, which is why it must not quietly accept another.
        await #expect(processExitsWith: .failure) {
            var histogram = [Int](repeating: 0, count: 256)
            histogram[77] = 10
            let encoder = PrefixCode.Encoder(lengths: PrefixCode.lengths(for: histogram, maxLength: 15))
            encoder.emit(78, to: BitWriter())
        }
        await #expect(processExitsWith: .failure) {
            PrefixCode.Encoder(lengths: [UInt8](repeating: 0, count: 40)).emit(3, to: BitWriter())
        }
        await #expect(processExitsWith: .failure) {
            let encoder = PrefixCode.Encoder(lengths: PrefixCode.lengths(for: [5, 0, 7, 1], maxLength: 15))
            encoder.emit(1, to: BitWriter())
        }
    }

    @Test func aSingleLeafStillAcceptsItsOwnSymbol() {
        var histogram = [Int](repeating: 0, count: 280)
        histogram[270] = 3
        let encoder = PrefixCode.Encoder(lengths: PrefixCode.lengths(for: histogram, maxLength: 15))
        let writer = BitWriter()
        encoder.emit(270, to: writer)
        #expect(writer.bitCount == 0)
    }
}
