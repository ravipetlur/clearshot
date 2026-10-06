import CoreGraphics
import Testing
@testable import CSScrolling

/// The rule of evidence for matching by pieces: an offset is accepted only on pieces that tell it apart, never by the
/// number of periodic pieces it lines up, never against content that stayed put, and only when no other offset
/// qualifies as well. Every frame either stitches exactly or warns: never a lost or repeated row.
struct RuleOfEvidenceTests {
    let page = SyntheticPage.plain
    let configuration = StitchConfiguration(pixelsPerPoint: 2)

    private func stitcher(estimator: any OffsetEstimator = NoOffsetEstimate()) -> Stitcher {
        Stitcher(configuration: configuration, estimator: estimator)
    }

    /// The round button 88 px across, 48 px in from the bottom right.
    private func withButton(_ frame: StitchFrame) -> StitchFrame {
        frame.paintingDisc(centerX: frame.width - 48 - 44, centerY: frame.height - 48 - 44, radius: 44, color: 0xFF22_88EE)
    }

    /// The frames at `positions` stitched (along `axis` from the start, when given), and the composed picture.
    private func stitch(_ frames: [StitchFrame], estimator: any OffsetEstimator = NoOffsetEstimate(),
                        axis: ScrollAxis? = nil) -> (updates: [StitchUpdate], image: CGImage?) {
        var stitcher = Stitcher(configuration: StitchConfiguration(pixelsPerPoint: 2, axis: axis), estimator: estimator)
        let updates = frames.map { stitcher.add($0) }
        return (updates, stitcher.compose())
    }

    /// Whether `image` is exactly `expected` (tight BGRA, 800 px wide).
    private func expectExactly(_ image: CGImage?, _ expected: StitchFrame, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let image else {
            Issue.record("nothing composed", sourceLocation: sourceLocation)
            return
        }
        #expect(image.height == expected.height, sourceLocation: sourceLocation)
        let difference = firstDifferentRow(tightBytes(of: image), expected.pixels, rowBytes: 3200)
        #expect(difference == nil, "first differing row: \(difference ?? -1)", sourceLocation: sourceLocation)
    }

    // MARK: An alias with more votes than the truth

    @Test func anAliasWithMoreVotesThanTheTruthIsNotAccepted() throws {
        // 16 pieces, 400 lines: 15 columns repeat every 40 lines, one is different on every line; the truth is 50. The
        // alias at 10 pairs more lines of the 15 than the truth does, but the one column contradicts it everywhere.
        let matcher = PieceMatcher(configuration: StitchConfiguration(pixelsPerPoint: 0.25))
        func key(_ piece: Int, _ row: Int) -> UInt64 { SyntheticPage.mix(UInt64(piece * 100_000 + row)) | 1 }
        func frame(at top: Int) -> LineHashes {
            LineHashes(pieces: (0..<16).map { piece in
                (0..<400).map { line in piece < 15 ? key(piece, (top + line) % 40) : key(piece, top + line) }
            })
        }
        let found = try #require(matcher.match(from: frame(at: 0), to: frame(at: 50), in: 0..<400, candidates: []))
        #expect(found.offset == 50)
    }

    @Test func labelledItemsUnderAButtonWithoutAnEstimateAreNotLost() {
        // Items 120 rows apart, each with a unique label 40 px wide and the same furniture across the rest, under the
        // floating button; steps of 100, then 180, and no estimate at all.
        let positions = [0, 100, 200, 300, 400, 580, 760]
        func list(_ position: Int, _ length: Int) -> StitchFrame {
            ListPage.frame(at: position, length: length, item: 120, filled: 90, label: 40..<80, furniture: 90..<768)
        }
        let (updates, image) = stitch(positions.map { withButton(list($0, 1000)) })
        #expect(updates.map(\.offset) == [0, 100, 100, 100, 100, 180, 180])
        expectExactly(image, withButton(list(0, 1760)))
    }

    // MARK: Never still when the page moved

