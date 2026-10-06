import CoreGraphics
import Foundation
import Testing
@testable import CSOCR

/// Vision's readings of tiles, captured once from the recognizer (`Fixtures/tile-readings.json`: each tile's lines as
/// `ownedPart` keeps them, in the tile's pixels), replayed through the merge. Vision's output varies with the OS and
/// even with the executable, so these, not the live tests, hold the merge to exact text.
struct TileReadingReplayTests {
    private struct Word: Decodable { var start: Int; var count: Int; var box: [Double] }
    private struct Piece: Decodable { var text: String; var box: [Double]; var words: [Word]? }
    private struct Tile: Decodable { var rect: [Double]; var inner: Int; var pieces: [Piece] }
    private struct Case: Decodable { var label: String; var expected: [String]; var tiles: [Tile] }

    private static let cases: [Case] = {
        guard let url = Bundle.module.url(forResource: "tile-readings", withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              let cases = try? JSONDecoder().decode([Case].self, from: data) else { return [] }
        return cases
    }()

    private static func rect(_ values: [Double]) -> CGRect {
        CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    /// The merged text of each case whose label starts with `prefix`, beside what it should be.
    private func replay(_ prefix: String) -> [(label: String, read: [String], expected: [String])] {
        Self.cases.filter { $0.label.hasPrefix(prefix) }.map { fixture in
            let parts = fixture.tiles.map { tile in
                (tile: OCRTile(rect: Self.rect(tile.rect), innerEdges: OCRTile.Edges(rawValue: tile.inner)),
                 pieces: tile.pieces.map { piece in
                     OCRPiece(line: OCRLine(text: piece.text, box: Self.rect(piece.box)),
                              words: piece.words?.map { OCRWord(start: $0.start, count: $0.count, box: Self.rect($0.box)) })
                 },
                 qrPayloads: [String]())
            }
            return (fixture.label, OCRTiling.merge(pieces: parts).lines.map(\.text), fixture.expected)
        }
    }

    private func expectExact(_ prefix: String, count: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let results = replay(prefix)
        #expect(results.count == count, "fixtures for \(prefix)", sourceLocation: sourceLocation)
        for result in results {
            #expect(result.read == result.expected, "\(result.label)", sourceLocation: sourceLocation)
        }
    }

    @Test func aURLAcrossACutReplaysExactlyWhereverTheCutFalls() {
        // 70 cuts along "…https://github.com/the-author/mac-apps/blob/main/ClearShot/README.md…" in Helvetica 40,
        // among them the 25 where a long token's evenly spread letters drifted and a letter came out twice.
        expectExact("url40 ", count: 70)
    }

    @Test func the6KLongLinesReplayExactly() {
        // Rows 1–12 of the 2 600 px page (row 1 across a cut in "kettle lemon", row 6 in "rocket saddle") and rows
        // 1–12 and 29 of the full-width page, each across two to four cuts.
        expectExact("6K ", count: 2)
    }

    @Test func twelveItemsKeepsItsTwelve() {
        // The cut swept 3 px at a time through and around "12" in "Total 12 items in the list".
        expectExact("12 items ", count: 21)
    }

    @Test func largeHeadingsReplayExactly() {
        // 64 and 72 px, the cut every 160 px across the heading.
        expectExact("heading ", count: 22)
    }
}
