import CoreGraphics
import Testing
@testable import CSCapture

struct WindowLevelsTests {
    func level(_ key: CGWindowLevelKey) -> Int {
        Int(CGWindowLevelForKey(key))
    }

    /// Annotate's always-on-top window is `.floating`, alerts are modal panels, and thumbnails and the HUD are `.statusBar`.
    @Test func aPinIsAboveAnAlwaysOnTopEditorAndBelowAlertsAndThumbnails() {
        #expect(level(.floatingWindow) < WindowLevels.pin)
        #expect(WindowLevels.pin < level(.modalPanelWindow))
        #expect(level(.modalPanelWindow) < level(.statusWindow))
    }

    @Test func theCoverSitsAboveIconsAndWidgetsAndBelowNormalWindows() {
        #expect(WindowLevels.wallpaper < level(.desktopWindow))
        #expect(level(.desktopWindow) < WindowLevels.desktopIcon)
        #expect(WindowLevels.desktopIcon == level(.desktopIconWindow))
        #expect(WindowLevels.desktopIcon < WindowLevels.desktopWidget)
        #expect(WindowLevels.desktopWidget < WindowLevels.desktopCover)
        #expect(WindowLevels.desktopCover < level(.normalWindow))
    }
}
