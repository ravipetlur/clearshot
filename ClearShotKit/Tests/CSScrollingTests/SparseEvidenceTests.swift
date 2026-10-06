import CoreGraphics
import Testing
@testable import CSScrolling

/// A match by whole lines that rests on little: fewer than 64 different equal lines, or equal lines under a quarter of
/// the lines it pairs (sticky lines aside), is what one repeated element and whitespace can give. Alone, such a match
/// moves the stitch forward only at the pace before or with Vision agreeing, and never makes it follow a scroll back.
struct SparseEvidenceTests {
    /// A mostly blank page: one identical 40-row banner every 1 100 rows (at 500–539 of each period), and 26-row lines
    /// of their own at 100 and 250 of each period; `length` lines from `position`.
    static func sparsePage(at position: Int, length: Int = 1000) -> StitchFrame {
        UnambiguousTests.page(length: length) { line, row in
            let page = position + line
            let inPeriod = page % 1100
            if (500..<540).contains(inPeriod) {
                for x in 40..<760 { row[x] = UnambiguousTests.ink(UInt64(inPeriod * 1000 + x / 5)) }
            } else if (100..<126).contains(inPeriod) || (250..<276).contains(inPeriod) {
                for x in 60..<600 { row[x] = UnambiguousTests.ink(UInt64(page * 1000 + x / 4)) }
            }
        }
    }

    // MARK: W1: a flick past the range, then the next identical banner

    @Test(arguments: [0, 1, 2])
    func aFlickOntoTheNextBannerIsNeverFollowedBack(estimator kind: Int) {
        // Steps of 150, a flick to 1 700 (beyond the range), then steps of 150. At c54826e the frame at 1 850 was
        // followed as back 650 on the next banner and blank lines alone, the warning cleared, and the stitch went on
        // 2 200 rows behind the page: wrong rows from 1 350, unwarned. No estimate, the true one, and one misreading
        // the flick as 300.
        let positions = [0, 150, 300, 1700, 1850, 2000, 2150, 2300, 2450, 2600]
        let frames = positions.map { Self.sparsePage(at: $0) }
        let estimates: [Int]? = kind == 0 ? nil : positions
        let (updates, image) = UnambiguousTests.stitch(frames, positions: estimates, overrides: kind == 2 ? [3: 300] : [:])
        UnambiguousTests.expectExactOrWarned(updates, positions: positions)
        #expect(!updates.contains { $0.trace?.outcome == .followed }, "a follow: \(updates.map { $0.trace?.description ?? "" })")
        UnambiguousTests.expectRows(image, of: Self.sparsePage(at: 0, length: 3600), height: image?.height)
        if kind != 0 {
            // With an estimate the first moves are taken, and the frame at 1 850 says why it isn't followed.
            #expect(updates[1...2].allSatisfy { $0.accepted && $0.offset == 150 })
            #expect(updates[4].trace?.comparisons.first?.description.hasSuffix(
                "no match; back 650 on 40 whole lines of 350: too few to follow back") == true,
                "\(updates[4].trace?.description ?? "")")
        }
    }

    // MARK: The guard

    @Test func aSparseWholeLineMatchMovesOnlyAtThePaceOrWithVision() {
        // The page above, 150 down: by whole lines, 66 equal lines of the 850 it pairs (a banner and a line).
        let configuration = StitchConfiguration(pixelsPerPoint: 2)
        let margin = configuration.edgeMarginPixels
        let matcher = OffsetMatcher(configuration: configuration)
        let top = LineHashes(Self.sparsePage(at: 0), axis: .vertical, margin: margin)
        let down = LineHashes(Self.sparsePage(at: 150), axis: .vertical, margin: margin)
        func movement(from previous: LineHashes, to current: LineHashes, previousOffset: Int?, estimate: Int?) -> Movement {
            matcher.compare(previous, current, previousOffset: previousOffset) { _ in estimate }.movement
        }
        // A new pace: only with Vision agreeing.
        #expect(movement(from: top, to: down, previousOffset: nil, estimate: 150) == .moved(150))
        #expect(movement(from: top, to: down, previousOffset: nil, estimate: 151) == .moved(150))
        #expect(movement(from: top, to: down, previousOffset: nil, estimate: nil) == .noMatch)
        #expect(movement(from: top, to: down, previousOffset: nil, estimate: 400) == .noMatch)
        #expect(movement(from: top, to: down, previousOffset: 40, estimate: nil) == .noMatch)
        // The pace before: Vision isn't asked.
        #expect(movement(from: top, to: down, previousOffset: 150, estimate: 400) == .moved(150))
        // A scroll back on so little is never followed, Vision agreeing or not.
        #expect(movement(from: down, to: top, previousOffset: 150, estimate: -150) == .noMatch)
        #expect(movement(from: down, to: top, previousOffset: 150, estimate: nil) == .noMatch)
    }

    @Test func plainTextIsNeverSparse() {
        // Text 300 down, and 820 down (an 82% step on a 1 000-line frame), and text between a 400-line header and a
        // 390-line footer: the lone whole-line match stands against an estimate that disagrees.
        let configuration = StitchConfiguration(pixelsPerPoint: 2)
        let margin = configuration.edgeMarginPixels
        let matcher = OffsetMatcher(configuration: configuration)
        func rows(_ frame: StitchFrame) -> LineHashes { LineHashes(frame, axis: .vertical, margin: margin) }
        let page = SyntheticPage.plain
        for step in [300, 820] {
            let comparison = matcher.compare(rows(page.frame(at: 0, length: 1000)), rows(page.frame(at: step, length: 1000)),
                                             previousOffset: nil) { _ in 591 }
            #expect(comparison.movement == .moved(step), "step \(step): \(comparison.movement)")
        }
        let banded = SyntheticPage(length: 2000, header: 400, footer: 390)
        let comparison = matcher.compare(rows(banded.frame(at: 9, length: 1000)), rows(banded.frame(at: 109, length: 1000)),
                                         previousOffset: nil) { _ in 591 }
        #expect(comparison.movement == .moved(100), "banded: \(comparison.movement)")
    }
}
