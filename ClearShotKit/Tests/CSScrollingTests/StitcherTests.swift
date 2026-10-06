import CoreGraphics
import Testing
@testable import CSScrolling

struct StitcherTests {
    /// Irregular scroll steps, in pixels, from a measured registration experiment.
    static let steps = [137, 211, 401, 64, 333, 590, 12, 250, 700, 820]
    /// Frames for the sticky page: 1 200 lines, so that even the 820 step is within 90% of the band left between the
    /// 80-line header and the 60-line footer (0.9 × 1 060 = 954).
    static let stickyFrameLength = 1200

    let configuration = StitchConfiguration(pixelsPerPoint: 2)

    private func stitcher(_ configuration: StitchConfiguration? = nil,
                          estimator: any OffsetEstimator = NoOffsetEstimate()) -> Stitcher {
        Stitcher(configuration: configuration ?? self.configuration, estimator: estimator)
    }

    /// Feeds frames at `positions` (body rows scrolled) and returns the updates.
    private func add(_ positions: [Int], of page: SyntheticPage, length: Int, axis: ScrollAxis = .vertical,
                     to stitcher: inout Stitcher) -> [StitchUpdate] {
        positions.map { stitcher.add(page.frame(at: $0, length: length, axis: axis)) }
    }

    /// Checks that `image` is exactly `expected` (tight BGRA laid out like the frames), `width` × `height` px, in the
    /// frames' layout and colour space.
    private func expectImage(_ image: CGImage?, equals expected: [UInt8], width: Int, height: Int, page: SyntheticPage,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        guard let image else {
            Issue.record("nothing was composed", sourceLocation: sourceLocation)
            return
        }
        #expect(image.width == width && image.height == height, sourceLocation: sourceLocation)
        #expect(image.bitmapInfo.contains(.byteOrder32Little), sourceLocation: sourceLocation)
        #expect(image.alphaInfo == .premultipliedFirst, sourceLocation: sourceLocation)
        #expect(image.colorSpace == page.colorSpace, sourceLocation: sourceLocation)
        let difference = firstDifferentRow(tightBytes(of: image), expected, rowBytes: image.width * 4)
        #expect(difference == nil, "first differing row: \(difference ?? -1)", sourceLocation: sourceLocation)
    }

