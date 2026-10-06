import CoreGraphics
import Foundation
import Testing
@testable import CSOCR

struct OCRTilingTests {
    /// Ink that is the same in every column: no cut has anywhere better to go.
    private func flatInk(width: Int, value: Int = 0) -> (Range<Int>) -> [Int] {
        { _ in Array(repeating: value, count: width) }
    }

    /// The vertical cut between two horizontally neighbouring tiles: each reaches half the overlap past it.
    private func cut(between left: OCRTile, and right: OCRTile) -> Int {
        let fromLeft = Int(left.rect.maxX) - OCRTiling.horizontalOverlap / 2
        let fromRight = Int(right.rect.minX) + OCRTiling.horizontalOverlap / 2
        #expect(fromLeft == fromRight)
        return fromLeft
    }

    /// Checks that `tiles` is a grid covering a `width` × `height` image: rows top to bottom, each row's tiles left to
    /// right, every tile within the size limits, neighbours overlapping exactly 160 px down and 400 px across, and the
    /// inner edges being exactly the sides that face a neighbour. Returns the number of tiles in each row.
    @discardableResult
    private func checkGrid(_ tiles: [OCRTile], width: Int, height: Int,
                           sourceLocation: SourceLocation = #_sourceLocation) -> [Int] {
        var rows: [[OCRTile]] = []
        for tile in tiles {
            if let last = rows.last?.last, last.rect.minY == tile.rect.minY {
                rows[rows.count - 1].append(tile)
            } else {
                rows.append([tile])
            }
        }
        #expect(rows.first?.first?.rect.minY == 0, sourceLocation: sourceLocation)
        #expect(rows.last?.first?.rect.maxY == CGFloat(height), sourceLocation: sourceLocation)
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 {
                #expect(rows[rowIndex - 1][0].rect.maxY - row[0].rect.minY == CGFloat(OCRTiling.verticalOverlap),
                        sourceLocation: sourceLocation)
            }
            #expect(row.first?.rect.minX == 0, sourceLocation: sourceLocation)
            #expect(row.last?.rect.maxX == CGFloat(width), sourceLocation: sourceLocation)
            for (columnIndex, tile) in row.enumerated() {
                #expect(tile.rect.width <= CGFloat(OCRTiling.maximumTileWidth), sourceLocation: sourceLocation)
                #expect(tile.rect.height <= CGFloat(OCRTiling.maximumTileHeight), sourceLocation: sourceLocation)
                #expect(tile.rect.minY == row[0].rect.minY && tile.rect.height == row[0].rect.height, sourceLocation: sourceLocation)
                if columnIndex > 0 {
                    #expect(row[columnIndex - 1].rect.maxX - tile.rect.minX == CGFloat(OCRTiling.horizontalOverlap),
                            sourceLocation: sourceLocation)
                }
                var expected: OCRTile.Edges = []
                if rowIndex > 0 { expected.insert(.top) }
                if rowIndex < rows.count - 1 { expected.insert(.bottom) }
                if columnIndex > 0 { expected.insert(.left) }
                if columnIndex < row.count - 1 { expected.insert(.right) }
                #expect(tile.innerEdges == expected, sourceLocation: sourceLocation)
            }
        }
        return rows.map(\.count)
    }

    @Test func aHalfResolutionMainDisplayCaptureIsWhole() {
        #expect(!OCRTiling.needsTiling(width: 3360, height: 1890))
        var inkAsked = false
        let tiles = OCRTiling.tiles(width: 3360, height: 1890) { _ in
            inkAsked = true
            return []
        }
        #expect(tiles == [OCRTile(rect: CGRect(x: 0, y: 0, width: 3360, height: 1890), innerEdges: [])])
        #expect(!inkAsked)
        // The limits themselves are still whole: 6.5 MP, and a long side exactly 3× the short one.
        #expect(!OCRTiling.needsTiling(width: 2600, height: 2500))
        #expect(!OCRTiling.needsTiling(width: 1200, height: 400))
        #expect(!OCRTiling.needsTiling(width: 400, height: 1200))
        #expect(OCRTiling.needsTiling(width: 2601, height: 2500))
        #expect(OCRTiling.needsTiling(width: 1201, height: 400))
        #expect(OCRTiling.needsTiling(width: 400, height: 1201))
    }

    @Test func aSquareNineMegapixelImageIsTiled() {
        #expect(OCRTiling.needsTiling(width: 3000, height: 3000))
        var inkRows: [Range<Int>] = []
        let tiles = OCRTiling.tiles(width: 3000, height: 3000) { rows in
            inkRows.append(rows)
            return Array(repeating: 0, count: 3000)
        }
        // Rows split at 1 500 and reach 80 px past it; columns cut at 1 500 and reach 200 px past it.
        #expect(tiles == [
            OCRTile(rect: CGRect(x: 0, y: 0, width: 1700, height: 1580), innerEdges: [.bottom, .right]),
            OCRTile(rect: CGRect(x: 1300, y: 0, width: 1700, height: 1580), innerEdges: [.bottom, .left]),
            OCRTile(rect: CGRect(x: 0, y: 1420, width: 1700, height: 1580), innerEdges: [.top, .right]),
            OCRTile(rect: CGRect(x: 1300, y: 1420, width: 1700, height: 1580), innerEdges: [.top, .left]),
        ])
        // Each row's cuts are chosen from the ink of that row's own pixels.
        #expect(inkRows == [0..<1580, 1420..<3000])
    }

    @Test func aFullScreen6KCaptureIsAGrid() {
        #expect(OCRTiling.needsTiling(width: 6720, height: 3780))
        let tiles = OCRTiling.tiles(width: 6720, height: 3780, columnInk: flatInk(width: 6720))
        #expect(checkGrid(tiles, width: 6720, height: 3780) == [5, 5, 5])
        #expect(tiles.map { Int($0.rect.minY) }.uniqued() == [0, 1180, 2440])
        // With nothing to steer them, the columns are cut at their even positions.
        #expect((0..<4).map { cut(between: tiles[$0], and: tiles[$0 + 1]) } == [1344, 2688, 4032, 5376])
    }

    @Test func aHorizontalScrollingCaptureIsTiledAcross() {
        let tiles = OCRTiling.tiles(width: 16_000, height: 1200, columnInk: flatInk(width: 16_000))
        #expect(checkGrid(tiles, width: 16_000, height: 1200) == [10])
        #expect(tiles.allSatisfy { $0.rect.minY == 0 && $0.rect.height == 1200 })
    }

    @Test func aCutMovesIntoABlankColumn() {
        let ink = (0..<3000).map { (1600...1660).contains($0) ? 0 : 7 }
        let tiles = OCRTiling.tiles(width: 3000, height: 3000) { _ in ink }
        checkGrid(tiles, width: 3000, height: 3000)
        // The blank column nearest the even position (1 500) is the gap's first.
        #expect(cut(between: tiles[0], and: tiles[1]) == 1600)
        #expect(cut(between: tiles[2], and: tiles[3]) == 1600)

        // The least ink wins even where nothing is blank; between two equally clear columns, the nearer one.
        let twoGaps = (0..<3000).map { column -> Int in
            switch column {
            case 1310...1320, 1690...1700: 1
            default: 9
            }
        }
        let gapTiles = OCRTiling.tiles(width: 3000, height: 3000) { _ in twoGaps }
        #expect(cut(between: gapTiles[0], and: gapTiles[1]) == 1320)
    }

    @Test func withoutABlankColumnTheCutStaysAtItsEvenPosition() {
        let flat = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000, value: 12))
        #expect(cut(between: flat[0], and: flat[1]) == 1500)
        // A blank column beyond the 256 px search is out of reach.
        let farGap = (0..<3000).map { (1800...1860).contains($0) ? 0 : 7 }
        let far = OCRTiling.tiles(width: 3000, height: 3000) { _ in farGap }
        #expect(cut(between: far[0], and: far[1]) == 1500)
    }

    @Test func everyPlanStaysWithinTheTileLimits() {
        // The only blank columns are 256 px out from the even positions, alternately left and right, so every other
        // piece is pushed as wide as the search allows: the widest tiles a plan can have.
        for (width, height) in [(1700, 4000), (2700, 2500), (3297, 3000), (4944, 2000), (6720, 3780), (6720, 16_383),
                                (16_000, 1200), (3200, 12_000), (5000, 1889), (9999, 3777), (20_000, 20_000)] {
            let pieces = (width + 1647) / 1648
            let blank = Set((1..<max(pieces, 1)).map { $0 * width / pieces + ($0.isMultiple(of: 2) ? 256 : -256) })
            let ink = (0..<width).map { blank.contains($0) ? 0 : 1 }
            let tiles = OCRTiling.tiles(width: width, height: height) { _ in ink }
            checkGrid(tiles, width: width, height: height)
            #expect(tiles.count > 1)
        }
        // Three full 1 648 px pieces: the middle one, pushed out 256 px each way, makes a tile of exactly the limit.
        let pushed = OCRTiling.tiles(width: 4944, height: 2000) { _ in
            (0..<4944).map { $0 == 1648 - 256 || $0 == 3296 + 256 ? 0 : 1 }
        }
        #expect(pushed.map(\.rect.width).max() == CGFloat(OCRTiling.maximumTileWidth))
    }

    @Test func aOneLineStripIsOneTileThoughItNeedsTiling() {
        // Wider than 3:1, so too long to read whole, yet narrower than one tile: the usual Capture Text selection.
        for (width, height) in [(800, 200), (1200, 80), (1600, 400)] {
            #expect(OCRTiling.needsTiling(width: width, height: height))
            #expect(OCRTiling.tileCount(width: width, height: height) == 1)
        }
        #expect(OCRTiling.tileCount(width: 6720, height: 3780) > 1)
        #expect(OCRTiling.tileCount(width: 1600, height: 16_000) > 1)
    }

    @Test func tileCountIsHowManyTilesThePlanCuts() {
        for (width, height) in [(800, 200), (1200, 80), (1600, 400), (1600, 1200), (2400, 300), (3000, 120),
                                (1700, 4000), (2700, 2500), (6720, 3780), (6720, 16_383), (1600, 16_000), (16_000, 1200),
                                (5000, 1889), (20_000, 20_000), (1, 1), (0, 100)] {
            let tiles = OCRTiling.tiles(width: width, height: height, columnInk: flatInk(width: width))
            #expect(OCRTiling.tileCount(width: width, height: height) == tiles.count, "\(width)×\(height)")
        }
    }

    @Test func linesTouchingAnInnerCutAreDroppedAndOverlapsDeduplicated() {
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        // Top left: (0, 0, 1700, 1580), cut below and to the right. Bottom left: (0, 1420, 1700, 1580), cut above
        // and to the right. Vision's box for a line cut by a tile's right or bottom edge stops short of it, by about
        // 4.3 px on the largest tiles, so "near" is 8 px.
        let topLeft: [OCRLine] = [
            OCRLine(text: "At the image's top", box: CGRect(x: 40, y: 0, width: 300, height: 30)),          // a border: kept
            OCRLine(text: "Cut by the bottom", box: CGRect(x: 40, y: 1560, width: 300, height: 20)),        // dropped
            OCRLine(text: "Cut short of the bottom", box: CGRect(x: 40, y: 1545.7, width: 300, height: 30)), // 4.3 px: dropped
            OCRLine(text: "Whole in the overlap", box: CGRect(x: 40, y: 1450, width: 300, height: 30)),     // kept
            OCRLine(text: "Cut by the right", box: CGRect(x: 1500, y: 200, width: 199, height: 30)),        // dropped
            OCRLine(text: "E", box: CGRect(x: 1680, y: 250, width: 15, height: 26)),                        // 5 px: dropped
            OCRLine(text: "Clear of the right", box: CGRect(x: 1400, y: 300, width: 290, height: 30)),      // 10 px: kept
        ]
        let bottomLeft: [OCRLine] = [
            OCRLine(text: "Cut by the top", box: CGRect(x: 40, y: 0, width: 300, height: 25)),              // dropped
            OCRLine(text: "Whole in the overlap", box: CGRect(x: 52, y: 42, width: 300, height: 30)),       // 12 px off: a duplicate
            OCRLine(text: "Whole in the overlay", box: CGRect(x: 40, y: 30, width: 300, height: 30)),       // other text: kept
            OCRLine(text: "Whole in the overlap", box: CGRect(x: 40, y: 43, width: 300, height: 30)),       // 13 px off: kept
            OCRLine(text: "At the image's bottom", box: CGRect(x: 40, y: 1550, width: 300, height: 30)),    // a border: kept
        ]
        let result = OCRTiling.merge([
            (tile: tiles[0], lines: topLeft, qrPayloads: []),
            (tile: tiles[1], lines: [], qrPayloads: []),
            (tile: tiles[2], lines: bottomLeft, qrPayloads: []),
            (tile: tiles[3], lines: [], qrPayloads: []),
        ])
        // In reading order: the left column's rows, then the right column.
        #expect(result.lines == [
            OCRLine(text: "At the image's top", box: CGRect(x: 40, y: 0, width: 300, height: 30)),
            OCRLine(text: "Whole in the overlap", box: CGRect(x: 40, y: 1450, width: 300, height: 30)),
            OCRLine(text: "Whole in the overlay", box: CGRect(x: 40, y: 1450, width: 300, height: 30)),
            OCRLine(text: "Whole in the overlap", box: CGRect(x: 40, y: 1463, width: 300, height: 30)),
            OCRLine(text: "At the image's bottom", box: CGRect(x: 40, y: 2970, width: 300, height: 30)),
            OCRLine(text: "Clear of the right", box: CGRect(x: 1400, y: 300, width: 290, height: 30)),
        ])
    }

    @Test func linesMapBackToImageCoordinatesInReadingOrder() {
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        func lines(_ name: String) -> [OCRLine] {
            [OCRLine(text: "\(name) one", box: CGRect(x: 500, y: 600, width: 200, height: 30)),
             OCRLine(text: "\(name) two", box: CGRect(x: 400, y: 640, width: 200, height: 30))]
        }
        // Handed over in any order. The tiles' lines form two columns (x 400–700 and 1 700–2 000) with a gutter
        // between them top to bottom: the left column is read first, each row by row.
        let result = OCRTiling.merge([
            (tile: tiles[3], lines: lines("D"), qrPayloads: []),
            (tile: tiles[1], lines: lines("B"), qrPayloads: []),
            (tile: tiles[0], lines: lines("A"), qrPayloads: []),
            (tile: tiles[2], lines: lines("C"), qrPayloads: []),
        ])
        #expect(result.lines.map(\.text) == ["A one", "A two", "C one", "C two", "B one", "B two", "D one", "D two"])
        #expect(result.lines.map(\.box.origin) == [
            CGPoint(x: 500, y: 600), CGPoint(x: 400, y: 640),
            CGPoint(x: 500, y: 2020), CGPoint(x: 400, y: 2060),
            CGPoint(x: 1800, y: 600), CGPoint(x: 1700, y: 640),
            CGPoint(x: 1800, y: 2020), CGPoint(x: 1700, y: 2060),
        ])
        #expect(result.lines.allSatisfy { $0.box.size == CGSize(width: 200, height: 30) })
        #expect(result.qrPayloads.isEmpty)
    }

    // MARK: - Where tiles meet

    private func local(_ rect: CGRect, in tile: OCRTile) -> CGRect {
        rect.offsetBy(dx: -tile.rect.minX, dy: -tile.rect.minY)
    }

    @Test func aTileKeepsTheLinesOfItsOwnRowsWithTheirWordsWhereItMeetsANeighbour() {
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        // Top left (0, 0, 1700, 1580) owns the rows above 1 500, the bottom-left tile (0, 1420, …) those below; each keeps
        // a line up to 6 px past that, more than Vision's boxes for a line differ between tiles.
        let (topLeft, bottomLeft) = (tiles[0], tiles[2])
        let low = CGRect(x: 100, y: 1495, width: 300, height: 30) // centre 1 510
        #expect(OCRTiling.ownedPart(of: "Low line", box: low, in: topLeft) { _ in nil } == nil)
        #expect(OCRTiling.ownedPart(of: "Low line", box: local(low, in: bottomLeft), in: bottomLeft) { _ in nil }?.line.text == "Low line")
        let onTheBoundary = CGRect(x: 100, y: 1488, width: 300, height: 30) // centre 1 503: both rows keep it
        #expect(OCRTiling.ownedPart(of: "Edge", box: onTheBoundary, in: topLeft) { _ in nil } != nil)
        #expect(OCRTiling.ownedPart(of: "Edge", box: local(onTheBoundary, in: bottomLeft), in: bottomLeft) { _ in nil } != nil)

        // Away from the neighbour on its right (which reads from 1 300), a line is kept as read, without words.
        var asked = false
        let away = OCRTiling.ownedPart(of: "Whole  line", box: CGRect(x: 100, y: 100, width: 300, height: 30), in: topLeft) { _ in
            asked = true
            return nil
        }
        #expect(away == OCRPiece(line: OCRLine(text: "Whole  line", box: CGRect(x: 100, y: 100, width: 300, height: 30))))
        #expect(!asked)
        // Reaching into the overlap, it is kept whole too, with its words located among its non-space characters.
        let text = "the quick 日本"
        let boxes = [CGRect(x: 1200, y: 100, width: 40, height: 30), CGRect(x: 1248, y: 100, width: 70, height: 30),
                     CGRect(x: 1326, y: 100, width: 26, height: 30), CGRect(x: 1352, y: 100, width: 26, height: 30)]
        let ranges = OCRTiling.wordRanges(in: text)
        let near = OCRTiling.ownedPart(of: text, box: CGRect(x: 1200, y: 100, width: 178, height: 30), in: topLeft) { range in
            ranges.firstIndex(of: range).map { boxes[$0] }
        }
        #expect(near?.line.text == text)
        #expect(near?.words == [OCRWord(start: 0, count: 3, box: boxes[0]), OCRWord(start: 3, count: 5, box: boxes[1]),
                                OCRWord(start: 8, count: 1, box: boxes[2]), OCRWord(start: 9, count: 1, box: boxes[3])])
        // Without word boxes it is still kept, its characters then placed across the whole line.
        #expect(OCRTiling.ownedPart(of: text, box: CGRect(x: 1200, y: 100, width: 178, height: 30), in: topLeft) { _ in nil }?.words == nil)
    }

    @Test func cjkCharactersAreWordsOfTheirOwn() {
        let text = "日本語の text、です"
        #expect(OCRTiling.wordRanges(in: text).map { String(text[$0]) } == ["日", "本", "語", "の", "text", "、", "で", "す"])
        #expect(OCRTiling.wordRanges(in: "  spaced   out  ").count == 2)
        #expect(OCRTiling.wordRanges(in: "").isEmpty)
    }

    /// What Vision would read of `line`, drawn `width` px a character from x `x0` at y 100, in `tile`: the
    /// characters with any part in the tile, a character cut off by the tile's edge misread as "▯", its boxes stopping
    /// a few px short of the edges as Vision's do, and shifted by `jitter`. As the tile contributes it.
    private func read(_ line: String, from x0: CGFloat, width: CGFloat = 20, in tile: OCRTile, jitter: CGFloat = 0) -> OCRPiece? {
        let characters = Array(line)
        var visible = characters.indices.filter { index in
            characters[index] != " " && x0 + width * CGFloat(index + 1) > tile.rect.minX && x0 + width * CGFloat(index) < tile.rect.maxX
        }
        guard let first = visible.first, let last = visible.last else { return nil }
        visible = Array(first...last)
        let text = String(visible.map { index in
            let cutOff = x0 + width * CGFloat(index) < tile.rect.minX || x0 + width * CGFloat(index + 1) > tile.rect.maxX
            return cutOff ? "▯" : characters[index]
        })
        func box(_ range: Range<String.Index>) -> CGRect {
            let start = first + text.distance(from: text.startIndex, to: range.lowerBound)
            let minX = max(x0 + width * CGFloat(start), tile.rect.minX + 3)
            let maxX = min(x0 + width * CGFloat(start + text[range].count), tile.rect.maxX - 4)
            return CGRect(x: minX + jitter - tile.rect.minX, y: 100 - tile.rect.minY, width: maxX - minX, height: 1.5 * width)
        }
        return OCRTiling.ownedPart(of: text, box: box(text.startIndex..<text.endIndex), in: tile, boxFor: box)
    }

    /// `line` read by the 3000 × 3000 plan's two top tiles (cut at 1 500) and merged.
    private func readAcrossTheCut(_ line: String, from x0: CGFloat, width: CGFloat = 20) -> [String] {
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        return OCRTiling.merge(pieces: [
            (tile: tiles[0], pieces: read(line, from: x0, width: width, in: tiles[0]).map { [$0] } ?? [], qrPayloads: []),
            (tile: tiles[1], pieces: read(line, from: x0, width: width, in: tiles[1], jitter: 1.5).map { [$0] } ?? [], qrPayloads: []),
        ]).lines.map(\.text)
    }

    @Test func largeCharactersAcrossACutStitchExactly() {
        // At 26–64 px a character, the 400 px both tiles read holds only 6–15 characters.
        let sentence = "the quick brown fox jumps over the lazy dog while seven bold zebras quietly graze nearby"
        for width in [26, 32, 40, 50, 64] as [CGFloat] {
            let line = String(sentence.prefix(Int(2800 / width))).trimmingCharacters(in: .whitespaces)
            let span = width * CGFloat(line.count)
            for x0 in stride(from: max(1700 - span + 40, 60), through: min(1260, 2940 - span), by: 37) {
                #expect(readAcrossTheCut(line, from: x0, width: width) == [line], "\(Int(width)) px a character from x \(Int(x0))")
            }
        }
    }

    @Test func aSpaceBothReadingsHaveIsKept() {
        // Vision's two readings of row 1 of the 2 600 px page (the left tile ends inside "lemon", the right one begins
        // inside "garden"), with their word boxes.
        func piece(_ words: [(String, CGFloat, CGFloat)]) -> OCRPiece {
            var start = 0
            let located = words.map { word -> OCRWord in
                defer { start += word.0.count }
                return OCRWord(start: start, count: word.0.count, box: CGRect(x: word.1, y: 100, width: word.2 - word.1, height: 30))
            }
            let box = CGRect(x: words[0].1, y: 100, width: words[words.count - 1].2 - words[0].1, height: 30)
            return OCRPiece(line: OCRLine(text: words.map(\.0).joined(separator: " "), box: box), words: located)
        }
        let left = piece([("Row", 2020, 2074), ("1", 2078, 2093), ("dragon", 2097, 2182), ("eagle", 2186, 2251), ("falcon", 2255, 2331),
                          ("garden", 2335, 2420), ("harbor", 2424, 2500), ("island", 2504, 2577), ("jungle", 2581, 2654),
                          ("kettle", 2658, 2723), ("le", 2727, 2744)])
        let right = piece([("jarden", 2347, 2419), ("harbor", 2423, 2500), ("island", 2504, 2577), ("jungle", 2580, 2653),
                           ("kettle", 2657, 2722), ("lemon", 2726, 2799), ("marble", 2803, 2887), ("needle", 2891, 2972), ("orange", 2975, 3060)])
        #expect(OCRPiece.stitched(left, right).line.text
                == "Row 1 dragon eagle falcon garden harbor island jungle kettle lemon marble needle orange")
        // And as the pure model reads it, wherever the cut falls.
        for x0 in stride(from: CGFloat(1100), through: 1420, by: 11) {
            #expect(readAcrossTheCut("jungle kettle lemon marble needle orange pepper quartz", from: x0)
                    == ["jungle kettle lemon marble needle orange pepper quartz"], "from x \(Int(x0))")
        }
    }

    @Test func aWordNeitherTileSeesWholeIsStitchedFromBoth() {
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        // A 30-character token from 1 185 to 1 785: the left tile (to 1 700) and the right one (from 1 300) each see
        // only part of it, a character cut off at the edge misread.
        let line = "see abcdefghijklmnopqrstuvwxyz0123 now"
        #expect(read(line, from: 1105, in: tiles[0])?.line.text == "see abcdefghijklmnopqrstuvwxy▯")
        #expect(read(line, from: 1105, in: tiles[1])?.line.text == "▯ghijklmnopqrstuvwxyz0123 now")
        // Stitched through the stretch both read: whole, nothing twice, nothing misread.
        #expect(readAcrossTheCut(line, from: 1105) == [line])
        // Wherever the cut falls in it.
        for shift in stride(from: 0, through: 60, by: 7) {
            #expect(readAcrossTheCut(line, from: 1105 + CGFloat(shift)) == [line], "shifted \(shift) px")
        }
        // Runs of one character: a rule and a dot leader.
        for line in ["start " + String(repeating: "=", count: 60) + " end", "Chapter one " + String(repeating: ".", count: 50) + " 17"] {
            for x0 in stride(from: CGFloat(1000), through: 1060, by: 13) {
                #expect(readAcrossTheCut(line, from: x0) == [line], "from x \(Int(x0))")
            }
        }
        // An ordinary line across the cut, and one ending just past it.
        #expect(readAcrossTheCut("the quick brown fox jumps over the lazy dog", from: 1200) == ["the quick brown fox jumps over the lazy dog"])
        #expect(readAcrossTheCut("ends here", from: 1450) == ["ends here"])
    }

    @Test func aReadingHeldWithinTheOtherIsDropped() {
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        // A 15-character token from 1 405 to 1 705: cut off by the left tile's edge (1 700), whole in the right tile.
        #expect(readAcrossTheCut("see abcdefghijklmno now", from: 1325) == ["see abcdefghijklmno now"])
        // Whole in the left tile, cut off by the right one's edge (1 300).
        #expect(readAcrossTheCut("see abcdefghijklmno now", from: 920) == ["see abcdefghijklmno now"])
        // A short line inside the overlap, seen whole by both.
        #expect(readAcrossTheCut("both", from: 1460) == ["both"])
        // A sliver: the left tile ends just inside a line and reads its first letter.
        let sliver = OCRPiece(line: OCRLine(text: "E", box: CGRect(x: 1686, y: 100, width: 10, height: 30)))
        let whole = OCRPiece(line: OCRLine(text: "Entry 63 sample words", box: CGRect(x: 387, y: 100, width: 280, height: 30)))
        let result = OCRTiling.merge(pieces: [(tile: tiles[0], pieces: [sliver], qrPayloads: []),
                                              (tile: tiles[1], pieces: [whole], qrPayloads: [])])
        #expect(result.lines.map(\.text) == ["Entry 63 sample words"])
    }

    @Test func aSideSliverIsDropped() {
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        func merged(_ left: OCRPiece, _ right: [OCRPiece]) -> [String] {
            OCRTiling.merge(pieces: [(tile: tiles[0], pieces: [left], qrPayloads: []),
                                     (tile: tiles[1], pieces: right, qrPayloads: [])]).lines.map(\.text)
        }
        func piece(_ text: String, _ from: CGFloat, _ to: CGFloat) -> OCRPiece {
            OCRPiece(line: OCRLine(text: text, box: CGRect(x: from, y: 100, width: to - from, height: 30)))
        }
        // A letter or two the left tile read at its edge (1 700), boxed more than 3 px off the right tile's reading
        // of the word they begin, which carries on past the edge. (The right tile's pieces are in its own pixels.)
        #expect(merged(piece("E", 1690, 1697), [piece("Entry 179 sample words", 395, 685)]) == ["Entry 179 sample words"])
        #expect(merged(piece("En", 1682, 1697), [piece("Entry 179 sample words", 387, 677)]) == ["Entry 179 sample words"])
        // And one the right tile read at its edge (1 300), inside the left tile's reading of the word.
        let ending = piece("the end", 1220, 1310)
        let tail = OCRPiece(line: OCRLine(text: "d", box: CGRect(x: 3, y: 100, width: 8, height: 30)))
        #expect(OCRTiling.merge(pieces: [(tile: tiles[0], pieces: [ending], qrPayloads: []),
                                         (tile: tiles[1], pieces: [tail], qrPayloads: [])]).lines.map(\.text) == ["the end"])
        // Not a sliver: a short word away from the edge is a word.
        #expect(merged(piece("Go", 1600, 1628), [piece("on", 340, 366)]) == ["Go on"])
    }

    @Test func aShortWordAtACutIsNotASliver() {
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        // The left tile reads "12" whole, ending 7 px inside its edge (1 700). The right tile reads it too (held within
        // the left reading) and "items" 20 px on: nothing reads "12" inside a longer word, so it stays.
        func merged(_ word: String, _ next: String) -> [String] {
            OCRTiling.merge(pieces: [
                (tile: tiles[0], pieces: [OCRPiece(line: OCRLine(text: word, box: CGRect(x: 1665, y: 100, width: 28, height: 30)))], qrPayloads: []),
                (tile: tiles[1], pieces: [OCRPiece(line: OCRLine(text: word, box: CGRect(x: 366, y: 100, width: 28, height: 30))),
                                          OCRPiece(line: OCRLine(text: next, box: CGRect(x: 413, y: 100, width: 90, height: 30)))], qrPayloads: []),
            ]).lines.map(\.text)
        }
        #expect(merged("12", "items") == ["12 items"])
        #expect(merged("Al", "Smith") == ["Al Smith"])
    }

    /// One line read by the 3000 × 3000 plan's two top tiles: `left` (with its words' boxes) by the left tile, `right`
    /// by the right one, all in image pixels.
    private func stitch(_ left: [(String, CGFloat, CGFloat)], _ right: [(String, CGFloat, CGFloat)]) -> [String] {
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        func piece(_ words: [(String, CGFloat, CGFloat)], in tile: OCRTile) -> OCRPiece? {
            // As Vision writes it: words apart by a space, except Han or Kana, which run on.
            var text = ""
            var offsets: [Int] = []
            for word in words {
                if let last = text.last, !(last.isHanOrKana && word.0.first?.isHanOrKana == true) { text += " " }
                offsets.append(text.count)
                text += word.0
            }
            // Each given word's span of `text`; a range inside one (a CJK character) gets its share of the word's box.
            let spans = zip(words, offsets).map { word, offset in
                (range: text.index(text.startIndex, offsetBy: offset)..<text.index(text.startIndex, offsetBy: offset + word.0.count),
                 from: word.1, to: word.2)
            }
            let line = CGRect(x: words[0].1, y: 100, width: words[words.count - 1].2 - words[0].1, height: 30)
            return OCRTiling.ownedPart(of: text, box: local(line, in: tile), in: tile) { range in
                guard let span = spans.first(where: { $0.range.contains(range.lowerBound) }) else { return nil }
                let share = (span.to - span.from) / CGFloat(text[span.range].count)
                let offset = CGFloat(text.distance(from: span.range.lowerBound, to: range.lowerBound))
                let box = CGRect(x: span.from + offset * share, y: 100, width: share * CGFloat(text[range].count), height: 30)
                return local(box, in: tile)
            }
        }
        return OCRTiling.merge(pieces: [(tile: tiles[0], pieces: piece(left, in: tiles[0]).map { [$0] } ?? [], qrPayloads: []),
                                        (tile: tiles[1], pieces: piece(right, in: tiles[1]).map { [$0] } ?? [], qrPayloads: [])])
            .lines.map(\.text)
    }

    @Test func aSpaceOnlyOneReadingHasIsDropped() {
        // Vision put a space in each tile's reading of the path, in different places; where both read it, neither stands.
        #expect(stitch([("error:", 900, 994), ("/opt/src/CSOCR/OCRTiling", 997, 1414), (".swift:42:13:", 1417, 1602), ("cannot", 1605, 1696)],
                       [("▯RTiling.swift:", 1303, 1505), ("42:13:", 1508, 1602), ("cannot", 1605, 1705), ("find", 1708, 1777), ("it", 1780, 1815)])
                == ["error: /opt/src/CSOCR/OCRTiling.swift:42:13: cannot find it"])
        // Spaces both readings have stay: Korean keeps its spaces.
        #expect(stitch([("한국어", 1380, 1458), ("텍스트", 1468, 1546), ("입니", 1556, 1608)],
                       [("국어", 1406, 1458), ("텍스트", 1468, 1546), ("입니다", 1556, 1634)])
                == ["한국어 텍스트 입니다"])
        // The same word twice in a row is read twice, Latin or CJK.
        #expect(stitch([("say", 1300, 1360), ("that", 1370, 1450), ("that", 1460, 1540), ("again", 1550, 1690)],
                       [("that", 1371, 1451), ("that", 1461, 1541), ("again", 1551, 1691), ("now", 1701, 1761)])
                == ["say that that again now"])
        #expect(stitch([("看", 1400, 1426), ("看", 1426, 1452), ("吧", 1452, 1478), ("好", 1478, 1504), ("的", 1504, 1530)],
                       [("看", 1427, 1453), ("吧", 1453, 1479), ("好", 1479, 1505), ("的", 1505, 1531), ("。", 1531, 1557)])
                == ["看看吧好的。"])
    }

    @Test func piecesOfALineAcrossACutAreJoined() {
        // Row 0 of the 6K plan: tiles cut at 1 344, 2 688, 4 032 and 5 376.
        let tiles = OCRTiling.tiles(width: 6720, height: 3780, columnInk: flatInk(width: 6720))
        func pieces(_ tile: OCRTile, _ lines: [(String, CGRect)]) -> (tile: OCRTile, lines: [OCRLine], qrPayloads: [String]) {
            (tile: tile, lines: lines.map { OCRLine(text: $0.0, box: $0.1.offsetBy(dx: -tile.rect.minX, dy: -tile.rect.minY)) }, qrPayloads: [])
        }
        let result = OCRTiling.merge([
            pieces(tiles[0], [("Row 1 the quick", CGRect(x: 1000, y: 100, width: 340, height: 30)),
                              ("Row 2 jumps", CGRect(x: 1000, y: 160, width: 338, height: 30)),
                              ("Alone on the left", CGRect(x: 100, y: 400, width: 300, height: 30))]),
            pieces(tiles[1], [("over the", CGRect(x: 1346, y: 161, width: 114, height: 30)),
                              ("brown fox jumps over", CGRect(x: 1348, y: 101, width: 1332, height: 30)),
                              ("Far from the cut", CGRect(x: 2000, y: 400, width: 300, height: 30))]),
            pieces(tiles[2], [("the lazy dog", CGRect(x: 2690, y: 100, width: 210, height: 30))]),
            pieces(tiles[3], [("日本語の", CGRect(x: 5240, y: 700, width: 130, height: 30))]),
            pieces(tiles[4], [("テキスト", CGRect(x: 6000, y: 700, width: 130, height: 30)),
                              ("テキスト", CGRect(x: 5378, y: 701, width: 130, height: 30))]),
        ])
        // In reading order: four columns, each row by row.
        #expect(result.lines == [
            OCRLine(text: "Alone on the left", box: CGRect(x: 100, y: 400, width: 300, height: 30)),
            // Joined across two cuts, left to right with single spaces; the box is the union of the pieces.
            OCRLine(text: "Row 1 the quick brown fox jumps over the lazy dog", box: CGRect(x: 1000, y: 100, width: 1900, height: 31)),
            OCRLine(text: "Row 2 jumps over the", box: CGRect(x: 1000, y: 160, width: 460, height: 31)),
            OCRLine(text: "Far from the cut", box: CGRect(x: 2000, y: 400, width: 300, height: 30)),
            // CJK runs on without a space, as the assembler joins it; a piece far from the cut stays apart.
            OCRLine(text: "日本語のテキスト", box: CGRect(x: 5240, y: 700, width: 268, height: 31)),
            OCRLine(text: "テキスト", box: CGRect(x: 6000, y: 700, width: 130, height: 30)),
        ])
    }

    @Test func linesGivenWholeJoinWhereTheyMeet() {
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        // Lines given whole (`merge(_:)`): the cut is at 1 500; the right tile's lines are in its own pixels (x − 1 300).
        func join(_ left: (String, CGFloat, CGFloat), _ right: (String, CGFloat, CGFloat)) -> [String] {
            OCRTiling.merge([
                (tile: tiles[0], lines: [OCRLine(text: left.0, box: CGRect(x: left.1, y: 100, width: left.2 - left.1, height: 30))], qrPayloads: []),
                (tile: tiles[1], lines: [OCRLine(text: right.0, box: CGRect(x: right.1 - 1300, y: 100, width: right.2 - right.1, height: 30))], qrPayloads: []),
            ]).lines.map(\.text)
        }
        // Read by both where they overlap: stitched, or dropped when held within the other.
        #expect(join(("the quick brown", 1200, 1530), ("brown fox", 1461, 1600)) == ["the quick brown fox"])
        #expect(join(("the quick brown", 1200, 1530), ("brown", 1461, 1531)) == ["the quick brown"])
        // Touching, or a little apart: joined with a space, the same word twice included, none between Han or Kana.
        #expect(join(("said", 1300, 1503), ("hello", 1501, 1580)) == ["said hello"])
        #expect(join(("said", 1300, 1506), ("hello", 1500, 1580)) == ["said hello"])
        #expect(join(("that", 1300, 1503), ("that", 1501, 1580)) == ["that that"])
        #expect(join(("한국어", 1400, 1490), ("텍스트", 1508, 1590)) == ["한국어 텍스트"])
        #expect(join(("日本語の", 1400, 1490), ("テキスト", 1508, 1590)) == ["日本語のテキスト"])
        // Two columns 30 px apart (a line height) are not one line.
        #expect(join(("Left column first line", 1000, 1485), ("right column first line", 1515, 1900))
                == ["Left column first line", "right column first line"])
    }

    @Test func duplicateQRPayloadsAppearOnce() {
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        let result = OCRTiling.merge([
            (tile: tiles[0], lines: [], qrPayloads: ["https://a.test", "WIFI:S:Home;;"]),
            (tile: tiles[1], lines: [], qrPayloads: ["https://a.test"]),
            (tile: tiles[2], lines: [], qrPayloads: []),
            (tile: tiles[3], lines: [], qrPayloads: ["WIFI:S:Home;;", "https://b.test"]),
        ])
        #expect(result.qrPayloads == ["https://a.test", "WIFI:S:Home;;", "https://b.test"])
        #expect(result.lines.isEmpty)
        #expect(!result.isEmpty)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
