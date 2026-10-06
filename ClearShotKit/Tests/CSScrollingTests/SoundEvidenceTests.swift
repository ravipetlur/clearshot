import CoreGraphics
import Testing
@testable import CSScrolling

/// Evidence for an offset is counted over every line it pairs: of several that verify, Vision's estimate picks first,
/// and the pieces that tell them apart only without one, the others' evidence weighed over every line they pair;
/// reference content paired with blank counts against; the contradictions a fixed element doesn't explain span at most
/// a quarter of the lines with something on them; and an estimate asked for that falls nowhere near the one offset that
/// verifies, by pieces only, is a no-match.
struct SoundEvidenceTests {
    // MARK: An element moving faster than the page over a blank stretch

    /// A mostly blank page with text from page row 800 down, scrolled to `position`, and a 40-row patterned element at
    /// frame line `element`, `length` lines.
    static func blankAboveText(at position: Int, element: Int, length: Int = 1000) -> StitchFrame {
        let text = SyntheticPage(width: 800, length: 3000, seed: 5).frame(at: position, length: length)
        return UnambiguousTests.page(length: length) { line, row in
            if position + line >= 800 {
                text.pixels.withUnsafeBytes { bytes in
                    for x in 0..<800 { row[x] = bytes.loadUnaligned(fromByteOffset: line * 3200 + x * 4, as: UInt32.self) }
                }
            }
            if (element..<(element + 40)).contains(line) {
                for x in 200..<600 { row[x] = UnambiguousTests.ink(UInt64(4_000_000 + (line - element) * 1000 + x / 4)) }
            }
        }
    }

