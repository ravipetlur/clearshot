import Foundation
import Testing
@testable import CSWebP

/// What `EntropyImageWriter.cost` says against what `write` spends, and the image form without the meta-prefix field,
/// which the palette and the predictor's tile image are written in.
struct EntropyImageWriterTests {
    typealias Symbol = EntropyImageWriter.Symbol

    /// The bits of a writer, first written first.
    private static func bits(of writer: BitWriter) -> [UInt8] {
        let bytes = writer.bytes()
        return (0..<writer.bitCount).map { (bytes[$0 / 8] >> UInt8($0 % 8)) & 1 }
    }

    private static func written(_ symbols: [Symbol], cacheBits: Int, kind: EntropyImageWriter.Kind) -> BitWriter {
        let writer = BitWriter()
        EntropyImageWriter.write(symbols, cacheBits: cacheBits, kind: kind, to: writer)
        return writer
    }

    // MARK: The estimate is the spend

    /// Streams of every shape the encoder makes: whole images with references and the cache, and the degenerate ones
    /// (one symbol, one colour throughout, no copies at all, nothing).
    private static func streams() -> [(name: String, symbols: [Symbol], cacheBits: Int)] {
        var list: [(String, [Symbol], Int)] = []
        let images: [(String, RGBAImage)] = [
            ("ui 160x90", Fixtures.uiScreenshot(160, 90)), ("noise 70x40", Fixtures.noise(70, 40, seed: 2)),
            ("random 50x30", Fixtures.randomNoise(50, 30, seed: 3)), ("palette 17", Fixtures.palette(17, 40, 30)),
            ("binary alpha", Fixtures.binaryAlpha(50, 40)), ("runs", Fixtures.runs(100, 80)),
            ("tiles", Fixtures.repeatedTiles(64, 40)),
        ]
        for (name, image) in images {
            let pixels = image.argbPixels
            for bits in [0, 1, 4, 8, 11] {
                list.append(("\(name), cache \(bits)",
                             BackwardReferences.find(pixels: pixels, width: image.width, cacheBits: bits), bits))
            }
            list.append(("\(name), literals", pixels.map(Symbol.literal), 0))
        }
        list.append(("one literal", [.literal(0xFF11_2233)], 0))
        list.append(("the same literal throughout", [Symbol](repeating: .literal(0xFF11_2233), count: 50), 0))
        list.append(("one copy", [.literal(7), .backref(length: 40, distanceCode: 1)], 0))
        list.append(("only a cache index", [.cacheIndex(3)], 4))
        list.append(("nothing", [], 0))
        list.append(("nothing, with a cache", [], 6))
        return list.map { (name: $0.0, symbols: $0.1, cacheBits: $0.2) }
    }

    @Test func theCostIsExactlyTheBitsWriteSpends() {
        for stream in Self.streams() {
            for kind in [EntropyImageWriter.Kind.spatiallyCoded, .entropyCoded] {
                let spent = Self.written(stream.symbols, cacheBits: stream.cacheBits, kind: kind).bitCount
                let cost = EntropyImageWriter.cost(of: stream.symbols, cacheBits: stream.cacheBits, kind: kind)
                #expect(cost.total() == spent, "\(stream.name), \(kind): estimated \(cost.total()), written \(spent)")
                #expect(cost.fixedBits + cost.symbolBits == spent)
            }
        }
    }

    @Test func theCostOfASampleScalesOnlyTheSymbolPart() {
        let pixels = Fixtures.uiScreenshot(160, 90).argbPixels
        let symbols = BackwardReferences.find(pixels: pixels, width: 160, cacheBits: 4)
        let cost = EntropyImageWriter.cost(of: symbols, cacheBits: 4, kind: .spatiallyCoded)
        #expect(cost.total(symbolBitsScaledBy: 1) == cost.total())
        #expect(cost.total(symbolBitsScaledBy: 2) == cost.fixedBits + 2 * cost.symbolBits)
        #expect(cost.total(symbolBitsScaledBy: 0) == cost.fixedBits)
    }

    @Test func writingWithTheCountsAlreadyMadeIsWritingWithoutThem() {
        // The counts that costed a stream are handed to `write` so that the stream is not counted twice.
        for stream in Self.streams() {
            for kind in [EntropyImageWriter.Kind.spatiallyCoded, .entropyCoded] {
                let counted = EntropyImageWriter.Histograms(counting: stream.symbols, cacheBits: stream.cacheBits)
                let with = BitWriter()
                EntropyImageWriter.write(stream.symbols, cacheBits: stream.cacheBits, kind: kind, histograms: counted, to: with)
                let without = Self.written(stream.symbols, cacheBits: stream.cacheBits, kind: kind)
                #expect(with.bytes() == without.bytes() && with.bitCount == without.bitCount, "\(stream.name), \(kind)")
                #expect(EntropyImageWriter.cost(of: counted, kind: kind).total() == with.bitCount, "\(stream.name)")
            }
        }
    }

