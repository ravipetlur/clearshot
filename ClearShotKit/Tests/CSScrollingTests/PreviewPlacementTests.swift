import CoreGraphics
import Testing
@testable import CSScrolling

struct PreviewPlacementTests {
    /// The main display (3360 × 1890 pt) without the Dock (56 pt, bottom) and the menu bar (31 pt, top).
    static let mainVisible = CGRect(x: 0, y: 56, width: 3360, height: 1803)
    /// The portrait display, left of and below the main display's top; no Dock or menu bar on it.
    static let portraitVisible = CGRect(x: -1800, y: -819, width: 1800, height: 3200)

    @Test func thePreviewGoesBesideTheRegionOrInsideIt() {
        let main = Self.mainVisible, portrait = Self.portraitVisible
        let rows: [(name: String, region: CGRect, axis: ScrollAxis, visible: CGRect, frame: CGRect)] = [
            // 12 pt right of the region; as tall as the visible frame less 24 pt above and below.
            ("right of the region", CGRect(x: 400, y: 300, width: 1200, height: 1000), .vertical, main,
             CGRect(x: 1612, y: 80, width: 200, height: 1755)),
            ("left when the region touches the right edge", CGRect(x: 2000, y: 300, width: 1360, height: 1000), .vertical,
             main, CGRect(x: 1788, y: 80, width: 200, height: 1755)),
            // Inside the region's right edge, 12 pt in.
            ("inside when neither side fits", CGRect(x: 100, y: 56, width: 3200, height: 1803), .vertical, main,
             CGRect(x: 3088, y: 80, width: 200, height: 1755)),
            // 12 pt below the region; as wide as the visible frame less 24 pt each side, centred.
            ("under a horizontal capture", CGRect(x: 200, y: 800, width: 2400, height: 600), .horizontal, main,
             CGRect(x: 24, y: 628, width: 3312, height: 160)),
            ("above it when too close to the Dock", CGRect(x: 200, y: 100, width: 2400, height: 600), .horizontal, main,
             CGRect(x: 24, y: 712, width: 3312, height: 160)),
            ("inside the bottom edge when neither fits", main, .horizontal, main,
             CGRect(x: 24, y: 68, width: 3312, height: 160)),
            ("on the portrait display it stays there", CGRect(x: -1500, y: 0, width: 1100, height: 1500), .vertical,
             portrait, CGRect(x: -388, y: -795, width: 200, height: 3152)),
            // At the portrait display's right edge (beside the main display) it goes left, not onto the main display.
            ("left at the portrait display's right edge", CGRect(x: -1000, y: 0, width: 1000, height: 1500), .vertical,
             portrait, CGRect(x: -1212, y: -795, width: 200, height: 3152)),
        ]
        for row in rows {
            let frame = PreviewPlacement.frame(region: row.region, axis: row.axis, visibleFrame: row.visible)
            #expect(frame == row.frame, "\(row.name)")
            #expect(row.visible.contains(frame), "\(row.name)")
        }
        // A fractional region still gives whole points.
        let fractional = PreviewPlacement.frame(region: CGRect(x: 100.25, y: 56, width: 3200.5, height: 1803),
                                                axis: .vertical, visibleFrame: main)
        #expect(fractional.origin.x == fractional.origin.x.rounded())
    }
}
