import CoreGraphics
import CSCore
import Testing
@testable import CSRecording

struct RecordingControlsPlacementTests {
    /// A 3360 × 1890 display at the origin, with the Dock (56 pt) along the bottom and the menu bar (31 pt) along the top.
    let display = CGRect(x: 0, y: 0, width: 3360, height: 1890)
    let visible = CGRect(x: 0, y: 56, width: 3360, height: 1803)
    let bar = CGSize(width: 300, height: 40)

    @Test func belowTheAreaUsesToolbarPlacement() {
        let region = CGRect(x: 1000, y: 800, width: 600, height: 400)
        let frame = RecordingControlsPlacement.frame(size: bar, region: region, position: .belowArea, visibleFrame: visible)
        #expect(frame == CGRect(x: 1150, y: 748, width: 300, height: 40))
        #expect(frame == ToolbarPlacement.frame(size: bar, anchoredTo: region, visibleFrame: visible).frame)
    }

    @Test func aFullscreenRegionPutsTheBarInside() {
        let frame = RecordingControlsPlacement.frame(size: bar, region: display, position: .belowArea, visibleFrame: visible)
        #expect(frame == CGRect(x: 1530, y: 64, width: 300, height: 40))
        #expect(display.contains(frame))
    }

    @Test func topAndBottomOfTheScreenAreCentred() {
        #expect(RecordingControlsPlacement.screenInset == 24)
        let region = CGRect(x: 100, y: 100, width: 400, height: 300)
        let top = RecordingControlsPlacement.frame(size: bar, region: region, position: .topOfScreen, visibleFrame: visible)
        #expect(top == CGRect(x: 1530, y: 1795, width: 300, height: 40))
        let bottom = RecordingControlsPlacement.frame(size: bar, region: region, position: .bottomOfScreen, visibleFrame: visible)
        #expect(bottom == CGRect(x: 1530, y: 80, width: 300, height: 40))
        // On whole points, on a display left of the main one.
        let odd = CGSize(width: 301, height: 41)
        let left = CGRect(x: -1800, y: -819, width: 1800, height: 3200)
        let placed = RecordingControlsPlacement.frame(size: odd, region: region, position: .topOfScreen, visibleFrame: left)
        #expect(placed == CGRect(x: -1051, y: 2316, width: 301, height: 41))
    }
}
