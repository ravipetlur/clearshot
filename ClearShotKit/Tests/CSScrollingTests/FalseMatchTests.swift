import CoreGraphics
import Testing
@testable import CSScrolling

/// Matching by pieces must never accept a movement the page didn't make: a frame where only a sidebar scrolled, a
/// periodic alias near the previous offset, columns set aside to let an alias through, an element that appears
/// mid-capture stitched into the page. Each would add duplicated or missing rows with no warning.
struct FalseMatchTests {
    let page = SyntheticPage.plain
    let configuration = StitchConfiguration(pixelsPerPoint: 2)

    private func stitcher(estimator: any OffsetEstimator = NoOffsetEstimate()) -> Stitcher {
        Stitcher(configuration: configuration, estimator: estimator)
    }

    /// The page at `position` with a sidebar `width` px wide on its left showing its own rows from `sidebar`.
    private func frame(page position: Int, sidebar: Int, width: Int) -> StitchFrame {
        let side = SyntheticPage(width: width, length: 4000, seed: 99)
        return page.frame(at: position, length: 1000).replacingColumns(with: side.frame(at: sidebar, length: 1000))
    }

    /// The round button 88 px across, 48 px in from the bottom right.
    private func withButton(_ frame: StitchFrame) -> StitchFrame {
        frame.paintingDisc(centerX: frame.width - 48 - 44, centerY: frame.height - 48 - 44, radius: 44, color: 0xFF22_88EE)
    }

    /// Whether the composed `image` is the page's columns `columns` from its first row, every row once.
    private func expectPageColumns(_ image: CGImage?, height: Int, columns: Range<Int>,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        guard let image else {
            Issue.record("nothing composed", sourceLocation: sourceLocation)
            return
        }
        #expect(image.height == height, sourceLocation: sourceLocation)
        let composed = Self.columns(columns, of: tightBytes(of: image), width: 800)
        let expected = Self.columns(columns, of: page.expected(to: image.height - 1000, length: 1000), width: 800)
        let difference = firstDifferentRow(composed, expected, rowBytes: columns.count * 4)
        #expect(difference == nil, "first differing row: \(difference ?? -1)", sourceLocation: sourceLocation)
    }

    // MARK: Critical 1: a still page whose sidebar scrolls

    @Test(arguments: [120, 200, 400])
    func aStillPageWithAScrollingSidebarAddsNothing(width: Int) {
        var stitcher = stitcher()
        _ = stitcher.add(frame(page: 0, sidebar: 0, width: width))
        let update = stitcher.add(frame(page: 0, sidebar: 150, width: width))
        #expect(!update.accepted && update.offset == 0, "\(update.trace?.description ?? "")")
        #expect(stitcher.compose()?.height == 1000)
    }

    @Test(arguments: [120, 200, 400])
    func aSidebarScrolledOnItsOwnMidCaptureAddsNothing(width: Int) {
        // The page scrolls 120 three times with the sidebar stuck, then only the sidebar scrolls (130), then the page
        // scrolls twice more.
        let frames = [(0, 0), (120, 0), (240, 0), (360, 0), (360, 130), (480, 130), (600, 130)]
        var stitcher = stitcher()
        let updates = frames.map { stitcher.add(frame(page: $0.0, sidebar: $0.1, width: width)) }
        #expect(!updates[4].accepted && updates[4].offset == 0, "\(updates[4].trace?.description ?? "")")
        // A sidebar scrolled on its own is not the page and not a small change in place: the warning shows (it isn't
        // followed as still).
        #expect(updates[4].warnings == [.slowDown])
        let image = stitcher.compose()
        if width < 400 {
            // Once it is where it scrolled to, the sidebar has stayed put since the frame before and is left out: the
            // page is measured again from the last stitched frame.
            #expect(updates.map(\.accepted) == [true, true, true, true, false, true, true])
            #expect(updates.map(\.offset) == [0, 120, 120, 120, 0, 120, 120])
            expectPageColumns(image, height: 1600, columns: width..<800)
        } else {
            // Half the frame moving beside half that stays put could be either: warned throughout, and what is composed
            // is the page, every row once.
            #expect(updates.dropFirst().allSatisfy { !$0.accepted && $0.warnings == [.slowDown] })
            expectPageColumns(image, height: image?.height ?? 0, columns: width..<800)
        }
    }

