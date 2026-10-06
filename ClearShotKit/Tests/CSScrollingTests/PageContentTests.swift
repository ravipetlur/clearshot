import CoreGraphics
import Synchronization
import Testing
@testable import CSScrolling

/// Real pages scroll content past things that don't scroll with it: a floating button, a sidebar that sticks, a block
/// that changes after its frame was stitched. Each used to stop the stitch for good with "Please slow down…" however
/// slowly the page moved; and a too-fast scroll could only be recovered by scrolling back.
struct PageContentTests {
    let page = SyntheticPage.plain
    let configuration = StitchConfiguration(pixelsPerPoint: 2)
    /// Slow steps, 6–14% of a 1 000-line frame.
    static let slowPositions = [0, 90, 200, 330, 420, 560, 650, 790, 900, 1030]

    private func stitcher(estimator: any OffsetEstimator = NoOffsetEstimate()) -> Stitcher {
        Stitcher(configuration: configuration, estimator: estimator)
    }

    /// A round floating button (back to top, a chat bubble) 88 px across, 48 px in from the bottom right of a 1000-line
    /// frame: over the ends of the longest text lines.
    private func withButton(_ frame: StitchFrame) -> StitchFrame {
        frame.paintingDisc(centerX: frame.width - 48 - 44, centerY: frame.height - 48 - 44, radius: 44, color: 0xFF22_88EE)
    }

    // MARK: A: a floating button

    @Test func aFloatingButtonDoesNotStopTheStitch() {
        var stitcher = stitcher()
        let updates = Self.slowPositions.map { stitcher.add(withButton(page.frame(at: $0, length: 1000))) }
        #expect(updates.map(\.accepted) == Array(repeating: true, count: Self.slowPositions.count))
        #expect(updates.map(\.offset) == [0] + zip(Self.slowPositions.dropFirst(), Self.slowPositions).map { $0 - $1 })
        #expect(updates.allSatisfy { $0.warnings.isEmpty && !$0.noMatch })
    }

    @Test func aFloatingButtonIsDrawnOnceAtTheEndWithThePageUnderItIntact() throws {
        var stitcher = stitcher()
        for position in Self.slowPositions { _ = stitcher.add(withButton(page.frame(at: position, length: 1000))) }
        let composed = stitcher.compose()
        let image = try #require(composed)
        // The page from the first frame's top to the last frame's bottom, every row once, and the button only where the
        // last frame had it.
        let height = 1000 + Self.slowPositions.last!
        let expected = withButton(StitchFrame(width: 800, height: height, bytesPerRow: 3200,
                                              pixels: page.expected(to: Self.slowPositions.last!, length: 1000),
                                              colorSpace: page.colorSpace))
        #expect(image.width == 800 && image.height == height)
        let difference = firstDifferentRow(tightBytes(of: image), expected.pixels, rowBytes: 3200)
        #expect(difference == nil, "first differing row: \(difference ?? -1)")
    }

    @Test func aFloatingButtonDoesNotLetATooFastScrollThrough() {
        // 1 200 past the last accepted frame: nothing in common but the button, which stayed put.
        var stitcher = stitcher()
        _ = stitcher.add(withButton(page.frame(at: 0, length: 1000)))
        _ = stitcher.add(withButton(page.frame(at: 100, length: 1000)))
        let update = stitcher.add(withButton(page.frame(at: 1300, length: 1000)))
        #expect(!update.accepted && update.noMatch && update.warnings == [.slowDown])
    }

    // MARK: B: a sidebar that sticks

    /// The page with a 200-px sidebar on its left that scrolls with it until the page passes row 300, then stays put.
    private func withStickingSidebar(at position: Int) -> StitchFrame {
        let sidebar = SyntheticPage(width: 200, length: 4000, seed: 99)
        return page.frame(at: position, length: 1000).replacingColumns(with: sidebar.frame(at: min(position, 300), length: 1000))
    }

    @Test func aSidebarThatSticksDoesNotStopTheStitch() throws {
        var stitcher = stitcher()
        let updates = Self.slowPositions.map { stitcher.add(withStickingSidebar(at: $0)) }
        // The frame where the sidebar sticks moved it 100 against the page's 130: two parts moving apart, which pieces
        // can't tell from a wrong match, so it warns (no columns are set aside). From the next frame the sidebar has
        // stayed put since the frame before, and the page is measured from the last one stitched.
        #expect(updates.map(\.accepted) == [true, true, true, false, true, true, true, true, true, true])
        #expect(updates.map(\.offset) == [0, 90, 110, 0, 220, 140, 90, 140, 110, 130])
        #expect(updates.enumerated().allSatisfy { $1.warnings == ($0 == 3 ? [.slowDown] : []) })
        // The page right of the sidebar comes out whole, every row once (the sidebar's own columns repeat its slice in
        // each strip: a known limit).
        let composed = stitcher.compose()
        let image = try #require(composed)
        let height = 1000 + Self.slowPositions.last!
        #expect(image.width == 800 && image.height == height)
        let content = columns(200..<800, of: tightBytes(of: image), width: 800)
        let expected = columns(200..<800, of: page.expected(to: Self.slowPositions.last!, length: 1000), width: 800)
        let difference = firstDifferentRow(content, expected, rowBytes: 600 * 4)
        #expect(difference == nil, "first differing row: \(difference ?? -1)")
    }