    @Test(arguments: [[0, 120, 240, 360, 480, 640, 760, 880], [0, 160, 320, 440, 560]])
    func aStepOfWholeItemsIsMeasuredNotTakenForStill(positions: [Int]) {
        // 80-row items under the floating button: a step of 160 lines the furniture up in place.
        let frames = positions.map { withButton(ListPage.frame(at: $0, length: 1000)) }
        let (updates, image) = stitch(frames, estimator: KnownPositions(Array(zip(positions, frames))))
        #expect(updates.map(\.offset) == [0] + zip(positions.dropFirst(), positions).map { $0 - $1 })
        expectExactly(image, withButton(ListPage.frame(at: 0, length: 1000 + positions.last!)))
    }

    @Test(arguments: [560, 600], [nil, ScrollAxis.vertical])
    func aWideStickySidebarThenScrollingAlongNeverLosesRows(width: Int, axis: ScrollAxis?) {
        // The page (the narrower part) scrolls 100 three times beside a sticky sidebar, then the sidebar scrolls along.
        let sidebar = SyntheticPage(width: width, length: 4000, seed: 99)
        let frames = [(0, 0), (100, 0), (200, 0), (300, 0), (400, 100), (500, 200), (600, 300)].map {
            page.frame(at: $0.0, length: 1000).replacingColumns(with: sidebar.frame(at: $0.1, length: 1000))
        }
        let (updates, image) = stitch(frames, axis: axis)
        expectEitherExactOrWarned(updates, steps: [100, 100, 100, 100, 100, 100], axisKnown: axis != nil)
        expectPageColumns(image, columns: width..<800)
    }

    // MARK: Sticky sidebars of every width: exact or warned, never wrong rows

    @Test(arguments: [200, 240, 280, 320, 360, 400, 440, 520, 560, 600], [nil, ScrollAxis.vertical])
    func aStickySidebarOfAnyWidthStitchesExactlyOrWarns(width: Int, axis: ScrollAxis?) {
        let sidebar = SyntheticPage(width: width, length: 4000, seed: 99)
        let positions = [0, 120, 240, 360, 480, 600, 720]
        let frames = positions.map {
            page.frame(at: $0, length: 1000).replacingColumns(with: sidebar.frame(at: 0, length: 1000))
        }
        let (updates, image) = stitch(frames, axis: axis)
        expectEitherExactOrWarned(updates, steps: Array(repeating: 120, count: 6), axisKnown: axis != nil)
        expectPageColumns(image, columns: width..<800)
    }

    /// Every frame after the first is either accepted with its true step (measured from the last accepted frame) or,
    /// once the axis is known, left with the warning on: never silently not stitched. (Before the axis is known, a frame
    /// that the other axis reads as an animation isn't warned about: the rule that keeps a wide animated strip quiet.)
    private func expectEitherExactOrWarned(_ updates: [StitchUpdate], steps: [Int], axisKnown: Bool,
                                           sourceLocation: SourceLocation = #_sourceLocation) {
        var pending = 0
        for (update, step) in zip(updates.dropFirst(), steps) {
            pending += step
            if update.accepted {
                #expect(update.offset == pending, sourceLocation: sourceLocation)
                pending = 0
            } else if axisKnown || update.axis != nil {
                #expect(update.warnings.contains(.slowDown), "not stitched and no warning: \(update.trace?.description ?? "")",
                        sourceLocation: sourceLocation)
            }
        }
    }

    /// Whether the composed `image` is the page's columns `columns` from its first row, every row once.
    private func expectPageColumns(_ image: CGImage?, columns: Range<Int>, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let image else {
            Issue.record("nothing composed", sourceLocation: sourceLocation)
            return
        }
        let composed = FalseMatchTests.columns(columns, of: tightBytes(of: image), width: 800)
        let expected = FalseMatchTests.columns(columns, of: page.expected(to: image.height - 1000, length: 1000), width: 800)
        let difference = firstDifferentRow(composed, expected, rowBytes: columns.count * 4)
        #expect(difference == nil, "first differing row: \(difference ?? -1)", sourceLocation: sourceLocation)
    }
}
