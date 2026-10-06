import CoreGraphics
import Synchronization
import Testing
@testable import CSScrolling

/// The stitcher only moves its position on an unambiguous answer: every offset in the range that verifies, by whole
/// lines or by pieces, is weighed; several are told apart only by the pieces that tell them apart, or by Vision's
/// estimate; a still verdict by pieces, or a scroll back that only the estimate picked, never moves the reference.
struct UnambiguousTests {
    static let paper: UInt32 = 0xFFFF_FFFF

    /// A page `width` × `length` from a function giving each row's pixels (BGRA words), rows from the top.
    static func page(width: Int = 800, length: Int, row: (Int, inout [UInt32]) -> Void) -> StitchFrame {
        var words = [UInt32](repeating: paper, count: width * length)
        var line = [UInt32](repeating: paper, count: width)
        for y in 0..<length {
            for x in 0..<width { line[x] = paper }
            row(y, &line)
            words.replaceSubrange((y * width)..<((y + 1) * width), with: line)
        }
        return StitchFrame(width: width, height: length, bytesPerRow: width * 4, pixels: SyntheticPage.bytes(words),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// A pattern word for `seed`, never paper.
    static func ink(_ seed: UInt64) -> UInt32 {
        0xFF00_0000 | UInt32(truncatingIfNeeded: SyntheticPage.mix(seed)) & 0x00FF_FFFF
    }

    /// `frame` with `rows` replaced by the same rows of `source` (as wide, as tall), at the same place.
    static func overlay(_ frame: StitchFrame, with source: StitchFrame, columns: Range<Int>, rows: Range<Int>) -> StitchFrame {
        var pixels = frame.pixels
        pixels.withUnsafeMutableBytes { bytes in
            source.pixels.withUnsafeBytes { from in
                for y in rows {
                    (bytes.baseAddress! + y * frame.bytesPerRow + columns.lowerBound * 4)
                        .copyMemory(from: from.baseAddress! + y * source.bytesPerRow + columns.lowerBound * 4,
                                    byteCount: columns.count * 4)
                }
            }
        }
        return StitchFrame(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, pixels: pixels,
                           colorSpace: frame.colorSpace)
    }

    /// Stitches `frames`; with `positions` and `estimates` given, Vision's estimate is the true movement (or the
    /// override for a frame's index).
    static func stitch(_ frames: [StitchFrame], positions: [Int]? = nil, overrides: [Int: Int] = [:],
                       axis: ScrollAxis? = nil) -> (updates: [StitchUpdate], image: CGImage?) {
        let estimator: any OffsetEstimator = positions.map { KnownFrames(frames, positions: $0, overrides: overrides) }
            ?? NoOffsetEstimate()
        var stitcher = Stitcher(configuration: StitchConfiguration(pixelsPerPoint: 2, axis: axis), estimator: estimator)
        let updates = frames.map { stitcher.add($0) }
        return (updates, stitcher.compose())
    }

    /// Whether `image` is exactly `expected`'s first `height` rows in `columns` (all of it when `height` is nil).
    static func expectRows(_ image: CGImage?, of expected: StitchFrame, columns: Range<Int>? = nil, height: Int? = nil,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        guard let image else {
            Issue.record("nothing composed", sourceLocation: sourceLocation)
            return
        }
        let height = height ?? expected.height
        #expect(image.height == height, sourceLocation: sourceLocation)
        guard image.height <= expected.height else { return }
        let columns = columns ?? 0..<expected.width
        let composed = FalseMatchTests.columns(columns, of: tightBytes(of: image), width: image.width)
        let truth = FalseMatchTests.columns(columns, of: Array(expected.pixels[0..<(image.height * expected.bytesPerRow)]),
                                            width: expected.width)
        let difference = firstDifferentRow(composed, truth, rowBytes: columns.count * 4)
        #expect(difference == nil, "first differing row: \(difference ?? -1)", sourceLocation: sourceLocation)
    }

    /// Every frame is accepted with its true step since the last accepted one, or, once the axis is known, warned or
    /// explained as still (an animation, or standing still: the reference stays, so nothing drifts).
    static func expectExactOrWarned(_ updates: [StitchUpdate], positions: [Int],
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        var last = positions[0]
        for (update, position) in zip(updates.dropFirst(), positions.dropFirst()) {
            if update.accepted {
                #expect(update.offset == position - last, sourceLocation: sourceLocation)
                last = position
            } else if update.axis != nil {
                let still = update.trace.map { trace in
                    trace.outcome == nil && trace.comparisons.contains { [.animation, .moved(0)].contains($0.movement) }
                } ?? false
                #expect(update.warnings.contains(.slowDown) || position == last || still,
                        "not stitched and no warning: \(update.trace?.description ?? "")", sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: Still by pieces never moves the reference

    @Test(arguments: [(240, 600), (160, 800), (200, 800)])
    func aDenseSidebarBesideASparsePageIsExactOrWarned(sidebar width: Int, blockEvery: Int) {
        // A sidebar with something on every line beside a page that is blank but for a 60-row block every `blockEvery`
        // rows until row 2400, dense text after; steps of 60, no estimate.
        let text = SyntheticPage(width: 800, length: 5000, seed: 3).frame(at: 0, length: 5000)
        let page = Self.page(length: 5000) { y, line in
            guard y >= 2400 || y % blockEvery < 60 else { return }
            text.pixels.withUnsafeBytes { bytes in
                for x in 0..<800 { line[x] = bytes.loadUnaligned(fromByteOffset: y * 3200 + x * 4, as: UInt32.self) }
            }
        }
        let sidebar = Self.page(width: 800, length: 1000) { y, line in
            for x in 0..<width { line[x] = Self.ink(UInt64(y * 1000 + x / 4)) }
        }
        let positions = Array(stride(from: 0, through: 3000, by: 60))
        let frames = positions.map { position in
            Self.overlay(page.lines(position..<(position + 1000), along: .vertical), with: sidebar, columns: 0..<width,
                         rows: 0..<1000)
        }
        let (updates, image) = Self.stitch(frames, axis: .vertical)
        Self.expectExactOrWarned(updates, positions: positions)
        Self.expectRows(image, of: page, columns: width..<800, height: image?.height)
    }

    // MARK: A scroll back that only a misled estimate picks is not followed

    @Test func aMisreadScrollBackOnRepeatingLinesIsNotFollowed() {
        // Lines repeating every 850 rows; steps of 170 with the true estimate, but frame 6 read as −680 (170 − 850),
        // which the lines verify as well as the truth.
        let text = SyntheticPage.plain.frame(at: 0, length: 850)
        let page = Self.page(length: 4100) { y, line in
            text.pixels.withUnsafeBytes { bytes in
                for x in 0..<800 { line[x] = bytes.loadUnaligned(fromByteOffset: (y % 850) * 3200 + x * 4, as: UInt32.self) }
            }
        }
        let positions = Array(stride(from: 0, through: 3060, by: 170))
        let frames = positions.map { page.lines($0..<($0 + 1000), along: .vertical) }
        let (_, image) = Self.stitch(frames, positions: positions, overrides: [6: -680])
        Self.expectRows(image, of: page, height: 4060)
    }

    // MARK: Several offsets verify: the pieces that tell them apart, or the estimate

    /// Identical 60-row banners every 300 rows on a blank page.
    static let banners = page(length: 4000) { y, line in
        guard y % 300 < 60 else { return }
        for x in 40..<760 { line[x] = ink(UInt64((y % 300) * 1000 + x / 6)) }
    }

    @Test(arguments: [true, false])
    func bannersUnderAFloatingElementTakeTheEstimateOrWarn(withEstimate: Bool) {
        // A patterned panel fixed in the middle of the frame: at the true movement its rows pair with blank page, so
        // whole lines fail, and an alias two banners on, where it pairs with nothing, matches every line.
        let panel = Self.page(length: 1000) { y, line in
            guard (450..<550).contains(y) else { return }
            for x in 300..<500 { line[x] = Self.ink(UInt64(0xABC + y * 1000 + x / 5)) }
        }
        let positions = Array(stride(from: 0, through: 900, by: 100))
        let frames = positions.map {
            Self.overlay(Self.banners.lines($0..<($0 + 1000), along: .vertical), with: panel, columns: 300..<500,
                         rows: 450..<550)
        }
        let (updates, image) = Self.stitch(frames, positions: withEstimate ? positions : nil, axis: .vertical)
        // The page, with the panel where the first frame had it.
        let expected = Self.overlay(Self.banners.lines(0..<1900, along: .vertical), with: panel, columns: 300..<500,
                                    rows: 450..<550)
        if withEstimate {
            #expect(updates.map(\.offset) == [0] + Array(repeating: 100, count: 9))
            Self.expectRows(image, of: expected)
        } else {
            Self.expectExactOrWarned(updates, positions: positions)
            Self.expectRows(image, of: expected, height: image?.height)
        }
    }

    /// The banners beside a 100-px sidebar that stays put; with `heading`, one unique 40-row heading at page row 1000.
    static func bannersBesideASidebar(heading: Bool) -> (frames: [StitchFrame], positions: [Int], page: StitchFrame) {
        let headingRows = SyntheticPage(width: 800, length: 2000, seed: 77).frame(at: 0, length: 2000)
        let headingPage = Self.page(length: 4000) { y, line in
            guard (1000..<1040).contains(y) else { return }
            headingRows.pixels.withUnsafeBytes { bytes in
                for x in 100..<760 { line[x] = bytes.loadUnaligned(fromByteOffset: y * 3200 + x * 4, as: UInt32.self) }
            }
        }
        let drawn = heading ? overlay(banners, with: headingPage, columns: 100..<760, rows: 1000..<1040) : banners
        let sidebar = SyntheticPage(width: 100, length: 2000, seed: 99).frame(at: 0, length: 1000)
        let positions = [0, 150, 350, 550, 750, 950, 1150, 1300]
        let frames = positions.map { drawn.lines($0..<($0 + 1000), along: .vertical).replacingColumns(with: sidebar) }
        return (frames, positions, drawn)
    }

    @Test(arguments: [true, false])
    func identicalBannersBesideASidebarTakeTheEstimateOrWarn(withEstimate: Bool) {
        let (frames, positions, page) = Self.bannersBesideASidebar(heading: false)
        let (updates, image) = Self.stitch(frames, positions: withEstimate ? positions : nil, axis: .vertical)
        if withEstimate {
            #expect(updates.map(\.accepted) == Array(repeating: true, count: positions.count))
            Self.expectRows(image, of: page, columns: 100..<800, height: 2300)
        } else {
            Self.expectExactOrWarned(updates, positions: positions)
            Self.expectRows(image, of: page, columns: 100..<800, height: image?.height)
        }
    }

    @Test func aUniqueHeadingAmongTheBannersStaysExact() {
        let (frames, positions, page) = Self.bannersBesideASidebar(heading: true)
        let (updates, image) = Self.stitch(frames, axis: .vertical)
        Self.expectExactOrWarned(updates, positions: positions)
        Self.expectRows(image, of: page, columns: 100..<800, height: image?.height)
    }

    // MARK: Every offset that verifies is weighed

    /// Pairs of frames (the one before, the reference, the current) where offsets verify by pieces.
    static func piecePairs() -> [(name: String, frames: [StitchFrame])] {
        let text = SyntheticPage.plain.frame(at: 0, length: 3000)
        let sidebar = SyntheticPage(width: 240, length: 2000, seed: 99).frame(at: 0, length: 1000)
        func button(_ frame: StitchFrame) -> StitchFrame {
            frame.paintingDisc(centerX: 708, centerY: 908, radius: 44, color: 0xFF22_88EE)
        }
        let panel = page(length: 1000) { y, line in
            guard (450..<550).contains(y) else { return }
            for x in 300..<500 { line[x] = ink(UInt64(0xABC + y * 1000 + x / 5)) }
        }
        func underPanel(_ frame: StitchFrame) -> StitchFrame {
            overlay(frame, with: panel, columns: 300..<500, rows: 450..<550)
        }
        let window = { (page: StitchFrame, position: Int) in page.lines(position..<(position + 1000), along: .vertical) }
        return [
            ("button", [0, 0, 100].map { button(window(text, $0)) }),
            ("button, a long step", [0, 0, 600].map { button(window(text, $0)) }),
            ("sidebar", [0, 60, 150].map { window(text, $0).replacingColumns(with: sidebar) }),
            ("banners beside a sidebar", Array(bannersBesideASidebar(heading: false).frames[0...2])),
            ("banners under a panel", [0, 0, 100].map { underPanel(window(banners, $0)) }),
        ]
    }

    @Test(arguments: piecePairs().map(\.name))
    func thePrefilterNeverLeavesOutAnOffsetThatVerifies(name: String) throws {
        // Every offset in the range that verifies by pieces (tried one by one) is among those the prefilter keeps.
        let frames = try #require(Self.piecePairs().first { $0.name == name }?.frames)
        let configuration = StitchConfiguration(pixelsPerPoint: 2)
        let matcher = PieceMatcher(configuration: configuration)
        let margin = configuration.edgeMarginPixels
        let (before, reference, current) = (frames[0], frames[1], frames[2])
        let band = 0..<1000
        let previousLines = LineHashes(reference, axis: .vertical, margin: margin)
        let currentLines = LineHashes(current, axis: .vertical, margin: margin)
        let unchanged = before.unchangedAcross(current, along: .vertical, lines: band)
        let masked = (LineHashes(piecesOf: reference, axis: .vertical, margin: margin, ignoring: unchanged),
                      LineHashes(piecesOf: current, axis: .vertical, margin: margin, ignoring: unchanged))
        let pieces = PieceMatcher.Pieces(previous: previousLines, current: currentLines, masked: masked)
        let possible = try #require(matcher.possible(PieceMatcher.Pieces(previous: previousLines, current: currentLines),
                                                     in: band))
        let limit = Int(configuration.maximumOffsetFraction * Double(band.count))
        let verified = (-limit...limit).filter { $0 != 0 && matcher.verify(pieces, in: band, at: $0) != nil }
        #expect(!verified.isEmpty, "\(name): nothing verifies")
        #expect(verified.allSatisfy { possible.contains($0) }, "\(name): verified \(verified), kept \(possible)")
    }

    // MARK: Minor: a button over a blank stretch

    @Test func aButtonOverABlankStretchIsDrawnOnceAtTheEnd() {
        // A mostly blank page with a 60-row block of text every 300 rows, under the floating button: where the rows
        // around the button are blank in both frames, its rows are whole lines unchanged in place.
        let text = SyntheticPage.plain.frame(at: 0, length: 4000)
        let page = Self.page(length: 4000) { y, line in
            guard y % 300 < 60 else { return }
            text.pixels.withUnsafeBytes { bytes in
                for x in 0..<800 { line[x] = bytes.loadUnaligned(fromByteOffset: y * 3200 + x * 4, as: UInt32.self) }
            }
        }
        func withButton(_ frame: StitchFrame) -> StitchFrame {
            frame.paintingDisc(centerX: 800 - 92, centerY: frame.height - 92, radius: 44, color: 0xFF22_88EE)
        }
        let positions = [0, 120, 240, 410, 520, 700, 850, 1000]
        let frames = positions.map { withButton(page.lines($0..<($0 + 1000), along: .vertical)) }
        let (updates, image) = Self.stitch(frames, positions: positions)
        #expect(updates.allSatisfy { $0.accepted })
        Self.expectRows(image, of: withButton(page.lines(0..<2000, along: .vertical)))
    }
}

/// Knows each frame of a test by its pixels' storage (frames that look alike are told apart), and proposes the true
/// movement between two of them, or an override for a frame's index.
final class KnownFrames: OffsetEstimator, @unchecked Sendable {
    private let positions: [(storage: UnsafeRawPointer?, index: Int, position: Int)]
    private let overrides: [Int: Int]

    init(_ frames: [StitchFrame], positions: [Int], overrides: [Int: Int] = [:]) {
        self.positions = zip(frames.indices, zip(frames, positions)).map { index, pair in
            (pair.0.pixels.withUnsafeBytes { UnsafeRawPointer($0.baseAddress) }, index, pair.1)
        }
        self.overrides = overrides
    }

    func estimate(from previous: StitchFrame, to current: StitchFrame, band: Range<Int>, axis: ScrollAxis) -> Int? {
        guard let from = find(previous), let to = find(current) else { return nil }
        return overrides[to.index] ?? to.position - from.position
    }

    private func find(_ frame: StitchFrame) -> (index: Int, position: Int)? {
        let storage = frame.pixels.withUnsafeBytes { UnsafeRawPointer($0.baseAddress) }
        return positions.first { $0.storage == storage }.map { ($0.index, $0.position) }
    }
}
