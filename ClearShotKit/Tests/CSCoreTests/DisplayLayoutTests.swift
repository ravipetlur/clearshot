import CoreGraphics
import Testing
@testable import CSCore

extension DisplayLayout {
    /// Two displays, as NSScreen and CGDisplayBounds report them: the main display, 3360×1890 pt @2x, and a second
    /// display in portrait, 1800×3200 pt @2x, placed left of and below the main display. Its CGDisplayBounds is
    /// (-1800, -491, 1800, 3200).
    static let twoDisplaysWithPortraitSecondary = DisplayLayout(displays: [
        DisplayInfo(id: 3, name: "Main Display", frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
                    scale: 2, isBuiltIn: false, safeAreaTop: 0),
        DisplayInfo(id: 2, name: "Portrait Display", frame: CGRect(x: -1800, y: -819, width: 1800, height: 3200),
                    scale: 2, isBuiltIn: false, safeAreaTop: 0),
    ])
}

struct DisplayLayoutTests {
    let layout = DisplayLayout.twoDisplaysWithPortraitSecondary
    var portrait: DisplayInfo { layout.display(id: 2)! }

    @Test func mainDisplayIsTheOneAtTheOrigin() {
        #expect(layout.main.id == 3)
    }

    @Test func appKitToCGMatchesCoreGraphicsBoundsForThePortraitDisplay() {
        #expect(layout.cgRect(fromAppKit: portrait.frame) == CGRect(x: -1800, y: -491, width: 1800, height: 3200))
    }

    @Test func cgConversionRoundTrips() {
        let rect = CGRect(x: -500, y: 1200, width: 300, height: 200)
        #expect(layout.appKitRect(fromCG: layout.cgRect(fromAppKit: rect)) == rect)
        let point = CGPoint(x: -20, y: -700)
        #expect(layout.appKitPoint(fromCG: layout.cgPoint(fromAppKit: point)) == point)
    }

    @Test func findsTheDisplayUnderAPoint() {
        #expect(layout.display(containing: CGPoint(x: 10, y: 10))?.id == 3)
        #expect(layout.display(containing: CGPoint(x: -10, y: -800))?.id == 2)
        // Below the main display and right of the portrait display there is no screen.
        #expect(layout.display(containing: CGPoint(x: 10, y: -10)) == nil)
    }

    @Test func mouseOnTheTopRowOfADisplayBelongsToThatDisplay() {
        // NSEvent.mouseLocation is the CG cursor flipped, so the top row of a display sits at y == frame.maxY.
        #expect(layout.display(containingMouse: CGPoint(x: 10, y: 1890))?.id == 3)
        #expect(layout.display(containingMouse: CGPoint(x: -100, y: 2381))?.id == 2)
        // The plain rect rule excludes that row, which is why the mouse needs its own lookup.
        #expect(layout.display(containing: CGPoint(x: 10, y: 1890)) == nil)
        #expect(layout.display(containing: CGPoint(x: -100, y: 2381)) == nil)
    }

    @Test func mouseOnTheBottomEdgeIsOutsideButJustAboveItIsInside() {
        #expect(layout.display(containingMouse: CGPoint(x: 10, y: 0)) == nil)
        #expect(layout.display(containingMouse: CGPoint(x: 10, y: 0.5))?.id == 3)
        #expect(layout.display(containingMouse: CGPoint(x: -100, y: -819)) == nil)
        #expect(layout.display(containingMouse: CGPoint(x: -100, y: -818.5))?.id == 2)
    }

    /// One display alone answers the same as the layout (Highlight Clicks asks the recorded display only): its top row is
    /// its own, and where a display sits on top of another, the lower one's top row is never the upper one's.
    @Test func aDisplayOwnsTheMouseOnItsTopRowAndNeverTheOneBelowsTopRow() {
        let main = layout.main
        #expect(main.containsMouse(CGPoint(x: 10, y: 1890)))
        #expect(!main.containsMouse(CGPoint(x: 10, y: 0)))
        #expect(!main.containsMouse(CGPoint(x: 3360, y: 10)))
        #expect(portrait.containsMouse(CGPoint(x: -1800, y: 2381)))

        let laptop = DisplayInfo(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2,
                                 isBuiltIn: true, safeAreaTop: 32)
        let above = DisplayInfo(id: 4, name: "Above", frame: CGRect(x: 0, y: 982, width: 1920, height: 1080), scale: 1,
                                isBuiltIn: false, safeAreaTop: 0)
        let stacked = DisplayLayout(displays: [above, laptop])
        // The laptop's top row (its menu bar's top edge) is y == 982, the upper display's bottom edge.
        #expect(laptop.containsMouse(CGPoint(x: 100, y: 982)))
        #expect(!above.containsMouse(CGPoint(x: 100, y: 982)))
        #expect(stacked.display(containingMouse: CGPoint(x: 100, y: 982))?.id == laptop.id)
        #expect(above.containsMouse(CGPoint(x: 100, y: 982.5)))
        #expect(!laptop.containsMouse(CGPoint(x: 100, y: 982.5)))
        #expect(above.containsMouse(CGPoint(x: 100, y: 2062)))
        #expect(stacked.display(containingMouse: CGPoint(x: 100, y: 2062))?.id == above.id)
    }

    @Test func mouseKeepsTheHorizontalEdgeRule() {
        // x == minX is inside, x == maxX is outside: the portrait display's right edge is the main display's left edge.
        #expect(layout.display(containingMouse: CGPoint(x: 0, y: 10))?.id == 3)
        #expect(layout.display(containingMouse: CGPoint(x: 0, y: -100)) == nil)
        #expect(layout.display(containingMouse: CGPoint(x: -1800, y: -100))?.id == 2)
        #expect(layout.display(containingMouse: CGPoint(x: 3360, y: 10)) == nil)
    }

    @Test func localRectHasItsOriginAtTheDisplaysTopLeft() {
        let topLeftCorner = CGRect(x: -1800, y: -819 + 3200 - 50, width: 100, height: 50)
        #expect(layout.localRect(topLeftCorner, in: portrait) == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(layout.appKitRect(fromLocal: CGRect(x: 0, y: 0, width: 100, height: 50), in: portrait) == topLeftCorner)
    }

    @Test func pixelRectScalesAndRoundsOutward() {
        let main = layout.main
        // Local (10.25, 20.5, 100, 50) on a 1890-pt-tall display.
        let rect = CGRect(x: 10.25, y: 1890 - 20.5 - 50, width: 100, height: 50)
        #expect(layout.pixelRect(rect, in: main) == CGRect(x: 20, y: 41, width: 201, height: 100))
    }

    @Test func bestMatchingPicksTheDisplayWithTheLargestOverlap() {
        let mostlyOnPortrait = CGRect(x: -300, y: 100, width: 400, height: 100)
        #expect(layout.display(bestMatching: mostlyOnPortrait)?.id == 2)
        let offscreen = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        #expect(layout.display(bestMatching: offscreen) == nil)
    }

    @Test func apiRectsUseTheBottomLeftOfTheGivenDisplay() {
        let api = CGRect(x: 10, y: 20, width: 300, height: 200)
        #expect(layout.appKitRect(fromAPI: api, on: portrait) == CGRect(x: -1790, y: -799, width: 300, height: 200))
    }

    @Test func pixelSizeUsesTheScale() {
        #expect(portrait.pixelSize == CGSize(width: 3600, height: 6400))
    }
}
