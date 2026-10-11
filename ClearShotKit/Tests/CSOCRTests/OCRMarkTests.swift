import CoreGraphics
import CSTestSupport
import Foundation
import Testing
@testable import CSOCR

/// Marks: the boxes Vision gives for stretches of a line's text that the caller asked for (`TextRecognizer.recognize(_:
/// options:marking:)`), carried through the tiles' merge with the line they belong to. The merge ones are pure and run
/// everywhere; the ones that read a rendered page with Vision are skipped on a Mac where it can't run (see
/// `VisionTextRecognition`).
@Suite(.serialized, .timeLimit(.minutes(3)))
struct OCRMarkTests {
    /// Ink that is the same in every column: no cut has anywhere better to go.
    private func flatInk(width: Int) -> (Range<Int>) -> [Int] {
        { _ in Array(repeating: 0, count: width) }
    }

    private func mark(_ text: String, _ box: CGRect, tag: Int = 0) -> OCRMark {
        OCRMark(text: text, box: box, tag: tag)
    }

    // MARK: Pure

    @Test func aLineHasNoMarksUnlessItIsGivenSome() {
        let line = OCRLine(text: "plain", box: CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(line.marks.isEmpty)
        #expect(line == OCRLine(text: "plain", box: CGRect(x: 1, y: 2, width: 3, height: 4), marks: []))
        #expect(line != OCRLine(text: "plain", box: line.box, marks: [mark("p", line.box)]))
    }

    @Test func languageCorrectionIsOnUnlessTheOptionsTurnItOff() {
        #expect(TextRecognitionOptions(automaticallyDetectsLanguage: true, primaryLanguage: "en-US").usesLanguageCorrection)
        let off = TextRecognitionOptions(automaticallyDetectsLanguage: true, primaryLanguage: "en-US", usesLanguageCorrection: false)
        #expect(!off.usesLanguageCorrection)
        #expect(off != TextRecognitionOptions(automaticallyDetectsLanguage: true, primaryLanguage: "en-US"))
    }

    @Test func marksMoveWithTheirLineIntoImagePixels() {
        // A line of the 3000 × 3000 plan's bottom-right tile, with marks in the tile's pixels.
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        let tile = tiles[3]
        let line = OCRLine(text: "write to jane@example.com", box: CGRect(x: 100, y: 200, width: 400, height: 30),
                           marks: [mark("jane@example.com", CGRect(x: 250, y: 201, width: 250, height: 28), tag: 3)])
        let result = OCRTiling.merge(pieces: [(tile: tile, pieces: [OCRPiece(line: line)], qrPayloads: [])])

        let moved = result.lines[0]
        #expect(moved.box == CGRect(x: tile.rect.minX + 100, y: tile.rect.minY + 200, width: 400, height: 30))
        #expect(moved.marks == [mark("jane@example.com",
                                     CGRect(x: tile.rect.minX + 250, y: tile.rect.minY + 201, width: 250, height: 28), tag: 3)])
    }

    /// What Vision would read of `line`, drawn 20 px a character from x `x0` at y 100, in `tile` (as `OCRTilingTests` does:
    /// the characters with any part in the tile, one cut off by its edge misread as "▯", boxes stopping a few px short of
    /// the edges), with a mark for each of the `marked` words it has, tagged with the word's position in `marked`.
    private func read(_ line: String, from x0: CGFloat, in tile: OCRTile, marking marked: [String]) -> OCRPiece? {
        let width: CGFloat = 20
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
            return CGRect(x: minX - tile.rect.minX, y: 100 - tile.rect.minY, width: maxX - minX, height: 1.5 * width)
        }
        guard var piece = OCRTiling.ownedPart(of: text, box: box(text.startIndex..<text.endIndex), in: tile, boxFor: box) else {
            return nil
        }
        piece.line.marks = marked.enumerated().compactMap { tag, word in
            text.range(of: word).map { OCRMark(text: word, box: box($0), tag: tag) }
        }
        return piece
    }

    @Test func aLineStitchedAcrossACutKeepsTheMarksOfBothReadings() {
        // The two top tiles of the 3000 × 3000 plan read x 0–1 700 and 1 300–3 000. The line runs 20 px a character from
        // x 1 000 to 1 860: "quick" (x 1 080–1 180) lies in the left reading only, "dog" (x 1 800–1 860) in the right
        // one only, and "fox" (x 1 320–1 380) in both. Each reading's marks are on the stitched line, in image pixels.
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        let (left, right) = (tiles[0], tiles[1])
        let line = "the quick brown fox jumps over the lazy dog"
        let marked = ["quick", "fox", "dog"]
        let result = OCRTiling.merge(pieces: [
            (tile: left, pieces: read(line, from: 1000, in: left, marking: marked).map { [$0] } ?? [], qrPayloads: []),
            (tile: right, pieces: read(line, from: 1000, in: right, marking: marked).map { [$0] } ?? [], qrPayloads: []),
        ])

        #expect(result.lines.map(\.text) == [line])
        let marks = result.lines[0].marks
        #expect(marks.map(\.text) == ["quick", "fox", "fox", "dog"], "\(marks)")
        #expect(marks.map(\.tag) == [0, 1, 1, 2])
        // Image pixels: the left tile starts at x 0, the right one at 1 300 (its marks were boxed in its own pixels).
        #expect(marks[0].box.minX == 1080 && marks[0].box.maxX == 1180)
        #expect(marks[1].box == marks[2].box && marks[1].box.minX == 1320 && marks[1].box.maxX == 1380)
        #expect(marks[3].box.minX == 1800 && marks[3].box.maxX <= 1860)
        #expect(marks.allSatisfy { $0.box.minY == 100 && $0.box.height == 30 })
    }

    @Test func aLineJoinedAcrossACutKeepsTheMarksOfBothPieces() {
        // Row 0 of the 6K plan, cut at 1 344: one piece ends at the cut and the next starts just past it.
        let tiles = OCRTiling.tiles(width: 6720, height: 3780, columnInk: flatInk(width: 6720))
        let (first, second) = (tiles[0], tiles[1])
        let before = OCRLine(text: "Row 1 the quick", box: CGRect(x: 1000, y: 100, width: 340, height: 30),
                             marks: [mark("quick", CGRect(x: 1250, y: 100, width: 90, height: 30), tag: 2)])
        let after = OCRLine(text: "brown fox", box: CGRect(x: 1348 - second.rect.minX, y: 101, width: 200, height: 30),
                            marks: [mark("fox", CGRect(x: 1450 - second.rect.minX, y: 101, width: 90, height: 30), tag: 5)])
        let result = OCRTiling.merge(pieces: [(tile: first, pieces: [OCRPiece(line: before)], qrPayloads: []),
                                              (tile: second, pieces: [OCRPiece(line: after)], qrPayloads: [])])

        #expect(result.lines.map(\.text) == ["Row 1 the quick brown fox"])
        #expect(result.lines[0].marks == [mark("quick", CGRect(x: 1250, y: 100, width: 90, height: 30), tag: 2),
                                          mark("fox", CGRect(x: 1450, y: 101, width: 90, height: 30), tag: 5)])
    }

    @Test func aLineKeptByTwoRowsIsKeptOnceWithItsMarks() {
        // A line centred on the boundary between two rows of tiles is read by both; the second reading is dropped.
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        let (top, bottom) = (tiles[0], tiles[2])
        let box = CGRect(x: 100, y: 1488, width: 300, height: 30) // centre 1 503
        func line(in tile: OCRTile) -> OCRLine {
            let local = box.offsetBy(dx: 0, dy: -tile.rect.minY)
            return OCRLine(text: "jane@example.com", box: local,
                           marks: [mark("jane@example.com", local.insetBy(dx: 2, dy: 2), tag: 4)])
        }
        let result = OCRTiling.merge(pieces: [(tile: top, pieces: [OCRPiece(line: line(in: top))], qrPayloads: []),
                                              (tile: bottom, pieces: [OCRPiece(line: line(in: bottom))], qrPayloads: [])])

        #expect(result.lines.count == 1)
        #expect(result.lines[0].marks == [mark("jane@example.com", box.insetBy(dx: 2, dy: 2), tag: 4)])
    }

    @Test func aMarkIsNotCutUnlessItsFlagSaysSo() {
        #expect(!OCRMark(text: "a", box: .zero, tag: 0).isCut)
        #expect(OCRMark(text: "a", box: .zero, tag: 0, isCut: true).isCut)
        #expect(OCRMark(text: "a", box: .zero, tag: 0) != OCRMark(text: "a", box: .zero, tag: 0, isCut: true))
    }

    @Test func aBoxWithinTheMarginOfAnInnerSideEdgeOfItsTileIsCutThere() {
        // The 3000 × 3000 plan's top row: the left tile is (0, 0, 1700, 1580), with inner edges right and bottom; the right
        // one is (1300, 0, 1700, 1580), with inner edges left and bottom. The margin is 8 px.
        let tiles = OCRTiling.tiles(width: 3000, height: 3000, columnInk: flatInk(width: 3000))
        let (left, right) = (tiles[0], tiles[1])
        func box(minX: CGFloat, maxX: CGFloat, minY: CGFloat = 100, maxY: CGFloat = 130) -> CGRect {
            CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        // At the right inner edge of the left tile: Vision's boxes stop a few pixels short of it.
        #expect(OCRTiling.touchesInnerSide(box(minX: 1400, maxX: 1696), of: left))
        #expect(OCRTiling.touchesInnerSide(box(minX: 1400, maxX: 1692), of: left))
        #expect(!OCRTiling.touchesInnerSide(box(minX: 1400, maxX: 1691), of: left))
        // At the left inner edge of the right tile (its own pixels).
        #expect(OCRTiling.touchesInnerSide(box(minX: 3, maxX: 300), of: right))
        #expect(OCRTiling.touchesInnerSide(box(minX: 8, maxX: 300), of: right))
        #expect(!OCRTiling.touchesInnerSide(box(minX: 9, maxX: 300), of: right))
        // A tile's border isn't a cut: the left tile's left edge, the right tile's right edge.
        #expect(!OCRTiling.touchesInnerSide(box(minX: 0, maxX: 300), of: left))
        #expect(!OCRTiling.touchesInnerSide(box(minX: 1400, maxX: 1700), of: right))
        // Top and bottom inner edges are the merge's own business, not a side.
        #expect(!OCRTiling.touchesInnerSide(box(minX: 100, maxX: 300, minY: 1550, maxY: 1580), of: left))
        // A whole image has no inner edges.
        let whole = OCRTile(rect: CGRect(x: 0, y: 0, width: 800, height: 600), innerEdges: [])
        #expect(!OCRTiling.touchesInnerSide(box(minX: 0, maxX: 800), of: whole))
    }

    // MARK: With Vision

    private let options = TextRecognitionOptions(automaticallyDetectsLanguage: true, primaryLanguage: "en-US",
                                                 usesLanguageCorrection: false)

    @Test(.needsVisionTextRecognition) func aMarkIsVisionsBoxForExactlyTheRangeAskedFor() async throws {
        let sentence = "write to jane@example.com for access"
        let address = "jane@example.com"
        let page = OCRPage(width: 1400, height: 200)
        page.text(sentence, x: 100, top: 60, size: 40)

        let result = try await TextRecognizer.recognize(page.image(), options: options) { text in
            text.range(of: address).map { [(range: $0, tag: 7)] } ?? []
        }

        #expect(result.qrPayloads.isEmpty)
        let line = try #require(result.lines.first)
        #expect(result.lines.count == 1)
        let mark = try #require(line.marks.first, "\(result.lines.map(\.text))")
        #expect(line.marks.count == 1)
        #expect(mark.tag == 7)
        #expect(mark.text == address)
        #expect(!mark.isCut)
        // The box runs from where the address starts to where it ends, in image pixels from the top left. Vision places a
        // range's ends by estimate, up to about half a character (10 px at this size) from where the glyphs are.
        let start = 100 + OCRPage.width(of: "write to ", size: 40)
        let end = 100 + OCRPage.width(of: "write to " + address, size: 40)
        #expect(abs(mark.box.minX - start) < 14, "starts at \(mark.box.minX), drawn at \(start)")
        #expect(abs(mark.box.maxX - end) < 14, "ends at \(mark.box.maxX), drawn at \(end)")
        // It is the address's and no more: "to" before it and "for" after it are outside.
        #expect(mark.box.minX > 100 + OCRPage.width(of: "write to", size: 40))
        #expect(mark.box.maxX < 100 + OCRPage.width(of: "write to " + address + " fo", size: 40))
        #expect(mark.box.minY >= line.box.minY - 4 && mark.box.maxY <= line.box.maxY + 4)
        #expect(abs(mark.box.midY - line.box.midY) < 6)
    }

    @Test(.needsVisionTextRecognition) func aMarkAtATilesInnerEdgeIsMarkedCut() async throws {
        // A 3 300 × 300 capture is read in three columns, cut at about 1 100 and 2 200. A run of 60 characters in 56 px type is
        // 1 900 px wide and runs through the first cut: the left tile reads it as far as its edge, and its mark ends there.
        let run = "ghp_" + String("aBcDeFgHjKmNpQrStUvWxYz23456789".prefix(30)) + String("aBcDeFgHjKmNpQrStUvWxYz23456789".prefix(26))
        let page = OCRPage(width: 3300, height: 300)
        page.text("paste " + run + " here", x: 40, top: 100, size: 56)
        #expect(OCRTiling.needsTiling(width: page.width, height: page.height))

        let result = try await TextRecognizer.recognize(page.image(), options: options) { text in
            text.ranges(of: /[A-Za-z0-9_]{30,}/).map { (range: $0, tag: 0) }
        }

        let marks = result.lines.flatMap(\.marks)
        #expect(marks.contains { $0.isCut }, "\(result.lines.map(\.text)) \(marks)")
        // A cut one reaches an inner side edge of the tile that read it, here the first cut's two sides.
        let ink = ColumnInk(page.image())
        let tiles = OCRTiling.tiles(width: page.width, height: page.height) { ink.counts(rows: $0) }
        #expect(marks.filter(\.isCut).allSatisfy { abs($0.box.maxX - tiles[0].rect.maxX) <= 8 || abs($0.box.minX - tiles[1].rect.minX) <= 8 },
                "\(marks) \(tiles.map(\.rect))")
    }

    @Test(.needsVisionTextRecognition) func aLineWithNothingToMarkHasNoMarks() async throws {
        let page = OCRPage(width: 1400, height: 200)
        page.text("nothing to see here", x: 100, top: 60, size: 40)

        let result = try await TextRecognizer.recognize(page.image(), options: options) { _ in [] }

        #expect(!result.lines.isEmpty)
        #expect(result.lines.allSatisfy { $0.marks.isEmpty })
    }

    @Test(.needsVisionTextRecognition) func marksOfALineInATiledImageAreInImagePixels() async throws {
        // A tall capture is read in tiles; the line lies in a lower row, so its tile's origin is far from the image's.
        let page = OCRPage(width: 3200, height: 6000)
        let address = "jane@example.com"
        page.text("contact " + address + " today", x: 400, top: 4300, size: 40)
        #expect(OCRTiling.needsTiling(width: page.width, height: page.height))

        let result = try await TextRecognizer.recognize(page.image(), options: options) { text in
            text.range(of: address).map { [(range: $0, tag: 1)] } ?? []
        }

        let line = try #require(result.lines.first { $0.text.contains("example") }, "\(result.lines.map(\.text))")
        let mark = try #require(line.marks.first)
        let start = 400 + OCRPage.width(of: "contact ", size: 40)
        let end = 400 + OCRPage.width(of: "contact " + address, size: 40)
        #expect(abs(mark.box.minX - start) < 14 && abs(mark.box.maxX - end) < 14, "\(mark.box) drawn \(start)...\(end)")
        #expect(abs(mark.box.midY - 4300) < 40, "\(mark.box)")
    }
}
