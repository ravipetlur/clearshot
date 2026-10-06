import CoreGraphics
import Testing
@testable import CSCore

/// Placement on two displays (`DisplayLayout.twoDisplaysWithPortraitSecondary`), with the visible frames NSScreen
/// reports: the main display loses the Dock at the bottom and the menu bar at the top; the portrait one has neither.
struct PinPlacementTests {
    let main: PinScreen
    let portrait: PinScreen
    var screens: [PinScreen] { [main, portrait] }

    init() {
        let layout = DisplayLayout.twoDisplaysWithPortraitSecondary
        main = PinScreen(frame: layout.main.frame, visibleFrame: CGRect(x: 0, y: 56, width: 3360, height: 1803))
        let portraitFrame = layout.display(id: 2)!.frame
        portrait = PinScreen(frame: portraitFrame, visibleFrame: portraitFrame)
    }

    func start(_ imagePoints: CGSize, over rect: CGRect) -> PinStart {
        PinPlacement.start(imagePoints: imagePoints, anchor: .capture(rect), screens: screens, active: main, cascade: 0)
    }

    func startOnTheActiveScreen(_ imagePoints: CGSize, cascade: Int) -> PinStart {
        PinPlacement.start(imagePoints: imagePoints, anchor: .activeScreen, screens: screens, active: main, cascade: cascade)
    }

    @Test func aSmallCaptureSitsExactlyOverItsRect() {
        let rect = CGRect(x: 100, y: 200, width: 400, height: 300)
        let start = start(CGSize(width: 400, height: 300), over: rect)
        #expect(start.frame == rect)
        #expect(start.zoom == 1)
    }

    @Test func aLargerImageIsCentredOnItsRect() {
        let start = start(CGSize(width: 528, height: 428), over: CGRect(x: 100, y: 200, width: 400, height: 300))
        #expect(start.frame == CGRect(x: 36, y: 136, width: 528, height: 428))
        #expect(start.zoom == 1)
    }

    @Test func aCaptureUnderTheMenuBarIsClampedBelowIt() {
        let start = start(CGSize(width: 400, height: 289), over: CGRect(x: 100, y: 1600, width: 400, height: 289))
        #expect(start.frame == CGRect(x: 100, y: 1570, width: 400, height: 289))
    }

    @Test func aFullDisplayCaptureZoomsToFitEightyPercent() {
        let start = start(CGSize(width: 3360, height: 1890), over: main.frame)
        #expect(abs(start.zoom - 1442.4 / 1890) < 1e-9)
        #expect(start.frame.origin == CGPoint(x: 397, y: 223))
        #expect(abs(start.frame.height - 1442.4) < 1e-9)
        #expect(main.visibleFrame.contains(start.frame))
    }

    @Test func aPortraitCaptureOnThePortraitDisplayStaysThere() {
        let start = start(CGSize(width: 1000, height: 3000), over: CGRect(x: -1500, y: -500, width: 1000, height: 3000))
        #expect(abs(start.zoom - 2560.0 / 3000) < 1e-9)
        #expect(start.frame.origin == CGPoint(x: -1427, y: -280))
        #expect(portrait.visibleFrame.contains(start.frame))
    }

    @Test func aCaptureSpanningBothDisplaysUsesTheOneWithMoreOfIt() {
        let start = start(CGSize(width: 400, height: 100), over: CGRect(x: -300, y: 100, width: 400, height: 100))
        #expect(start.frame == CGRect(x: -400, y: 100, width: 400, height: 100))
    }

    @Test func anEmptyCaptureRectIsCentredOnTheActiveScreen() {
        let start = start(CGSize(width: 400, height: 300), over: .zero)
        #expect(start.frame == CGRect(x: 1480, y: 807, width: 400, height: 300))
        #expect(start.zoom == 1)
    }

    @Test func anOffScreenCaptureRectIsCentredOnTheActiveScreen() {
        let start = start(CGSize(width: 400, height: 300), over: CGRect(x: 5000, y: 5000, width: 400, height: 300))
        #expect(start.frame == CGRect(x: 1480, y: 807, width: 400, height: 300))
    }

    @Test func pinsCascadeTwentyPointsRightAndDown() {
        let image = CGSize(width: 400, height: 300)
        #expect(startOnTheActiveScreen(image, cascade: 0).frame.origin == CGPoint(x: 1480, y: 807))
        #expect(startOnTheActiveScreen(image, cascade: 1).frame.origin == CGPoint(x: 1500, y: 787))
        #expect(startOnTheActiveScreen(image, cascade: 2).frame.origin == CGPoint(x: 1520, y: 767))
    }

    @Test func aCascadeThatWouldLeaveTheScreenStartsOver() {
        let image = CGSize(width: 2600, height: 1400)
        #expect(startOnTheActiveScreen(image, cascade: 10).frame.origin == CGPoint(x: 580, y: 57))
        #expect(startOnTheActiveScreen(image, cascade: 11).frame.origin == CGPoint(x: 380, y: 257))
        #expect(startOnTheActiveScreen(image, cascade: 11).zoom == 1)
    }

    @Test func aFrameLargerThanTheScreenIsClampedToItsTopLeft() {
        #expect(PinPlacement.clamped(CGRect(x: -10, y: -10, width: 4000, height: 2000), to: main.visibleFrame)
            == CGRect(x: 0, y: -141, width: 4000, height: 2000))
    }

    // The portrait display has been unplugged in the rescue tests: only the main display is left.

    @Test func aPinLeftOnAnUnpluggedDisplayMovesToTheMainScreen() {
        #expect(PinPlacement.rescued(CGRect(x: -1000, y: 0, width: 400, height: 300), screens: [main], main: main)
            == CGRect(x: 1480, y: 807, width: 400, height: 300))
    }

    @Test func aPinStillPartlyOnScreenStays() {
        #expect(PinPlacement.rescued(CGRect(x: -100, y: 500, width: 400, height: 300), screens: [main], main: main) == nil)
    }

    @Test func aPinWithOnlyASliverLeftIsRescued() {
        let sliver = CGRect(x: -390, y: 500, width: 400, height: 300)
        #expect(PinPlacement.rescued(sliver, screens: [main], main: main) == CGRect(x: 1480, y: 807, width: 400, height: 300))
        // With the portrait display still there, the same pin sits on it and stays.
        #expect(PinPlacement.rescued(sliver, screens: screens, main: main) == nil)
    }
}
