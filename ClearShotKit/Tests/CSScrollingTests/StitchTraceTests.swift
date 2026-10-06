import CoreGraphics
import Dispatch
import Synchronization
import Testing
@testable import CSScrolling

/// The capture log's view of each frame (`StitchTrace`): what was compared, Vision's estimate, the verdict, and for a
/// frame with no verified match the offset that came closest and where it failed, which tells a too-fast scroll from
/// content that doesn't scroll with the page.
struct StitchTraceTests {
    let page = SyntheticPage.plain
    let configuration = StitchConfiguration(pixelsPerPoint: 2)

    private func stitcher(estimator: any OffsetEstimator = NoOffsetEstimate()) -> Stitcher {
        Stitcher(configuration: configuration, estimator: estimator)
    }

    /// The frame with a round floating button (back to top, a chat bubble) `radius` px, 48 px in from the bottom right.
    private func withButton(_ frame: StitchFrame, radius: Int = 40) -> StitchFrame {
        frame.paintingDisc(centerX: frame.width - 48 - radius, centerY: frame.height - 48 - radius, radius: radius,
                           color: 0xFF22_88EE)
    }

    @Test func anAcceptedFrameIsTracedWithItsEstimateAndTheStickyBands() throws {
        let sticky = SyntheticPage.sticky
        var stitcher = stitcher(estimator: FixedEstimate(value: 211))
        let first = stitcher.add(sticky.frame(at: 0, length: 1200))
        #expect(first.trace?.comparisons == [])
        #expect(first.trace?.description == "first frame | 0.0 ms, 0 skipped")
        // Body rows 0, 100 and 311 are blank, text and text, and so are the last ones: only the bands are unchanged in place.
        _ = stitcher.add(sticky.frame(at: 100, length: 1200))
        let update = stitcher.add(sticky.frame(at: 311, length: 1200))
        let trace = try #require(update.trace)
        #expect(trace.comparisons.count == 1)
        let comparison = try #require(trace.comparisons.first)
        #expect(comparison.axis == .vertical && comparison.top == 80 && comparison.bottom == 60)
        #expect(comparison.band == 1060 && comparison.estimate == 211 && comparison.movement == .moved(211))
        #expect(comparison.nearMiss == nil)
        #expect(trace.previousOffset == 100 && trace.stickyBands == StickyBands(leading: 80, trailing: 60))
        #expect(trace.outcome == .stitched(newLines: 211, band: 60))
        #expect(trace.description == "vertical: top 80, bottom 60, band 1060, estimate 211, moved 211 | stitched 211 lines, "
            + "band 60 | sticky 80/60 | previous 100 | 0.0 ms, 0 skipped")
    }

    @Test func beforeTheLockBothAxesAreTraced() throws {
        var stitcher = stitcher()
        _ = stitcher.add(page.frame(at: 0, length: 1000))
        // 950 past: 50 lines of overlap, too little on either axis.
        let update = stitcher.add(page.frame(at: 950, length: 1000))
        #expect(update.noMatch)
        let axes = try #require(update.trace?.comparisons).map(\.axis)
        #expect(axes == [.vertical, .horizontal])
    }

    @Test func aTooFastScrollHasNothingInCommonAtAnyOffset() throws {
        var stitcher = stitcher()
        _ = stitcher.add(page.frame(at: 0, length: 1000))
        _ = stitcher.add(page.frame(at: 300, length: 1000))
        // 1 200 past the last accepted frame: no overlap (a piece or two of a line may be equal by chance).
        let update = stitcher.add(page.frame(at: 1500, length: 1000))
        #expect(update.noMatch && update.warnings == [.slowDown])
        let comparison = try #require(update.trace?.comparisons.first)
        #expect(comparison.movement == .noMatch && comparison.nearMiss == nil)
        #expect(comparison.description.hasSuffix(", estimate none, no match; nothing in common at any offset"))
    }

    @Test func aFloatingButtonIsMatchedByPiecesAndKeptInTheBand() throws {
        // The button is in both frames, fixed while the page moves 300 under it: whole lines don't match (the reference's
        // button rows pair with page), pieces do, and the band reaches up past the button (48 + 80 lines from the bottom).
        var stitcher = stitcher()
        #expect(stitcher.add(withButton(page.frame(at: 0, length: 1000))).accepted)
        let update = stitcher.add(withButton(page.frame(at: 300, length: 1000)))
        #expect(update.accepted && update.offset == 300)
        let trace = try #require(update.trace)
        let comparison = try #require(trace.comparisons.first)
        #expect(comparison.movement == .moved(300) && comparison.byPieces != nil && comparison.nearMiss == nil)
        guard case .stitched(let newLines, let band)? = trace.outcome else {
            Issue.record("not stitched: \(trace)")
            return
        }
        #expect(newLines == 300 && band >= 128)
        #expect(trace.description.contains("moved 300 by pieces ("))
    }

    @Test func aStuckSidebarIsMatchedByPiecesWithItsPiecesLeftOut() throws {
        // A 200-px sidebar that stays put while the page moves 200: nearly every line has sidebar text, so whole lines
        // are hardly ever equal; the sidebar's pieces, equal in place, are left out and the rest move by 200.
        let sidebar = SyntheticPage(width: 200, length: 2000, seed: 99)
        func frame(at position: Int) -> StitchFrame {
            page.frame(at: position, length: 1000).replacingColumns(with: sidebar.frame(at: 0, length: 1000))
        }
        var stitcher = stitcher()
        _ = stitcher.add(frame(at: 0))
        let update = stitcher.add(frame(at: 200))
        #expect(update.accepted && update.offset == 200)
        let pieces = try #require(update.trace?.comparisons.first?.byPieces)
        #expect(pieces.offset == 200 && pieces.fixed > 0)
    }

    @Test func aBlockThatChangedAfterItsFrameWasStitchedShowsAsOneRunWhereItIs() throws {
        // Page rows 600–949 (lines 600–949 of the first frame, 350 of them) show another picture once the frame is
        // stitched, as an image that loads does: too tall to forgive. 100 further on they are lines 500–849.
        func frame(at position: Int, loaded: Bool) -> StitchFrame {
            let picture = SyntheticPage(width: 800, length: 2000, seed: loaded ? 31 : 17).frame(at: 600, length: 350)
            let frame = page.frame(at: position, length: 1000)
            var pixels = frame.pixels
            pixels.withUnsafeMutableBytes { bytes in
                picture.pixels.withUnsafeBytes { source in
                    for row in 0..<350 {
                        (bytes.baseAddress! + (600 - position + row) * frame.bytesPerRow + 400)
                            .copyMemory(from: source.baseAddress! + row * picture.bytesPerRow + 400, byteCount: 600 * 4)
                    }
                }
            }
            return StitchFrame(width: 800, height: 1000, bytesPerRow: 3200, pixels: pixels, colorSpace: frame.colorSpace)
        }
        var stitcher = stitcher()
        #expect(stitcher.add(frame(at: 0, loaded: false)).accepted)
        let update = stitcher.add(frame(at: 100, loaded: true))
        #expect(update.noMatch)
        let nearMiss = try #require(update.trace?.comparisons.first?.nearMiss)
        #expect(nearMiss.offset == 100 && nearMiss.mismatchedRuns.count == 1 && nearMiss.runCount == 1)
        if let run = nearMiss.mismatchedRuns.first {
            #expect(run.lowerBound >= 500 && run.upperBound <= 850 && run.count > 300)
        }
    }
    @Test func aNearMissIsDescribedForTheLog() {
        let nearMiss = StitchTrace.NearMiss(offset: 300, equal: 898, compared: 1000, mismatchedRuns: [572..<652], runCount: 1,
                                            equalAcross: [100, 100, 100, 100, 100, 100, 92, 13])
        let comparison = StitchTrace.Comparison(axis: .vertical, top: 0, bottom: 0, band: 1000, estimate: 297,
                                                movement: .noMatch, nearMiss: nearMiss)
        var trace = StitchTrace(comparisons: [comparison], previousOffset: 300, stickyBands: StickyBands(leading: 0, trailing: 0))
        trace.milliseconds = 41.26
        trace.framesSkipped = 2
        #expect(trace.description == "vertical: top 0, bottom 0, band 1000, estimate 297, no match; closest 300: 898/1000 equal "
            + "(89.8%), 1 mismatched run: 572..<652, equal across 100 100 100 100 100 100 92 13 | sticky 0/0 | previous 300 | "
            + "41.3 ms, 2 skipped")
        let back = StitchTrace.Comparison(axis: .horizontal, top: 3, bottom: 4, band: 993, estimate: nil, movement: .moved(-40))
        let flat = StitchTrace.NearMiss(offset: -12, equal: 9, compared: 90, mismatchedRuns: [0..<40, 50..<90], runCount: 9,
                                        equalAcross: [nil, 10])
        let other = StitchTrace.Comparison(axis: .vertical, top: 1, bottom: 2, band: 997, estimate: nil, movement: .noMatch,
                                           nearMiss: flat)
        #expect(back.description == "horizontal: top 3, bottom 4, band 993, estimate none, back 40")
        #expect(other.description == "vertical: top 1, bottom 2, band 997, estimate none, no match; closest -12: 9/90 equal "
            + "(10.0%), 9 mismatched runs, the largest 0..<40 50..<90, equal across - 10")
        #expect(StitchTrace(ignored: .otherSize).description == "ignored: another size | 0.0 ms, 0 skipped")
        let pieces = PieceMatcher.Match(offset: 260, support: 4582, contradictions: 26, fixed: 75, neutral: 120,
                                        forgivenRuns: [759..<785, 899..<910])
        let byPieces = StitchTrace.Comparison(axis: .vertical, top: 0, bottom: 0, band: 1000, estimate: nil,
                                              movement: .moved(260), byPieces: pieces)
        #expect(byPieces.description == "vertical: top 0, bottom 0, band 1000, estimate none, moved 260 by pieces "
            + "(4582 for, 26 against, 75 fixed, 120 periodic; forgiven 759..<785 899..<910)")
        #expect(StitchTrace(comparisons: [back], outcome: .followed).description
            == "horizontal: top 3, bottom 4, band 993, estimate none, back 40 | followed, nothing new | 0.0 ms, 0 skipped")
        #expect(StitchTrace(outcome: .tooFar).description == "too far for what is stitched | 0.0 ms, 0 skipped")
        let still = StitchTrace.Comparison(axis: .vertical, top: 0, bottom: 0, band: 1000, estimate: nil, movement: .animation,
                                           stoodStill: true)
        #expect(still.description
            == "vertical: top 0, bottom 0, band 1000, estimate none, still by pieces (only a small part changed in place)")
    }

    @Test func theSessionTracesSkippedFramesAndTheTimeTaken() async throws {
        let gate = HoldingEstimator()
        let (deliveries, continuation) = AsyncStream.makeStream(of: StitchUpdate.self)
        let session = StitchSession(stitcher: Stitcher(configuration: StitchConfiguration(pixelsPerPoint: 2, axis: .vertical),
                                                       estimator: gate),
                                    previewSide: 400) { update, _ in continuation.yield(update) }
        var updates = deliveries.makeAsyncIterator()
        session.submit(page.frame(at: 0, length: 1000))
        #expect(await updates.next()?.trace?.framesSkipped == 0)
        // The queue is held in the next frame's estimate while three more arrive: two are replaced unseen.
        session.submit(page.frame(at: 100, length: 1000))
        #expect(gate.waitUntilHeld())
        for position in [200, 300, 400] { session.submit(page.frame(at: position, length: 1000)) }
        gate.letGo()
        let held = try #require(await updates.next()?.trace)
        #expect(held.framesSkipped == 0 && held.milliseconds > 0)
        let next = try #require(await updates.next())
        #expect(next.offset == 300 && next.trace?.framesSkipped == 2)
        _ = await session.finish()
    }
}