    // MARK: C: a block that changed after its frame was stitched

    /// A frame of the page at `position` with page rows 1 750–2 099, columns 100–699, showing `state`: a picture of
    /// its own (another page's text), as an image that loads after its placeholder was stitched.
    private func withBlock(at position: Int, loaded: Bool) -> StitchFrame {
        let state = SyntheticPage(width: 800, length: 4000, seed: loaded ? 31 : 17)
        var frame = page.frame(at: position, length: 1000)
        guard max(1750, position) < min(2100, position + 1000) else { return frame }
        let rows = max(1750, position)..<min(2100, position + 1000)
        let picture = state.frame(at: rows.lowerBound, length: rows.count)
        var pixels = frame.pixels
        pixels.withUnsafeMutableBytes { bytes in
            picture.pixels.withUnsafeBytes { source in
                for row in 0..<rows.count {
                    let line = rows.lowerBound - position + row
                    (bytes.baseAddress! + line * frame.bytesPerRow + 100 * 4)
                        .copyMemory(from: source.baseAddress! + row * picture.bytesPerRow + 100 * 4, byteCount: 600 * 4)
                }
            }
        }
        frame = StitchFrame(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, pixels: pixels,
                            colorSpace: frame.colorSpace)
        return frame
    }

    @Test func scrollingBackPastABlockThatChangedRecovers() throws {
        var stitcher = stitcher()
        // The block (page rows 1 750–2 099) is the bottom 350 lines of the frame at 1 100 when that frame is stitched;
        // then it changes.
        #expect(stitcher.add(withBlock(at: 1000, loaded: false)).accepted)
        #expect(stitcher.add(withBlock(at: 1100, loaded: false)).accepted)
        let stuck = [1200, 1300].map { stitcher.add(withBlock(at: $0, loaded: true)) }
        #expect(stuck.allSatisfy { $0.noMatch && $0.warnings == [.slowDown] })
        // Back up past the block, then down again: the stitch follows from there, adding nothing until it passes what
        // was stitched, and the warning clears.
        let back = [700, 850, 1000, 1150].map { stitcher.add(withBlock(at: $0, loaded: true)) }
        #expect(back.dropLast().allSatisfy { !$0.accepted && !$0.noMatch })
        let resumed = try #require(back.last)
        #expect(resumed.accepted && resumed.offset == 50 && resumed.warnings.isEmpty)
        #expect(stitcher.add(withBlock(at: 1300, loaded: true)).offset == 150)
        // Every page row once, from 1 000 to 2 299: the block as it was when its lines were stitched.
        let composed = stitcher.compose()
        let image = try #require(composed)
        #expect(image.height == 1300)
        var expected: [UInt8] = []
        for start in stride(from: 1000, to: 2300, by: 100) {
            let rows = withBlock(at: start, loaded: false)
            expected += rows.pixels[0..<(100 * rows.bytesPerRow)]
        }
        let difference = firstDifferentRow(tightBytes(of: image), expected, rowBytes: 3200)
        #expect(difference == nil, "first differing row: \(difference ?? -1)")
    }

    // MARK: D: too fast

    @Test func visionIsNotAskedWhileTheMovementKeepsItsPace() {
        let counter = CountingEstimator()
        var stitcher = stitcher(estimator: counter)
        // A steady scroll, then one that speeds up by a third and slows down again, all near the previous movement.
        for position in [0, 150, 300, 450, 650, 820, 960] { _ = stitcher.add(page.frame(at: position, length: 1000)) }
        #expect(counter.count == 1, "asked \(counter.count) times")
        // Twice as far as the movement before: outside its neighbourhood, so Vision is asked.
        #expect(stitcher.add(page.frame(at: 1400, length: 1000)).offset == 440)
        #expect(counter.count == 2)
    }

    @Test func theSlowDownWarningSaysToScrollBack() {
        // Slowing down alone never brings the stitch back; going back to where it can follow does.
        #expect(StitchWarning.slowDownText == "Please slow down…")
        #expect(StitchWarning.slowDownHint(along: .vertical) == "Scroll back up a little to continue")
        #expect(StitchWarning.slowDownHint(along: nil) == "Scroll back up a little to continue")
        #expect(StitchWarning.slowDownHint(along: .horizontal) == "Scroll back left a little to continue")
    }

    /// The columns `range` of a BGRA bitmap `width` pixels wide with tight rows.
    private func columns(_ range: Range<Int>, of bytes: [UInt8], width: Int) -> [UInt8] {
        let rows = bytes.count / (width * 4)
        var columns: [UInt8] = []
        columns.reserveCapacity(rows * range.count * 4)
        for row in 0..<rows {
            columns += bytes[(row * width + range.lowerBound) * 4..<(row * width + range.upperBound) * 4]
        }
        return columns
    }
}

/// Counts how often it is asked; never proposes anything.
final class CountingEstimator: OffsetEstimator, @unchecked Sendable {
    private let asked = Mutex(0)

    var count: Int { asked.withLock { $0 } }

    func estimate(from previous: StitchFrame, to current: StitchFrame, band: Range<Int>, axis: ScrollAxis) -> Int? {
        asked.withLock { $0 += 1 }
        return nil
    }
}