    // MARK: A near alias must not skip the estimate

    @Test func periodicLinesAskTheEstimateWhenThePreviousOffsetIsAnAlias() {
        // Rows repeating every 50; the truth is 120, Vision says 120, the previous movement was 170 (an alias).
        let period = (0..<50).map { SyntheticPage.mix(UInt64($0)) }
        let lines = { (range: Range<Int>) in
            LineHashes(hashes: range.map { period[$0 % 50] }, blank: Array(repeating: false, count: range.count))
        }
        var asked = 0
        let comparison = OffsetMatcher(configuration: configuration)
            .compare(lines(0..<1000), lines(120..<1120), previousOffset: 170) { _ in
                asked += 1
                return 120
            }
        #expect(comparison.movement == .moved(120) && asked == 1)
    }

    @Test func labelledListItemsSlowingDownAreNotDuplicated() throws {
        // List items 80 rows apart, each with a unique label and the same furniture, under a floating button; the
        // scroll slows from 120 to 40, where 40 + 80 is an alias near the previous movement.
        let positions = [0, 120, 240, 360, 480, 520, 560]
        let frames = positions.map { withButton(ListPage.frame(at: $0, length: 1000)) }
        var stitcher = stitcher(estimator: KnownPositions(Array(zip(positions, frames))))
        let updates = frames.map { stitcher.add($0) }
        #expect(updates.map(\.offset) == [0, 120, 120, 120, 120, 40, 40])
        let composed = stitcher.compose()
        let image = try #require(composed)
        let expected = withButton(ListPage.frame(at: 0, length: 1560))
        #expect(image.height == 1560)
        let difference = firstDifferentRow(tightBytes(of: image), expected.pixels, rowBytes: 3200)
        #expect(difference == nil, "first differing row: \(difference ?? -1)")
    }

    // MARK: An element that appears mid-capture

    @Test func aButtonThatAppearsMidCaptureIsDrawnOnceAtTheEnd() throws {
        let positions = PageContentTests.slowPositions
        var stitcher = stitcher()
        for (index, position) in positions.enumerated() {
            let frame = page.frame(at: position, length: 1000)
            _ = stitcher.add(index >= 5 ? withButton(frame) : frame)
        }
        let composed = stitcher.compose()
        let image = try #require(composed)
        let height = 1000 + positions.last!
        let expected = withButton(StitchFrame(width: 800, height: height, bytesPerRow: 3200,
                                              pixels: page.expected(to: positions.last!, length: 1000),
                                              colorSpace: page.colorSpace))
        #expect(image.height == height)
        let difference = firstDifferentRow(tightBytes(of: image), expected.pixels, rowBytes: 3200)
        #expect(difference == nil, "first differing row: \(difference ?? -1)")
    }

    // MARK: Minors

    @Test func theWarningClearsOnceTheStitchFollowsAgain() {
        // Too far, then back behind the last stitched frame: the stitch follows again, so the hint has been heeded.
        var stitcher = stitcher()
        _ = stitcher.add(page.frame(at: 0, length: 1000))
        _ = stitcher.add(page.frame(at: 300, length: 1000))
        #expect(stitcher.add(page.frame(at: 1300, length: 1000)).warnings == [.slowDown])
        let back = stitcher.add(page.frame(at: 250, length: 1000))
        #expect(!back.accepted && !back.noMatch && back.warnings.isEmpty)
        #expect(stitcher.add(page.frame(at: 450, length: 1000)).offset == 150)
    }

    @Test func horizontalPieceKeysAreTheTurnedFramesRowPieceKeys() {
        let vertical = LineHashes(page.frame(at: 300, length: 1000), axis: .vertical, margin: 32)
        let horizontal = LineHashes(page.frame(at: 300, length: 1000, axis: .horizontal), axis: .horizontal, margin: 32)
        #expect(vertical.hashes == horizontal.hashes && vertical.blank == horizontal.blank)
        #expect(vertical.pieceCount == horizontal.pieceCount && vertical.pieceKeys == horizontal.pieceKeys)
    }

