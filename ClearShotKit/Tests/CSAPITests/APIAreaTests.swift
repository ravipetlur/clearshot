import CoreGraphics
import CSCore
import Testing
@testable import CSAPI

/// API points are from the given display's bottom-left, y up; display 1 is the first of the layout (the menu-bar
/// screen), the rest follow in layout order.
struct APIAreaTests {
    let layout = DisplayLayout.twoDisplaysWithPortraitSecondary
    /// A point on the main display, for the pointer.
    let onMain = CGPoint(x: 1000, y: 1000)

    func area(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, display: Int?) -> APIArea {
        APIArea(rect: CGRect(x: x, y: y, width: width, height: height), display: display)
    }

    @Test func displayOneIsTheMainDisplay() throws {
        let resolved = try areaA.resolve(in: layout, mouse: CGPoint(x: -900, y: 0))
        #expect(resolved.rect == CGRect(x: 100, y: 120, width: 200, height: 150))
        #expect(resolved.display.id == 3)
        #expect(!resolved.wasClamped)
    }

    @Test func thePortraitDisplayIsDisplayTwoAndItsBottomLeftIsTheOrigin() throws {
        let resolved = try area(100, 120, 200, 150, display: 2).resolve(in: layout, mouse: onMain)
        #expect(resolved.rect == CGRect(x: -1700, y: -699, width: 200, height: 150))
        #expect(resolved.display.id == 2)
        #expect(!resolved.wasClamped)
    }

    @Test func withoutADisplayThePointersDisplayIsUsed() throws {
        let region = area(100, 120, 200, 150, display: nil)
        let onPortrait = try region.resolve(in: layout, mouse: CGPoint(x: -900, y: 0))
        #expect(onPortrait.display.id == 2)
        #expect(onPortrait.rect == CGRect(x: -1700, y: -699, width: 200, height: 150))
        let onMainDisplay = try region.resolve(in: layout, mouse: onMain)
        #expect(onMainDisplay.display.id == 3)
        #expect(onMainDisplay.rect == CGRect(x: 100, y: 120, width: 200, height: 150))
        // A pointer on no display (below the main display, right of the portrait display): the main display.
        #expect(try region.resolve(in: layout, mouse: CGPoint(x: 10, y: -10)).display.id == 3)
    }

    @Test func displayTwoIsMissingWithThePortraitDisplayUnplugged() {
        let unplugged = DisplayLayout.mainOnly
        #expect(throws: APIError.noSuchDisplay(2)) {
            try area(100, 120, 200, 150, display: 2).resolve(in: unplugged, mouse: onMain)
        }
        #expect(APIError.noSuchDisplay(2).message == "There's no display 2")
        #expect(throws: Never.self) { try areaA.resolve(in: unplugged, mouse: onMain) }
    }

    @Test func aPartlyOffAreaIsClampedAndSaysSo() throws {
        let resolved = try area(3300, 120, 200, 150, display: 1).resolve(in: layout, mouse: onMain)
        #expect(resolved.rect == CGRect(x: 3300, y: 120, width: 60, height: 150))
        #expect(resolved.display.id == 3)
        #expect(resolved.wasClamped)
    }

    @Test func anAreaOffTheDisplayIsAnError() {
        #expect(throws: APIError.areaOffDisplay(1)) {
            try area(3400, 120, 200, 150, display: 1).resolve(in: layout, mouse: onMain)
        }
        // Touching the display's right edge isn't on it.
        #expect(throws: APIError.areaOffDisplay(1)) {
            try area(3360, 120, 200, 150, display: 1).resolve(in: layout, mouse: onMain)
        }
        // Numbered as the display it was meant for, also when that is the pointer's.
        #expect(throws: APIError.areaOffDisplay(2)) {
            try area(100, 3300, 200, 150, display: nil).resolve(in: layout, mouse: CGPoint(x: -900, y: 0))
        }
    }

    /// Some of the area is on the display, but less than 4 points of it each way: it is too small, not off the display.
    @Test func lessThanFourPointsOnTheDisplayIsTooSmall() throws {
        // 2 points of it on the display.
        #expect(throws: APIError.areaTooSmall) {
            try area(3358, 120, 200, 150, display: 1).resolve(in: layout, mouse: onMain)
        }
        // Wholly on the display, but 2 points wide, or half a point tall.
        #expect(throws: APIError.areaTooSmall) {
            try area(100, 120, 2, 150, display: 1).resolve(in: layout, mouse: onMain)
        }
        #expect(throws: APIError.areaTooSmall) {
            try area(100, 120, 200, 0.5, display: nil).resolve(in: layout, mouse: onMain)
        }
        // Four points is enough.
        let four = try area(3356, 120, 200, 150, display: 1).resolve(in: layout, mouse: onMain)
        #expect(four.rect.width == 4)
    }

    @Test func numberingFollowsTheLayoutNotDisplayIDs() throws {
        let renumbered = DisplayLayout(displays: [
            DisplayInfo(id: 9, name: "Main", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                        scale: 2, isBuiltIn: true, safeAreaTop: 32),
            DisplayInfo(id: 1, name: "Side", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                        scale: 1, isBuiltIn: false, safeAreaTop: 0),
        ])
        let second = try area(10, 20, 100, 100, display: 2).resolve(in: renumbered, mouse: .zero)
        #expect(second.display.id == 1)
        #expect(second.rect == CGRect(x: 1522, y: 20, width: 100, height: 100))
        #expect(try area(10, 20, 100, 100, display: 1).resolve(in: renumbered, mouse: .zero).display.id == 9)
        #expect(throws: APIError.noSuchDisplay(9)) {
            try area(10, 20, 100, 100, display: 9).resolve(in: renumbered, mouse: .zero)
        }
    }
}
