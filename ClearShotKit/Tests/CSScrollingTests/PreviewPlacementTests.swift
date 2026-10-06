import CoreGraphics
import Testing
@testable import CSScrolling

struct PreviewPlacementTests {
    /// The main display (3360 × 1890 pt) without the Dock (56 pt, bottom) and the menu bar (31 pt, top).
    let mainVisible = CGRect(x: 0, y: 56, width: 3360, height: 1803)
    /// The portrait display, left of and below the main display's top; no Dock or menu bar on it.
    let portraitVisible = CGRect(x: -1800, y: -819, width: 1800, height: 3200)

    @Test func theSizesAreTheDecidedOnes() {
        #expect(PreviewPlacement.width == 200)
        #expect(PreviewPlacement.height == 160)
    }

    @Test func rightOfTheRegion() {
        let frame = PreviewPlacement.frame(region: CGRect(x: 400, y: 300, width: 1200, height: 1000), axis: .vertical,
                                           visibleFrame: mainVisible)
        // 12 pt right of the region; as tall as the visible frame less 24 pt above and below.
        #expect(frame == CGRect(x: 1612, y: 80, width: 200, height: 1755))
    }

    @Test func leftWhenTheRegionTouchesTheRightEdge() {
        let frame = PreviewPlacement.frame(region: CGRect(x: 2000, y: 300, width: 1360, height: 1000), axis: .vertical,
                                           visibleFrame: mainVisible)
        #expect(frame == CGRect(x: 1788, y: 80, width: 200, height: 1755))
    }

    @Test func insideWhenNeitherSideFits() {
        let frame = PreviewPlacement.frame(region: CGRect(x: 100, y: 56, width: 3200, height: 1803), axis: .vertical,
                                           visibleFrame: mainVisible)
        // Inside the region's right edge, 12 pt in.
        #expect(frame == CGRect(x: 3088, y: 80, width: 200, height: 1755))
        // A fractional region still gives whole points.
        let fractional = PreviewPlacement.frame(region: CGRect(x: 100.25, y: 56, width: 3200.5, height: 1803),
                                                axis: .vertical, visibleFrame: mainVisible)
        #expect(fractional.origin.x == fractional.origin.x.rounded())
    }

    @Test func underAHorizontalCapture() {
        let frame = PreviewPlacement.frame(region: CGRect(x: 200, y: 800, width: 2400, height: 600), axis: .horizontal,
                                           visibleFrame: mainVisible)
        // 12 pt below the region; as wide as the visible frame less 24 pt each side, centred.
        #expect(frame == CGRect(x: 24, y: 628, width: 3312, height: 160))
        // Too close to the Dock: above.
        let low = PreviewPlacement.frame(region: CGRect(x: 200, y: 100, width: 2400, height: 600), axis: .horizontal,
                                         visibleFrame: mainVisible)
        #expect(low == CGRect(x: 24, y: 712, width: 3312, height: 160))
        // Neither: inside the bottom edge.
        let full = PreviewPlacement.frame(region: mainVisible, axis: .horizontal, visibleFrame: mainVisible)
        #expect(full == CGRect(x: 24, y: 68, width: 3312, height: 160))
    }

    @Test func onThePortraitDisplayItStaysThere() {
        let frame = PreviewPlacement.frame(region: CGRect(x: -1500, y: 0, width: 1100, height: 1500), axis: .vertical,
                                           visibleFrame: portraitVisible)
        #expect(frame == CGRect(x: -388, y: -795, width: 200, height: 3152))
        // At the portrait display's right edge (beside the main display) it goes left, not onto the main display.
        let atEdge = PreviewPlacement.frame(region: CGRect(x: -1000, y: 0, width: 1000, height: 1500), axis: .vertical,
                                            visibleFrame: portraitVisible)
        #expect(atEdge == CGRect(x: -1212, y: -795, width: 200, height: 3152))
        #expect(portraitVisible.contains(atEdge))
    }
}