    @Test func aHorizontalCaptureWithAFloatingButtonIsRebuiltExactly() throws {
        // The button 48 px in from the bottom right of each turned frame: by its end along the axis.
        func withButtonAcross(_ frame: StitchFrame) -> StitchFrame {
            frame.paintingDisc(centerX: frame.width - 48 - 44, centerY: frame.height - 48 - 44, radius: 44,
                               color: 0xFF22_88EE)
        }
        let positions = [0, 90, 200, 330, 420, 560]
        var stitcher = stitcher()
        let updates = positions.map { stitcher.add(withButtonAcross(page.frame(at: $0, length: 1000, axis: .horizontal))) }
        #expect(updates.allSatisfy { $0.accepted })
        let composed = stitcher.compose()
        let image = try #require(composed)
        let width = 1000 + positions.last!
        let expected = withButtonAcross(StitchFrame(width: width, height: 800, bytesPerRow: width * 4,
                                                    pixels: page.expected(to: positions.last!, length: 1000, axis: .horizontal),
                                                    colorSpace: page.colorSpace))
        #expect(image.width == width && image.height == 800)
        let difference = firstDifferentRow(tightBytes(of: image), expected.pixels, rowBytes: width * 4)
        #expect(difference == nil, "first differing row: \(difference ?? -1)")
    }

    /// The columns `range` of a BGRA bitmap `width` pixels wide with tight rows.
    static func columns(_ range: Range<Int>, of bytes: [UInt8], width: Int) -> [UInt8] {
        let rows = bytes.count / (width * 4)
        var columns: [UInt8] = []
        columns.reserveCapacity(rows * range.count * 4)
        for row in 0..<rows {
            columns += bytes[(row * width + range.lowerBound) * 4..<(row * width + range.upperBound) * 4]
        }
        return columns
    }
}

/// A list 800 px wide: an item every 80 rows (60 rows of item, 20 of paper), each with a label of its own in x 40–169
/// (5-px cells) and the same furniture in x 180–767 (7-px cells, one pattern per row of an item).
enum ListPage {
    static let paper: UInt32 = 0xFFFF_FFFF

    /// Items `item` rows apart, `filled` rows of each drawn; labels in `label`, furniture in `furniture`.
    static func frame(at position: Int, length: Int, item itemRows: Int = 80, filled: Int = 60,
                      label: Range<Int> = 40..<170, furniture: Range<Int> = 180..<768) -> StitchFrame {
        var words = [UInt32](repeating: paper, count: 800 * length)
        for line in 0..<length {
            let row = position + line
            let item = row / itemRows
            let inItem = row % itemRows
            guard inItem < filled else { continue }
            for x in label {
                words[line * 800 + x] = color(SyntheticPage.mix(UInt64(item) &* 1_000_003 &+ UInt64(inItem * 100 + x / 5)))
            }
            for x in furniture {
                words[line * 800 + x] = color(SyntheticPage.mix(0xF00D &+ UInt64(inItem * 1000 + x / 7)))
            }
        }
        return StitchFrame(width: 800, height: length, bytesPerRow: 3200, pixels: SyntheticPage.bytes(words),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    private static func color(_ hash: UInt64) -> UInt32 {
        0xFF00_0000 | UInt32(truncatingIfNeeded: hash) & 0x00FF_FFFF
    }
}

/// Knows where each frame of a test is, and proposes the true movement between two of them.
final class KnownPositions: OffsetEstimator, @unchecked Sendable {
    private let frames: [(position: Int, frame: StitchFrame)]

    init(_ frames: [(Int, StitchFrame)]) {
        self.frames = frames.map { (position: $0.0, frame: $0.1) }
    }

    func estimate(from previous: StitchFrame, to current: StitchFrame, band: Range<Int>, axis: ScrollAxis) -> Int? {
        guard let from = position(of: previous), let to = position(of: current) else { return nil }
        return to - from
    }

    private func position(of frame: StitchFrame) -> Int? {
        frames.first { $0.frame.pixels.prefix(64 * 1024).elementsEqual(frame.pixels.prefix(64 * 1024)) }?.position
    }
}
