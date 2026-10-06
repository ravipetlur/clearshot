import CoreGraphics
import Testing
@testable import CSScrolling

struct LineHashesTests {
    let page = SyntheticPage.plain
    /// 16 pt at 2 px a point.
    let margin = StitchConfiguration(pixelsPerPoint: 2).edgeMarginPixels

    @Test func rowHashesSkipTheEdgeMargins() {
        #expect(margin == 32)
        let frame = page.frame(at: 0, length: 400)
        let hashes = LineHashes(frame, axis: .vertical, margin: margin)
        #expect(hashes.count == 400)
        // An overlay scroll bar in the margins, on every row: nothing changes.
        let scrollBars = frame.painting(CGRect(x: 0, y: 0, width: margin, height: 400), color: 0xFF80_8080)
            .painting(CGRect(x: frame.width - margin, y: 0, width: margin, height: 400), color: 0xFF80_8080)
        #expect(LineHashes(scrollBars, axis: .vertical, margin: margin) == hashes)
        // The first column inside the margin counts.
        let inside = frame.painting(CGRect(x: margin, y: 100, width: 1, height: 1), color: 0xFF00_00FF)
        let changed = LineHashes(inside, axis: .vertical, margin: margin)
        #expect(changed.hashes[100] != hashes.hashes[100])
        #expect(changed.hashes[99] == hashes.hashes[99] && changed.hashes[101] == hashes.hashes[101])
        // A narrow frame keeps at least half of each line.
        let narrow = StitchFrame(width: 40, height: 1, bytesPerRow: 160, pixels: [UInt8](repeating: 255, count: 160),
                                 colorSpace: page.colorSpace)
        let changedNarrow = narrow.painting(CGRect(x: 10, y: 0, width: 1, height: 1), color: 0xFF00_0000)
        #expect(LineHashes(changedNarrow, axis: .vertical, margin: margin) != LineHashes(narrow, axis: .vertical, margin: margin))
    }

    @Test func uniformLinesAreBlank() {
        let frame = page.frame(at: 0, length: 44)
        let hashes = LineHashes(frame, axis: .vertical, margin: margin)
        // Rows 0–8 and 35–43 are the gaps between text lines; rows 9–34 hold text.
        for row in 0..<44 {
            #expect(hashes.blank[row] == !(9..<35).contains(row), "row \(row)")
        }
        // A uniform row is blank whatever its colour, and different colours still hash differently; something only
        // in the margins doesn't stop a row being blank.
        let grey = frame.painting(CGRect(x: 0, y: 0, width: frame.width, height: 1), color: 0xFF80_8080)
            .painting(CGRect(x: 0, y: 1, width: 10, height: 1), color: 0xFF00_0000)
        let greyHashes = LineHashes(grey, axis: .vertical, margin: margin)
        #expect(greyHashes.blank[0] && greyHashes.blank[1])
        #expect(greyHashes.hashes[0] != hashes.hashes[0])
        #expect(greyHashes.hashes[1] == hashes.hashes[1])
    }

    @Test func columnHashesOfATransposedFrameMatchRowHashes() {
        let rows = LineHashes(page.frame(at: 300, length: 600), axis: .vertical, margin: margin)
        let columns = LineHashes(page.frame(at: 300, length: 600, axis: .horizontal), axis: .horizontal, margin: margin)
        #expect(columns.count == 600)
        #expect(columns == rows)
        #expect(rows.blank.contains(true) && rows.blank.contains(false))
    }
}
