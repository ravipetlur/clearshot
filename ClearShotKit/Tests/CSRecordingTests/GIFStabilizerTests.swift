import Testing
@testable import CSRecording

/// The stabiliser: a pixel changes only when a channel moves past the threshold from what the viewer shows there; the
/// changes give the rectangle and the mask.
struct GIFStabilizerTests {
    let gray: UInt32 = 0x64_6464
    /// An exact palette for these frames: gray, a lighter gray, and the colours the tests move pixels to.
    let palette = GIFPalette(colors: [0x64_6464, 0x68_6868, 0x6E_6E6E, 0xC8_3232], transparentIndex: 4)

    func solid(_ color: UInt32, changes: [Int: UInt32] = [:]) -> GIFFrame {
        GIFFixtures.frame(width: 8, height: 8) { x, y in changes[y * 8 + x] ?? color }
    }

    /// The viewer shows `frame` after it was diffed, indexed and committed.
    func show(_ frame: GIFFrame, on stabilizer: inout GIFStabilizer) {
        guard let diff = stabilizer.diff(frame) else { return }
        let indices = GIFQuantizer.indices(for: frame, diff: diff, palette: palette, dither: false)
        stabilizer.commit(diff, indices: indices, palette: palette)
    }

    @Test func pixelsWithinTheThresholdStayTransparent() throws {
        var stabilizer = GIFStabilizer(width: 8, height: 8, threshold: 6)
        show(solid(gray), on: &stabilizer)
        // (2, 2) and (5, 5) move by 10; (3, 3), inside their rectangle, by 4.
        let next = solid(gray, changes: [2 * 8 + 2: 0x6E_6E6E, 5 * 8 + 5: 0x6E_6E6E, 3 * 8 + 3: 0x68_6868])
        let found = stabilizer.diff(next)
        let diff = try #require(found)
        #expect(diff.rect == GIFRect(x: 2, y: 2, width: 4, height: 4))
        #expect(diff.changed.filter { $0 }.count == 2)
        let indices = GIFQuantizer.indices(for: next, diff: diff, palette: palette, dither: false)
        #expect(indices.count == 16)
        #expect(indices[0] == 2)
        #expect(indices[15] == 2)
        // The pixel within the threshold keeps showing the gray: transparent.
        #expect(indices[1 * 4 + 1] == 4)
        #expect(indices.filter { $0 == 4 }.count == 14)
    }

    /// The comparison is with what the viewer shows (the palette's colour), not with the last source frame.
    @Test func theThresholdIsMeasuredFromWhatTheViewerShows() throws {
        // 0x606060 shows as the palette's 0x646464; 0x6A moves 10 from the source but only 6 from what is shown.
        var stabilizer = GIFStabilizer(width: 8, height: 8, threshold: 6)
        show(solid(0x60_6060), on: &stabilizer)
        #expect(stabilizer.diff(solid(0x6A_6A6A)) == nil)
        let found = stabilizer.diff(solid(0x6B_6B6B))
        let moved = try #require(found)
        #expect(moved.rect == GIFRect(x: 0, y: 0, width: 8, height: 8))
    }

    @Test func theRectangleBoundsEveryChange() throws {
        var generator = SeededGenerator(seed: 3)
        for _ in 0..<20 {
            var stabilizer = GIFStabilizer(width: 8, height: 8, threshold: 0)
            show(solid(gray), on: &stabilizer)
            let points = Set((0..<Int.random(in: 1...6, using: &generator)).map { _ in Int.random(in: 0..<64, using: &generator) })
            let next = solid(gray, changes: Dictionary(uniqueKeysWithValues: points.map { ($0, UInt32(0xC8_3232)) }))
            let found = stabilizer.diff(next)
            let diff = try #require(found)
            let xs = points.map { $0 % 8 }, ys = points.map { $0 / 8 }
            let rect = GIFRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()! + 1, height: ys.max()! - ys.min()! + 1)
            #expect(diff.rect == rect)
            #expect(diff.changed.count == rect.width * rect.height)
            for row in 0..<rect.height {
                for column in 0..<rect.width {
                    let point = (rect.y + row) * 8 + rect.x + column
                    #expect(diff.changed[row * rect.width + column] == points.contains(point))
                }
            }
        }
    }

    @Test func anUnchangedFrameIsNil() throws {
        var stabilizer = GIFStabilizer(width: 8, height: 8, threshold: 0)
        // Nothing is shown yet: the first frame is all of it.
        let found = stabilizer.diff(solid(gray))
        let first = try #require(found)
        #expect(first.rect == GIFRect(x: 0, y: 0, width: 8, height: 8))
        #expect(first.changed.allSatisfy { $0 })
        stabilizer.commit(first, indices: GIFQuantizer.indices(for: solid(gray), diff: first, palette: palette, dither: false),
                          palette: palette)
        #expect(stabilizer.diff(solid(gray)) == nil)
    }
}