    // MARK: A coded image is written from its pixels

    /// Images for the tests below, one of them (700 x 400) larger than the 2^18 pixels an estimate is made on whole, so
    /// that its choice is made on a sample and its stream coded after.
    private static func codedImages() -> [(name: String, image: RGBAImage)] {
        [("ui 160x90", Fixtures.uiScreenshot(160, 90)), ("noise 70x40", Fixtures.noise(70, 40, seed: 2)),
         ("random 50x30", Fixtures.randomNoise(50, 30, seed: 3)), ("runs 100x80", Fixtures.runs(100, 80)),
         ("tiles 64x40", Fixtures.repeatedTiles(64, 40)), ("ui 700x400", Fixtures.uiScreenshot(700, 400))]
    }

    @Test func aCodedImageIsWrittenFromItsPixelsAsItsSymbolsAre() {
        // `Coded` does not keep the symbols (a large image has one per pixel, 8 bytes each): they are made again from
        // the pixels, the copies and the cache size as the image is written. The file is the one its symbols make.
        for (name, image) in Self.codedImages() {
            let pixels = image.argbPixels
            let coded = BackwardReferences.codedWithBestCache(pixels: pixels, width: image.width)
            let symbols = BackwardReferences.symbols(pixels: pixels, width: image.width, matches: coded.matches,
                                                     cacheBits: coded.cacheBits)
            for kind in [EntropyImageWriter.Kind.spatiallyCoded, .entropyCoded] {
                let fromPixels = BitWriter()
                EntropyImageWriter.write(coded, pixels: pixels, width: image.width, kind: kind, to: fromPixels)
                let fromSymbols = BitWriter()
                EntropyImageWriter.write(symbols, cacheBits: coded.cacheBits, kind: kind, histograms: coded.histograms,
                                         to: fromSymbols)
                #expect(fromPixels.bytes() == fromSymbols.bytes() && fromPixels.bitCount == fromSymbols.bitCount,
                        "\(name), \(kind)")
            }
        }
    }

    @Test func theBitsACodedImageSaysItSpendsAreTheBitsItsWritingSpends() {
        for (name, image) in Self.codedImages() {
            let pixels = image.argbPixels
            let coded = BackwardReferences.codedWithBestCache(pixels: pixels, width: image.width)
            let writer = BitWriter()
            EntropyImageWriter.write(coded, pixels: pixels, width: image.width, kind: .spatiallyCoded, to: writer)
            #expect(coded.bits == writer.bitCount, "\(name): said \(coded.bits), spent \(writer.bitCount)")
        }
    }

    @Test(arguments: [0, 1, 6, 11])
    func countsMadeAsTheSymbolsAreGeneratedAreTheCountsOfTheSymbols(_ cacheBits: Int) {
        for (name, image) in Self.codedImages() where image.width * image.height <= 1 << 16 {
            let pixels = image.argbPixels
            let matches = BackwardReferences.findMatches(pixels: pixels, width: image.width)
            for copies in [matches, []] {
                let symbols = BackwardReferences.symbols(pixels: pixels, width: image.width, matches: copies,
                                                         cacheBits: cacheBits)
                let counted = EntropyImageWriter.Histograms(counting: symbols, cacheBits: cacheBits)
                let streamed = BackwardReferences.histograms(pixels: pixels, width: image.width, matches: copies,
                                                             cacheBits: cacheBits)
                #expect(streamed.all == counted.all && streamed.extraBits == counted.extraBits,
                        "\(name), cache \(cacheBits), \(copies.count) copies")
            }
        }
    }

    // MARK: Without the meta-prefix field

    @Test func anEntropyCodedImageIsAMainImageWithoutItsMetaPrefixBit() {
        // Same colour-cache field, same codes, same symbols; the one bit after the cache field is not there.
        for stream in Self.streams() where !stream.symbols.isEmpty {
            let main = Self.bits(of: Self.written(stream.symbols, cacheBits: stream.cacheBits, kind: .spatiallyCoded))
            let sub = Self.bits(of: Self.written(stream.symbols, cacheBits: stream.cacheBits, kind: .entropyCoded))
            let cacheField = stream.cacheBits > 0 ? 5 : 1
            #expect(sub.count + 1 == main.count, "\(stream.name)")
            #expect(Array(main[..<cacheField]) == Array(sub[..<cacheField]), "\(stream.name): colour cache field")
            #expect(main[cacheField] == 0, "\(stream.name): the main image's meta prefix is one code group")
            #expect(Array(main[(cacheField + 1)...]) == Array(sub[cacheField...]), "\(stream.name): the rest")
        }
    }

    @Test func theColourCacheFieldIsOneBitWithoutACacheAndFiveWithOne() {
        let none = Self.bits(of: Self.written([.literal(1)], cacheBits: 0, kind: .entropyCoded))
        #expect(none.first == 0)
        let sized = Self.bits(of: Self.written([.literal(1)], cacheBits: 6, kind: .entropyCoded))
        #expect(Array(sized.prefix(5)) == [1, 0, 1, 1, 0], "1, then 6 in four bits, lowest first")
    }

    // MARK: Decoded inside a transform

    /// A whole file made by hand around a palette transform, so that the colour table is the one image written in the
    /// entropy-coded form, and ImageIO reads it back. Four colours, `width_bits` 2.
    private static func handBuiltPaletteFile(
        colours: [UInt32], indexRows: [[Int]], tableSymbols: ([UInt32]) -> (symbols: [Symbol], cacheBits: Int)
    ) -> Data {
        let width = indexRows[0].count, height = indexRows.count
        let widthBits = colours.count <= 2 ? 3 : colours.count <= 4 ? 2 : colours.count <= 16 ? 1 : 0
        let writer = BitWriter()
        Container.writeHeader(width: width, height: height, alphaIsUsed: true, to: writer)
        writer.write(1, bits: 1)  // a transform
        writer.write(3, bits: 2)  // the colour indexing transform
        writer.write(UInt32(colours.count - 1), bits: 8)
        // The table is a colours.count x 1 image, each entry less the one before, per channel.
        var deltas: [UInt32] = []
        var previous: UInt32 = 0
        for colour in colours {
            var delta: UInt32 = 0
            for shift in stride(from: 0, to: 32, by: 8) {
                let channel = ((colour >> UInt32(shift)) &- (previous >> UInt32(shift))) & 0xFF
                delta |= channel << UInt32(shift)
            }
            deltas.append(delta)
            previous = colour
        }
        let (table, tableCache) = tableSymbols(deltas)
        EntropyImageWriter.write(table, cacheBits: tableCache, kind: .entropyCoded, to: writer)
        writer.write(0, bits: 1)  // no more transforms
        // The pixels: indices bundled into the green channel, the first in the lowest bits, alpha 255.
        let packedWidth = (width + (1 << widthBits) - 1) >> widthBits
        var packed: [UInt32] = []
        for row in indexRows {
            for packedX in 0..<packedWidth {
                var green: UInt32 = 0
                for slot in 0..<(1 << widthBits) where packedX << widthBits + slot < width {
                    green |= UInt32(row[packedX << widthBits + slot]) << UInt32(slot * (8 >> widthBits))
                }
                packed.append(0xFF00_0000 | green << 8)
            }
        }
        EntropyImageWriter.write(packed.map(Symbol.literal), kind: .spatiallyCoded, to: writer)
        return Container.riffFile(payload: writer.finish())
    }

    private static func pixel(_ argb: UInt32) -> Pixel {
        Pixel(UInt8((argb >> 16) & 0xFF), UInt8((argb >> 8) & 0xFF), UInt8(argb & 0xFF), UInt8(argb >> 24))
    }

    @Test func aTableWrittenWithoutAMetaPrefixBitDecodesInsideTheTransform() throws {
        let colours: [UInt32] = [0xFF10_2030, 0x80FF_0000, 0xFF00_FF80, 0xFFE0_E0E0]
        let rows = [[0, 1, 2, 3, 1], [3, 3, 0, 2, 1], [2, 1, 1, 0, 0]]
        let file = Self.handBuiltPaletteFile(colours: colours, indexRows: rows) { ($0.map(Symbol.literal), 0) }
        let decoded = try RoundTrip.decode(file)
        #expect(decoded.image.width == 5 && decoded.image.height == 3)
        for (y, row) in rows.enumerated() {
            for (x, index) in row.enumerated() {
                #expect(decoded.image[x, y] == Self.pixel(colours[index]), "pixel (\(x), \(y))")
            }
        }
    }

    @Test(arguments: [0, 3, 8])
    func aTableWithCopiesAndACacheDecodesInsideTheTransform(_ cacheBits: Int) throws {
        // Sixteen colours stepping evenly, so that the deltas repeat: the table is one literal and then a copy, or
        // cache hits, whichever the symbols make of it. Two pixels are bundled into one (16 colours, `width_bits` 1).
        let colours: [UInt32] = (0..<16).map { 0xFF00_0000 | UInt32($0 * 9 + 5) << 16 | UInt32($0 * 3) << 8 | 0x40 }
        let rows = [Array(0..<16), Array((0..<16).reversed()), (0..<16).map { $0 * 7 % 16 }]
        let file = Self.handBuiltPaletteFile(colours: colours, indexRows: rows) { deltas in
            (BackwardReferences.find(pixels: deltas, width: deltas.count, cacheBits: cacheBits), cacheBits)
        }
        let decoded = try RoundTrip.decode(file)
        #expect(decoded.image.width == 16 && decoded.image.height == 3)
        for (y, row) in rows.enumerated() {
            for (x, index) in row.enumerated() {
                #expect(decoded.image[x, y] == Self.pixel(colours[index]), "pixel (\(x), \(y))")
            }
        }
    }
}
