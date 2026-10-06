import CoreGraphics
import Testing
@testable import CSCapture

struct WindowPickerTests {
    // Front to back.
    let windows = [
        WindowRecord.fixture(id: 10, frame: CGRect(x: 0, y: 0, width: 3360, height: 24), layer: 25, owner: "Control Center"),
        WindowRecord.fixture(id: 11, frame: CGRect(x: 100, y: 100, width: 300, height: 200)),
        WindowRecord.fixture(id: 12, frame: CGRect(x: 50, y: 50, width: 800, height: 600)),
        WindowRecord.fixture(id: 14, frame: CGRect(x: 0, y: 0, width: 3360, height: 1890), layer: WindowLevels.desktopIcon, owner: "Finder"),
    ]

    @Test func picksTheFrontmostNormalWindowUnderThePoint() {
        #expect(WindowPicker.window(at: CGPoint(x: 150, y: 150), in: windows, excluding: [])?.id == 11)
        #expect(WindowPicker.window(at: CGPoint(x: 600, y: 500), in: windows, excluding: [])?.id == 12)
    }

    @Test func skipsMenuBarItemsDesktopAndExcludedWindows() {
        #expect(WindowPicker.window(at: CGPoint(x: 10, y: 10), in: windows, excluding: [])?.id == nil)
        #expect(WindowPicker.window(at: CGPoint(x: 150, y: 150), in: windows, excluding: [11])?.id == 12)
    }

    @Test func skipsWindowsSmallerThanTheMinimumSide() {
        let point = CGPoint(x: 65, y: 65)
        let large = WindowRecord.fixture(id: 33, frame: CGRect(x: 50, y: 50, width: 800, height: 600))
        // Front to back: each too-small window sits in front of a larger one that also contains the point.
        let tooSmall = WindowRecord.fixture(id: 30, frame: CGRect(x: 60, y: 60, width: 20, height: 20))
        let tooNarrow = WindowRecord.fixture(id: 31, frame: CGRect(x: 60, y: 60, width: 20, height: 200))
        let tooShort = WindowRecord.fixture(id: 32, frame: CGRect(x: 60, y: 60, width: 200, height: 20))
        #expect(WindowPicker.window(at: point, in: [tooSmall, tooNarrow, tooShort, large], excluding: [])?.id == 33)

        // Exactly the minimum side is still offered.
        let atMinimum = WindowRecord.fixture(id: 34, frame: CGRect(x: 60, y: 60, width: 40, height: 40))
        #expect(WindowPicker.window(at: point, in: [atMinimum, large], excluding: [])?.id == 34)
    }

    @Test func skipsInvisibleWindows() {
        let ghost = [WindowRecord.fixture(id: 20, frame: CGRect(x: 0, y: 0, width: 500, height: 500), alpha: 0)]
        #expect(WindowPicker.window(at: CGPoint(x: 10, y: 10), in: ghost, excluding: []) == nil)
    }
}
