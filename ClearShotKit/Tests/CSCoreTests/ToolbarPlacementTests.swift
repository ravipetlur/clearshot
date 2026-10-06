import CoreGraphics
import Testing
@testable import CSCore

struct ToolbarPlacementTests {
    let layout = DisplayLayout.twoDisplaysWithPortraitSecondary
    /// The main display's visible frame with the Dock (56 pt) along the bottom and the menu bar (31 pt) along the top.
    let mainVisible = CGRect(x: 0, y: 56, width: 3360, height: 1803)
    /// The portrait display has neither, so its visible frame is its frame.
    var portraitVisible: CGRect { layout.display(id: 2)!.frame }
    let toolbar = CGSize(width: 520, height: 44)

    @Test func theGapAndMarginAreTheDecidedOnes() {
        #expect(ToolbarPlacement.gap == 12)
        #expect(ToolbarPlacement.margin == 8)
    }

    @Test func belowTheSelectionWhenThereIsRoom() {
        let placed = ToolbarPlacement.frame(size: toolbar, anchoredTo: CGRect(x: 1000, y: 800, width: 600, height: 400),
                                            visibleFrame: mainVisible)
        #expect(placed.frame == CGRect(x: 1040, y: 744, width: 520, height: 44))
        #expect(placed.side == .below)
    }

    @Test func aboveWhenTheDockLeavesNoRoom() {
        let placed = ToolbarPlacement.frame(size: toolbar, anchoredTo: CGRect(x: 1000, y: 60, width: 600, height: 400),
                                            visibleFrame: mainVisible)
        #expect(placed.frame.origin == CGPoint(x: 1040, y: 472))
        #expect(placed.side == .above)
    }

    @Test func insideWhenTheSelectionFillsTheDisplay() {
        let placed = ToolbarPlacement.frame(size: toolbar, anchoredTo: layout.main.frame, visibleFrame: mainVisible)
        #expect(placed.frame.origin == CGPoint(x: 1420, y: 64))
        #expect(placed.side == .inside)
    }

    @Test func clampedHorizontallyOnThePortraitDisplay() {
        let placed = ToolbarPlacement.frame(size: toolbar, anchoredTo: CGRect(x: -1800, y: 0, width: 300, height: 300),
                                            visibleFrame: portraitVisible)
        #expect(placed.frame.origin == CGPoint(x: -1792, y: -56))
        #expect(placed.side == .below)
        // And at the portrait display's right edge, it stays there rather than spilling onto the main display.
        let right = ToolbarPlacement.frame(size: toolbar, anchoredTo: CGRect(x: -300, y: 0, width: 300, height: 300),
                                           visibleFrame: portraitVisible)
        #expect(right.frame.maxX == -8)
    }

    @Test func aSelectionAtThePortraitDisplaysBottomGoesAbove() {
        let placed = ToolbarPlacement.frame(size: toolbar, anchoredTo: CGRect(x: -1500, y: -819, width: 600, height: 300),
                                            visibleFrame: portraitVisible)
        #expect(placed.frame.origin == CGPoint(x: -1460, y: -507))
        #expect(placed.side == .above)
    }

    @Test func originsAreWholePoints() {
        let placed = ToolbarPlacement.frame(size: CGSize(width: 101, height: 44),
                                            anchoredTo: CGRect(x: 1000.3, y: 800.2, width: 600, height: 400),
                                            visibleFrame: mainVisible)
        #expect(placed.frame.origin.x == placed.frame.origin.x.rounded())
        #expect(placed.frame.origin.y == placed.frame.origin.y.rounded())
        #expect(placed.frame.size == CGSize(width: 101, height: 44))
    }
}