    @Test(arguments: [(200, 300), (300, 200)], [nil, 100] as [Int?])
    func anElementFasterThanThePageNeverGivesItsOwnOffset(element: (row: Int, offset: Int), estimate: Int?) {
        // The reference: blank but for the element at row 500 and text in rows 800–999. The page moves 100 (the text
        // now in rows 700–899, new text below); the element moves faster, to `row`, so its own offset is `offset`. Both
        // verify at 03c7a15, and the pieces the two pair in common favour the element's.
        let configuration = StitchConfiguration(pixelsPerPoint: 2)
        let margin = configuration.edgeMarginPixels
        let reference = LineHashes(Self.blankAboveText(at: 0, element: 500), axis: .vertical, margin: margin)
        let current = LineHashes(Self.blankAboveText(at: 100, element: element.row), axis: .vertical, margin: margin)
        let comparison = OffsetMatcher(configuration: configuration)
            .compare(reference, current, previousOffset: 100) { _ in estimate }
        #expect(comparison.movement == .moved(100) || comparison.movement == .noMatch,
                "element offset \(element.offset), estimate \(estimate.map(String.init) ?? "none"): \(comparison.movement)")
    }

    @Test(arguments: [false, true])
    func anElementFasterThanThePageStitchesExactlyOrWarns(withEstimate: Bool) {
        let frames = [Self.blankAboveText(at: 0, element: 500), Self.blankAboveText(at: 100, element: 200)]
        let (updates, image) = UnambiguousTests.stitch(frames, positions: withEstimate ? [0, 100] : nil, axis: .vertical)
        let update = updates[1]
        if update.accepted {
            #expect(update.offset == 100, "\(update.trace?.description ?? "")")
            // The first frame, then page rows 1 000–1 099 from the second.
            UnambiguousTests.expectRows(image, of: Self.blankAboveText(at: 0, element: 500, length: 1100))
        } else {
            #expect(update.warnings.contains(.slowDown), "not stitched and no warning: \(update.trace?.description ?? "")")
            UnambiguousTests.expectRows(image, of: frames[0])
        }
    }

    // MARK: A flick past the range onto the next identical banner

    /// A mostly blank page: an identical 40-row banner every 1 100 rows, and 300 rows after each a 26-row line of its
    /// own; `length` lines from `position`.
    static func bannersAndLines(at position: Int, length: Int = 1000) -> StitchFrame {
        UnambiguousTests.page(length: length) { line, row in
            let page = position + line
            let inPeriod = page % 1100
            if (500..<540).contains(inPeriod) {
                for x in 40..<760 { row[x] = UnambiguousTests.ink(UInt64(inPeriod * 1000 + x / 5)) }
            } else if (800..<826).contains(inPeriod) {
                for x in 60..<500 { row[x] = UnambiguousTests.ink(UInt64(page * 1000 + x / 4)) }
            }
        }
    }

    @Test func aFlickOntoTheNextIdenticalBannerWarnsAndKeepsTheUniqueLine() {
        // Steps of 150, a flick of 1 100 (beyond the range), then steps of 150 again. At 03c7a15 the frame at 1 550 was
        // taken as 150 on from 300, pairing the next banner and forgiving the unique line: 1 100 rows lost unwarned.
        // The estimate is the true movement: the first moves rest on a banner and a line (66 whole lines of 850), which
        // moves at a new pace only with Vision agreeing.
        let positions = [0, 150, 300, 1400, 1550, 1700]
        let (updates, image) = UnambiguousTests.stitch(positions.map { Self.bannersAndLines(at: $0) }, positions: positions)
        #expect(updates[1...2].allSatisfy { $0.accepted && $0.offset == 150 })
        for update in updates[4...] {
            #expect(!update.accepted && update.warnings.contains(.slowDown), "\(update.trace?.description ?? "")")
        }
        // Every row up to the last frame stitched, the unique line at 800–825 among them.
        UnambiguousTests.expectRows(image, of: Self.bannersAndLines(at: 0, length: 1300))
    }

    // MARK: Identical banners beside a dense sidebar, with the estimate

    /// Identical 40-row banners every 300 rows on a blank page, beside a 100-px sidebar with something of its own on
    /// every line that stays put; `length` lines from `position`.
    static func bannersBesideADenseSidebar(at position: Int, length: Int = 1000) -> StitchFrame {
        UnambiguousTests.page(length: length) { line, row in
            let inPeriod = (position + line) % 300
            if (100..<140).contains(inPeriod) {
                for x in 32..<768 { row[x] = UnambiguousTests.ink(UInt64(inPeriod * 1000 + x / 5)) }
            }
            for x in 0..<100 { row[x] = UnambiguousTests.ink(UInt64(line * 1000 + x / 3)) }
        }
    }

    @Test func identicalBannersBesideADenseSidebarNeverRepeatAPeriod() {
        // The true estimate every time: at 03c7a15 the truth failed for the sidebar's fixed pieces, one alias with a
        // short overlap verified alone and was taken although the estimate disagreed, and one banner period (300 rows)
        // was repeated.
        let positions = [0, 150, 350, 500, 650, 850, 1000, 1150, 1300]
        let frames = positions.map { Self.bannersBesideADenseSidebar(at: $0) }
        let (updates, image) = UnambiguousTests.stitch(frames, positions: positions, axis: .vertical)
        UnambiguousTests.expectExactOrWarned(updates, positions: positions)
        // The page is periodic, so its rows can't show a repeated period: the length must be the last accepted frame's.
        let last = updates.lastIndex { $0.accepted }.map { positions[$0] } ?? 0
        #expect(image?.height == 1000 + last)
        UnambiguousTests.expectRows(image, of: Self.bannersBesideADenseSidebar(at: 0, length: 2300), columns: 100..<800,
                                    height: image?.height)
    }

    @Test func pairingMoreOfARepeatingPageIsNoEvidence() {
        // A guard for weighing over all the lines an offset pairs: identical 40-row banners every 300 rows under a
        // fixed disc, 1 050 rows apart (beyond the range). Every offset 150 + 300k verifies; the one with the most
        // overlap pairs one banner more than the others, which says nothing about which is right.
        let configuration = StitchConfiguration(pixelsPerPoint: 2)
        let margin = configuration.edgeMarginPixels
        func frame(at position: Int) -> LineHashes {
            let page = UnambiguousTests.page(length: 1000) { line, row in
                let inPeriod = (position + line) % 300
                guard (100..<140).contains(inPeriod) else { return }
                for x in 32..<768 { row[x] = UnambiguousTests.ink(UInt64(inPeriod * 1000 + x / 5)) }
            }
            return LineHashes(page.paintingDisc(centerX: 700, centerY: 500, radius: 44, color: 0xFF22_88EE), axis: .vertical,
                              margin: margin)
        }
        let comparison = OffsetMatcher(configuration: configuration).compare(frame(at: 0), frame(at: 1050),
                                                                           previousOffset: 350) { _ in nil }
        #expect(comparison.movement == .noMatch, "\(comparison.movement), verified \(comparison.verified)")
    }

    @Test func aDisagreeingEstimateVetoesALoneMatchByPiecesNotByWholeLines() throws {
        // The first move, 300 down, and an estimate of 591 that is nowhere near it.
        let page = SyntheticPage.plain
        func withButton(_ frame: StitchFrame) -> StitchFrame {
            frame.paintingDisc(centerX: frame.width - 48 - 44, centerY: frame.height - 48 - 44, radius: 44, color: 0xFF22_88EE)
        }
        // Whole lines verify it alone: exact line matching is the verifier, and Vision only proposes. Taken.
        let text = [page.frame(at: 0, length: 1000), page.frame(at: 300, length: 1000)]
        let (lines, linesImage) = UnambiguousTests.stitch(text, positions: [0, 300], overrides: [1: 591], axis: .vertical)
        #expect(lines[1].accepted && lines[1].offset == 300 && lines[1].warnings.isEmpty)
        let byLines = try #require(lines[1].trace?.comparisons.first)
        #expect(byLines.estimate == 591 && byLines.movement == .moved(300) && byLines.byPieces == nil)
        UnambiguousTests.expectRows(linesImage, of: page.frame(at: 0, length: 1300))
        // Under a floating button only pieces verify it: the estimate says it may be an alias. Warned, not taken.
        let buttoned = text.map(withButton)
        let (pieces, piecesImage) = UnambiguousTests.stitch(buttoned, positions: [0, 300], overrides: [1: 591],
                                                            axis: .vertical)
        #expect(!pieces[1].accepted && pieces[1].noMatch && pieces[1].warnings == [.slowDown])
        let byPieces = try #require(pieces[1].trace?.comparisons.first)
        #expect(byPieces.description.hasSuffix("estimate 591, no match; only 300 verifies, by pieces, and the estimate is "
            + "not there"), "\(byPieces.description)")
        UnambiguousTests.expectRows(piecesImage, of: buttoned[0])
    }
}
