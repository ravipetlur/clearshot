import CoreGraphics
import Testing
@testable import CSScrolling

struct OffsetMatcherTests {
    let configuration = StitchConfiguration(pixelsPerPoint: 2)
    var matcher: OffsetMatcher { OffsetMatcher(configuration: configuration) }
    let page = SyntheticPage.plain

    private func rows(_ frame: StitchFrame) -> LineHashes {
        LineHashes(frame, axis: .vertical, margin: configuration.edgeMarginPixels)
    }

    private func movement(from previous: LineHashes, to current: LineHashes, estimate: Int? = nil,
                          previousOffset: Int? = nil) -> Movement {
        matcher.compare(previous, current, previousOffset: previousOffset) { _ in estimate }.movement
    }

    /// Lines with the given keys, none blank.
    private func lines(_ keys: [UInt64]) -> LineHashes {
        LineHashes(hashes: keys, blank: Array(repeating: false, count: keys.count))
    }

    @Test func findsEachTrueOffset() {
        var position = 0
        for step in [137, 211, 401, 64, 333, 590, 12, 250, 700, 820] {
            let found = movement(from: rows(page.frame(at: position, length: 1000)),
                                 to: rows(page.frame(at: position + step, length: 1000)))
            #expect(found == .moved(step), "step \(step) from \(position)")
            position += step
        }
    }

    @Test func aWrongEstimateIsRejectedAndTheSearchFindsTheTruth() {
        let previous = rows(page.frame(at: 813, length: 1000))
        let current = rows(page.frame(at: 1146, length: 1000))
        var asked: [Range<Int>] = []
        let comparison = matcher.compare(previous, current, previousOffset: 64) { band in
            asked.append(band)
            return 591
        }
        #expect(comparison.movement == .moved(333))
        #expect(asked == [comparison.top..<(1000 - comparison.bottom)])
        // The right estimate is taken as it is.
        #expect(movement(from: previous, to: current, estimate: 332) == .moved(333))
        // At the pace before, Vision isn't asked and the search finds the truth.
        #expect(movement(from: previous, to: current, estimate: 591, previousOffset: 300) == .moved(333))
    }

    @Test func periodicContentPrefersTheEstimate() {
        // Rows repeating every 50: every offset 20 + 50k fits perfectly.
        let period = (0..<50).map { SyntheticPage.mix(UInt64($0)) }
        let previous = lines((0..<1000).map { period[$0 % 50] })
        let current = lines((120..<1120).map { period[$0 % 50] })
        #expect(movement(from: previous, to: current, estimate: 120) == .moved(120))
        // Without the estimate nothing tells them apart, the previous movement included: no match.
        #expect(movement(from: previous, to: current, previousOffset: 170) == .noMatch)
        #expect(movement(from: previous, to: current) == .noMatch)
    }

    @Test func blankOverlapsAreNoMatch() {
        // Text, then 800 blank rows, then text: two frames 500 apart overlap only in blank rows.
        let gappy = SyntheticPage(length: 2000, blank: 200..<1000)
        let previous = rows(gappy.frame(at: 0, length: 1000))
        let current = rows(gappy.frame(at: 500, length: 1000))
        #expect(movement(from: previous, to: current) == .noMatch)
        #expect(movement(from: previous, to: current, estimate: 500) == .noMatch)
    }

    @Test func aNegativeOffsetIsReportedAsScrollingBack() {
        let found = movement(from: rows(page.frame(at: 400, length: 1000)), to: rows(page.frame(at: 250, length: 1000)))
        #expect(found == .moved(-150))
    }

    @Test func eightyFivePercentEqualIsNoMatch() {
        var generator = SplitMix64(state: 7)
        let pageLines = (0..<1300).map { _ in generator.next() }
        let previous = lines(Array(pageLines[0..<1000]))
        // The frame 300 further on, with every line r where r % 20 < 3 (15%) or r % 10 == 0 (10%) changed.
        func current(changing changed: (Int) -> Bool) -> LineHashes {
            lines((0..<1000).map { changed($0) ? generator.next() : pageLines[300 + $0] })
        }
        #expect(movement(from: previous, to: current { $0 % 20 < 3 }, estimate: 300) == .noMatch)
        #expect(movement(from: previous, to: current { $0 % 10 == 0 }, estimate: 300) == .moved(300))
    }

    @Test func tooFewDistinctLinesIsNoMatch() {
        // Eight different lines over and over are just enough to trust; seven aren't, however well they fit.
        let eight = lines((0..<1000).map { SyntheticPage.mix(UInt64($0 % 8)) })
        let shifted = lines((3..<1003).map { SyntheticPage.mix(UInt64($0 % 8)) })
        #expect(movement(from: eight, to: shifted, estimate: 3) == .moved(3))
        let seven = lines((0..<1000).map { SyntheticPage.mix(UInt64($0 % 7)) })
        let sevenShifted = lines((3..<1003).map { SyntheticPage.mix(UInt64($0 % 7)) })
        #expect(movement(from: seven, to: sevenShifted, estimate: 3) == .noMatch)
    }

    @Test func visionReadsLongBandsAtSixteenHundred() {
        // Scaled to 800 px, a 2 400-line band under a floating button was misread on 11 of 90 moves at a random pace;
        // at 1 600 px, on 1. Shorter bands keep 800, at half the time an ask.
        let vision = VisionOffsetEstimator()
        #expect([1000, 1600, 1601, 1890, 2400].map(vision.side(forBand:)) == [800, 800, 1600, 1600, 1600])
        #expect(VisionOffsetEstimator(maximumSide: 400).side(forBand: 2400) == 1600)
        #expect(VisionOffsetEstimator(maximumSide: 2000).side(forBand: 2400) == 2000)
    }

    /// Vision on two frames 300 lines apart: a sign or scale mistake in turning its translation into an offset would
    /// show here (the stitcher would still recover by searching, so its tests can't see it). Vision's readings vary with
    /// the OS and even the build, so this only guards against catastrophic failure: each estimate must be within a
    /// quarter of the band (250 lines) of the truth, which a flipped sign (−300) or a lost scale (0 or 600) is not.
    /// Exact offsets are the matcher's job, tested on synthetic lines.
    @Test(.timeLimit(.minutes(2)))
    func visionsEstimateHasTheScrollSign() throws {
        let vision = VisionOffsetEstimator()
        let tolerance = 1000 / 4
        let down = try #require(vision.estimate(from: page.frame(at: 0, length: 1000), to: page.frame(at: 300, length: 1000),
                                                band: 0..<1000, axis: .vertical))
        #expect(abs(down - 300) < tolerance, "down: \(down)")
        let up = try #require(vision.estimate(from: page.frame(at: 300, length: 1000), to: page.frame(at: 0, length: 1000),
                                              band: 0..<1000, axis: .vertical))
        #expect(abs(up + 300) < tolerance, "up: \(up)")
        let right = try #require(vision.estimate(from: page.frame(at: 0, length: 1000, axis: .horizontal),
                                                 to: page.frame(at: 300, length: 1000, axis: .horizontal),
                                                 band: 0..<1000, axis: .horizontal))
        #expect(abs(right - 300) < tolerance, "right: \(right)")
        #expect(NoOffsetEstimate().estimate(from: page.frame(at: 0, length: 100), to: page.frame(at: 10, length: 100),
                                            band: 0..<100, axis: .vertical) == nil)
    }
}