/// Always proposes the same offset.
private struct FixedEstimate: OffsetEstimator {
    let value: Int

    func estimate(from previous: StitchFrame, to current: StitchFrame, band: Range<Int>, axis: ScrollAxis) -> Int? {
        value
    }
}

/// Holds the stitching queue inside its first estimate until released (a few milliseconds at least); passes every later
/// one through.
private final class HoldingEstimator: OffsetEstimator, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let isFirst = Mutex(true)

    func waitUntilHeld() -> Bool {
        entered.wait(timeout: .now() + 20) == .success
    }

    func letGo() {
        release.signal()
    }

    func estimate(from previous: StitchFrame, to current: StitchFrame, band: Range<Int>, axis: ScrollAxis) -> Int? {
        let first = isFirst.withLock { isFirst in
            defer { isFirst = false }
            return isFirst
        }
        if first {
            entered.signal()
            release.wait()
        }
        return nil
    }
}

extension StitchFrame {
    /// This frame with a filled disc (a BGRA word, 0xAARRGGBB) of `radius` px centred at (`centerX`, `centerY`); every
    /// row of it is a different width, as a round button's are.
    func paintingDisc(centerX: Int, centerY: Int, radius: Int, color: UInt32) -> StitchFrame {
        var pixels = pixels
        pixels.withUnsafeMutableBytes { bytes in
            for y in (centerY - radius)..<(centerY + radius) {
                let dy = Double(y - centerY) + 0.5
                let half = Int((Double(radius * radius) - dy * dy).squareRoot())
                for x in (centerX - half)..<(centerX + half) {
                    bytes.storeBytes(of: color.littleEndian, toByteOffset: y * bytesPerRow + x * 4, as: UInt32.self)
                }
            }
        }
        return StitchFrame(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels, colorSpace: colorSpace)
    }

    /// This frame with its first `columns.width` columns replaced by `columns` (as tall as this frame).
    func replacingColumns(with columns: StitchFrame) -> StitchFrame {
        precondition(columns.height == height && columns.width <= width)
        var pixels = pixels
        pixels.withUnsafeMutableBytes { bytes in
            columns.pixels.withUnsafeBytes { source in
                for y in 0..<height {
                    (bytes.baseAddress! + y * bytesPerRow).copyMemory(from: source.baseAddress! + y * columns.bytesPerRow,
                                                                      byteCount: columns.width * 4)
                }
            }
        }
        return StitchFrame(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels, colorSpace: colorSpace)
    }
}