    /// The colour a pixel of `image` comes out as when drawn in RGBA, so a byte-order mix-up would show.
    private func rgb(of image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: image.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2])
    }

    @Test func aPageWithStickyHeaderAndFooterIsRebuiltExactly() {
        let page = SyntheticPage.sticky
        let length = Self.stickyFrameLength
        var stitcher = stitcher()
        let positions = Self.steps.reduce(into: [0]) { $0.append($0.last! + $1) }
        let updates = add(positions, of: page, length: length, to: &stitcher)

        #expect(updates.map(\.accepted) == Array(repeating: true, count: 11))
        #expect(updates.map(\.offset) == [0] + Self.steps)
        #expect(updates.last?.axis == .vertical)
        #expect(updates.allSatisfy { $0.warnings.isEmpty && !$0.reachedLimit })
        #expect(updates.last?.outputSize == CGSize(width: 800, height: length + 3518))
        #expect(stitcher.acceptedFrames == 11)
        #expect(stitcher.stickyBands == StickyBands(leading: 80, trailing: 60))

        let image = stitcher.compose()
        expectImage(image, equals: page.expected(to: positions.last!, length: length), width: 800, height: length + 3518,
                    page: page)
        // The header's blue reads as blue, not swapped into orange.
        if let image {
            let (red, green, blue) = rgb(of: image, x: 2, y: 2)
            #expect(red == 0x28 && green == 0x64 && blue == 0xC8)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func theRealVisionEstimatorStillRebuildsThePageExactly() {
        let page = SyntheticPage.sticky
        let length = Self.stickyFrameLength
        var stitcher = stitcher(estimator: VisionOffsetEstimator())
        let positions = Self.steps.reduce(into: [0]) { $0.append($0.last! + $1) }
        let updates = add(positions, of: page, length: length, to: &stitcher)

        #expect(updates.map(\.offset) == [0] + Self.steps)
        expectImage(stitcher.compose(), equals: page.expected(to: positions.last!, length: length), width: 800,
                    height: length + 3518, page: page)
    }

    @Test func aHorizontalPageIsRebuiltExactly() {
        let page = SyntheticPage.sticky
        let length = Self.stickyFrameLength
        var stitcher = stitcher()
        let steps = [300, 45, 512, 700, 128]
        let positions = steps.reduce(into: [0]) { $0.append($0.last! + $1) }
        let updates = add(positions, of: page, length: length, axis: .horizontal, to: &stitcher)

        #expect(updates.map(\.offset) == [0] + steps)
        #expect(updates.map(\.axis) == [nil] + Array(repeating: .horizontal, count: steps.count))
        #expect(updates.last?.outputSize == CGSize(width: length + 1685, height: 800))
        #expect(stitcher.stickyBands == StickyBands(leading: 80, trailing: 60))
        expectImage(stitcher.compose(), equals: page.expected(to: positions.last!, length: length, axis: .horizontal),
                    width: length + 1685, height: 800, page: page)
    }

    @Test func theFirstMovementLocksTheAxis() {
        let page = SyntheticPage.plain
        var stitcher = stitcher()
        let first = stitcher.add(page.frame(at: 0, length: 1000, across: 0..<700))
        #expect(first.accepted && first.axis == nil)
        let down = stitcher.add(page.frame(at: 200, length: 1000, across: 0..<700))
        #expect(down.accepted && down.offset == 200 && down.axis == .vertical)
        // The same view moved 40 px sideways: on the locked axis that is no match.
        let sideways = stitcher.add(page.frame(at: 200, length: 1000, across: 40..<740))
        #expect(!sideways.accepted && sideways.axis == .vertical)
        #expect(sideways.warnings == [.slowDown] && sideways.noMatch)
        let further = stitcher.add(page.frame(at: 600, length: 1000, across: 0..<700))
        #expect(further.accepted && further.offset == 400 && further.warnings.isEmpty)
    }

    @Test func aTooFastScrollWarnsAndRecoversWhenTheOverlapReturns() {
        let page = SyntheticPage.plain
        var stitcher = stitcher()
        let updates = add([0, 300, 1250, 1250, 300, 900], of: page, length: 1000, to: &stitcher)

        #expect(updates.map(\.accepted) == [true, true, false, false, false, true])
        // 950 past the last accepted frame leaves 50 lines of overlap: too little to trust.
        #expect(updates[2].warnings == [.slowDown])
        #expect(updates.map(\.noMatch) == [false, false, true, true, false, false])
        // The warning stays until a frame is accepted again, even over a frame that matched (back where it was, still);
        // `noMatch` says what this frame did.
        #expect(updates[3].warnings == [.slowDown])
        #expect(updates[4].warnings == [.slowDown])
        // 600 past, with 400 lines of overlap.
        #expect(updates[5].offset == 600 && updates[5].warnings.isEmpty)
        expectImage(stitcher.compose(), equals: page.expected(to: 900, length: 1000), width: 800, height: 1900, page: page)
    }

    @Test func aStickyPageScrolledTooFastRecoversWithItsBandsOnce() {
        // 300, then 1 100 past it, more than the 1 060 body lines between the header and footer (no overlap at all),
        // then back to 700 past the last accepted frame, and on.
        let page = SyntheticPage.sticky
        let length = Self.stickyFrameLength
        var stitcher = stitcher()
        let updates = add([0, 300, 1400, 1000, 1600], of: page, length: length, to: &stitcher)

        #expect(updates.map(\.accepted) == [true, true, false, true, true])
        #expect(updates.map(\.noMatch) == [false, false, true, false, false])
        #expect(updates[2].warnings == [.slowDown])
        // The overlap is back: the warning clears and the move is measured from the last accepted frame.
        #expect(updates[3].warnings.isEmpty && updates[3].offset == 700)
        #expect(updates[4].warnings.isEmpty && updates[4].offset == 600)
        #expect(stitcher.stickyBands == StickyBands(leading: 80, trailing: 60))

        let image = stitcher.compose()
        // The header and footer once each, at the ends, and every body row once, none missing. A row's first pixel says
        // which band it is in.
        expectImage(image, equals: page.expected(to: 1600, length: length), width: 800, height: length + 1600, page: page)
        if let image {
            let rows = tightBytes(of: image).withUnsafeBytes { bytes in
                (0..<image.height).map { bytes.loadUnaligned(fromByteOffset: $0 * image.width * 4, as: UInt32.self) }
            }
            #expect(rows.indices.filter { rows[$0] == SyntheticPage.headerColor } == Array(0..<80))
            #expect(rows.indices.filter { rows[$0] == SyntheticPage.footerColor } == Array((image.height - 60)..<image.height))
        }
    }

    @Test func scrollingUpAtTheStartIsIgnored() {
        let page = SyntheticPage.plain
        var stitcher = stitcher()
        let updates = add([500, 300, 200, 700], of: page, length: 1000, to: &stitcher)

        #expect(updates.map(\.accepted) == [true, false, false, true])
        #expect(updates.allSatisfy { $0.warnings.isEmpty })
        #expect(updates.map(\.offset) == [0, 0, 0, 200])
        expectImage(stitcher.compose(), equals: page.expected(from: 500, to: 700, length: 1000), width: 800, height: 1200,
                    page: page)
    }

    @Test func scrollingBackMidCaptureAddsNothing() {
        let page = SyntheticPage.plain
        var stitcher = stitcher()
        let updates = add([0, 300, 150, 250, 500], of: page, length: 1000, to: &stitcher)

        #expect(updates.map(\.accepted) == [true, true, false, false, true])
        #expect(updates.allSatisfy { $0.warnings.isEmpty })
        #expect(updates.map(\.offset) == [0, 300, 0, 0, 200])
        #expect(updates[3].outputSize == CGSize(width: 800, height: 1300))
        expectImage(stitcher.compose(), equals: page.expected(to: 500, length: 1000), width: 800, height: 1500, page: page)
    }

    @Test func identicalFramesAddNothing() {
        let page = SyntheticPage.plain
        var stitcher = stitcher()
        let updates = add([0, 0, 250, 250, 250], of: page, length: 1000, to: &stitcher)

        #expect(updates.map(\.accepted) == [true, false, true, false, false])
        #expect(updates.allSatisfy { $0.warnings.isEmpty })
        #expect(stitcher.acceptedFrames == 2)
        expectImage(stitcher.compose(), equals: page.expected(to: 250, length: 1000), width: 800, height: 1250, page: page)
    }

    @Test func anAnimationInsideTheRegionIsNotAMove() {
        let page = SyntheticPage.plain
        var stitcher = stitcher()
        let still = page.frame(at: 0, length: 1000)
        let square = CGRect(x: 400, y: 500, width: 40, height: 40)
        #expect(stitcher.add(still).accepted)
        for frame in [still.painting(square, color: 0xFFFF_0000), still, still.painting(square, color: 0xFF00_FF00)] {
            let update = stitcher.add(frame)
            #expect(!update.accepted && update.warnings.isEmpty && update.axis == nil)
        }
        #expect(stitcher.add(page.frame(at: 300, length: 1000)).offset == 300)
        expectImage(stitcher.compose(), equals: page.expected(to: 300, length: 1000), width: 800, height: 1300, page: page)

        // Just under the line: a scroll between a 400-line header and a 390-line footer (79% of the frame unchanged in
        // place) is a move, and nothing of it is lost.
        let banded = SyntheticPage(length: 2000, header: 400, footer: 390)
        var between = self.stitcher()
        let updates = add([9, 109], of: banded, length: 1000, to: &between)
        #expect(updates.map(\.offset) == [0, 100])
        #expect(between.stickyBands == StickyBands(leading: 400, trailing: 390))
        expectImage(between.compose(), equals: banded.expected(from: 9, to: 109, length: 1000), width: 800, height: 1100,
                    page: banded)
    }

    @Test func aWideAnimatedStripWarnsNeitherBeforeNorAfterTheLock() {
        // A 600 × 60 strip (a progress bar, a carousel) is an animation on the vertical axis, but it changes three
        // quarters of the columns, so the horizontal pass finds no match; the animation still explains the frame.
        let page = SyntheticPage.plain
        var stitcher = stitcher()
        let strip = CGRect(x: 100, y: 470, width: 600, height: 60)
        let colours: [UInt32] = [0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF]
        let still = page.frame(at: 0, length: 1000)
        #expect(stitcher.add(still).accepted)
        for colour in colours {
            let update = stitcher.add(still.painting(strip, color: colour))
            #expect(!update.accepted && !update.noMatch && update.warnings.isEmpty && update.axis == nil)
        }
        let moved = page.frame(at: 300, length: 1000)
        #expect(stitcher.add(moved).offset == 300)
        for colour in colours {
            let update = stitcher.add(moved.painting(strip, color: colour))
            #expect(!update.accepted && !update.noMatch && update.warnings.isEmpty && update.axis == .vertical)
        }
    }

    @Test func theFooterEstimateShrinksWithoutLosingRows() {
        // A 60-row footer; body rows 860–1010 are blank, so the last 100 body rows of the frames at 20 and 70 are blank
        // in both, and the row above them is text in the first (body row 859) and blank in the second.
        let page = SyntheticPage(length: 4000, footer: 60, blank: 860..<1010)
        var stitcher = stitcher()
        let updates = add([20, 70], of: page, length: 1000, to: &stitcher)
        #expect(updates.map(\.offset) == [0, 50])
        #expect(stitcher.stickyBands?.trailing == 160)
        let later = add([420, 720], of: page, length: 1000, to: &stitcher)
        #expect(later.map(\.offset) == [350, 300])
        #expect(stitcher.stickyBands?.trailing == 60)
        expectImage(stitcher.compose(), equals: page.expected(from: 20, to: 720, length: 1000), width: 800, height: 1700,
                    page: page)
    }

    @Test func theOutputStopsAtTheCapInOutputPixels() {
        let page = SyntheticPage.narrow
        var stitcher = stitcher(StitchConfiguration(pixelsPerPoint: 2, outputScale: 0.5))
        var updates: [StitchUpdate] = []
        var position = 0
        repeat {
            updates.append(stitcher.add(page.frame(at: position, length: 2000)))
            position += 1500
        } while !(updates.last?.reachedLimit ?? true) && updates.count < 30

        // 2 000 + 20 × 1 500 = 32 000 source px; the 21st step is cut to the 766 that reach 32 766 (16 383 output px).
        #expect(updates.count == 22)
        #expect(updates.dropLast().allSatisfy { $0.accepted && !$0.reachedLimit })
        #expect(updates.last?.accepted == true && updates.last?.offset == 1500)
        #expect(updates.last?.outputSize == CGSize(width: 80, height: 16_383))
        // Later frames are ignored.
        let after = stitcher.add(page.frame(at: position, length: 2000))
        #expect(!after.accepted && after.reachedLimit && after.outputSize.height == 16_383)
        expectImage(stitcher.compose(), equals: page.expected(to: 30_766, length: 2000), width: 160, height: 32_766, page: page)
    }

    @Test func veryLargeAppearsFromEightyFivePercent() {
        let page = SyntheticPage.narrow
        // 85% of 16 383 is 13 925.55: 13 926 output px is very large, 13 900 isn't.
        for (lastStep, isVeryLarge) in [(926, true), (900, false)] {
            var stitcher = stitcher()
            let positions = (0...11).map { $0 * 1000 } + [11_000 + lastStep]
            let updates = add(positions, of: page, length: 2000, to: &stitcher)
            #expect(updates.last?.outputSize.height == CGFloat(13_000 + lastStep))
            #expect(updates.dropLast().allSatisfy { $0.warnings.isEmpty })
            #expect(updates.last?.warnings == (isVeryLarge ? [.veryLarge] : []))
        }
    }

    @Test func composingEmptiesTheStripStore() {
        let page = SyntheticPage.plain
        var stitcher = stitcher()
        _ = add([0, 400, 800], of: page, length: 1000, to: &stitcher)
        #expect(!stitcher.stripStore.isEmpty)
        #expect(stitcher.compose() != nil)
        #expect(stitcher.stripStore.isEmpty)
        #expect(stitcher.compose() == nil)
        var unused = Stitcher(configuration: configuration)
        #expect(unused.compose() == nil)
    }

    @Test func aFixedAxisSkipsDetection() {
        let page = SyntheticPage.plain
        var stitcher = stitcher(StitchConfiguration(pixelsPerPoint: 2, axis: .horizontal))
        let updates = add([0, 200], of: page, length: 1000, to: &stitcher)
        #expect(updates.map(\.axis) == [.horizontal, .horizontal])
        #expect(updates[1].accepted == false && updates[1].noMatch)
        #expect(updates[1].warnings == [.slowDown])
    }
}
