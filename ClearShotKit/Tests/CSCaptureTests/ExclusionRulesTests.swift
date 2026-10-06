import Testing
@testable import CSCapture

struct ExclusionRulesTests {
    let desktopIcons = WindowRecord.fixture(id: 1, layer: WindowLevels.desktopIcon, owner: "Finder", bundleID: KnownBundleIDs.finder)
    let widgets = WindowRecord.fixture(id: 2, layer: WindowLevels.desktopWidget, owner: "Notification Center",
                                       bundleID: KnownBundleIDs.notificationCenter)
    let finderWindow = WindowRecord.fixture(id: 3, layer: 0, owner: "Finder", bundleID: KnownBundleIDs.finder)
    let ownOverlay = WindowRecord.fixture(id: 4, layer: 1000, owner: "ClearShot", bundleID: "test.clearshot")
    let ownPin = WindowRecord.fixture(id: 5, layer: WindowLevels.pin, owner: "ClearShot", bundleID: "test.clearshot")
    let wallpaper = WindowRecord.fixture(id: 6, layer: -2147483625, owner: "Wallpaper", bundleID: KnownBundleIDs.wallpaper)
    /// WindowManager draws the wallpaper on some displays, so it must stay in the capture.
    let windowManagerWallpaper = WindowRecord.fixture(id: 8, layer: WindowLevels.wallpaper, owner: "WindowManager",
                                                      bundleID: KnownBundleIDs.windowManager, title: "Wallpaper")
    /// ClearShot's desktop cover: one of its own windows, never a pin.
    let cover = WindowRecord.fixture(id: 11, layer: WindowLevels.desktopCover, owner: "ClearShot", bundleID: "test.clearshot")

    @Test func hidesDesktopIconsAndWidgetsButKeepsTheWallpaperAndFinderWindows() {
        let rules = ExclusionRules(ownBundleID: "test.clearshot", keepOwnWindowIDs: [], hideDesktopIcons: true)
        #expect(rules.excludedWindowIDs(from: [desktopIcons, widgets, finderWindow, wallpaper]) == [1, 2])
    }

    @Test func keepsTheWindowManagerWallpaperWhenHidingDesktopIcons() {
        let rules = ExclusionRules(ownBundleID: "test.clearshot", keepOwnWindowIDs: [], hideDesktopIcons: true)
        #expect(rules.excludedWindowIDs(from: [desktopIcons, widgets, windowManagerWallpaper, wallpaper]) == [1, 2])
        #expect(!rules.shouldExclude(windowManagerWallpaper))
    }

    @Test func keepsDesktopIconsWhenTheSettingIsOff() {
        let rules = ExclusionRules(ownBundleID: "test.clearshot", keepOwnWindowIDs: [], hideDesktopIcons: false)
        #expect(rules.excludedWindowIDs(from: [desktopIcons, widgets, windowManagerWallpaper]).isEmpty)
    }

    @Test func alwaysExcludesClearShotsOwnWindowsExceptPins() {
        let rules = ExclusionRules(ownBundleID: "test.clearshot", keepOwnWindowIDs: [5], hideDesktopIcons: false)
        #expect(rules.excludedWindowIDs(from: [ownOverlay, ownPin]) == [4])
    }

    @Test func matchesByOwnerNameWhenTheBundleIDIsMissing() {
        let icons = WindowRecord.fixture(id: 7, layer: WindowLevels.desktopIcon, owner: "Finder", bundleID: nil)
        let rules = ExclusionRules(ownBundleID: "test.clearshot", keepOwnWindowIDs: [], hideDesktopIcons: true)
        #expect(rules.shouldExclude(icons))
    }

    @Test func matchesWidgetsByOwnerNameWhenTheBundleIDIsMissing() {
        let nameOnly = WindowRecord.fixture(id: 9, layer: -2147483601, owner: "Notification Center", bundleID: nil)
        let rules = ExclusionRules(ownBundleID: "test.clearshot", keepOwnWindowIDs: [], hideDesktopIcons: true)
        #expect(rules.shouldExclude(nameOnly))
    }

    @Test func keepsNotificationCenterWindowsAtNormalLayers() {
        let banner = WindowRecord.fixture(id: 10, layer: 25, owner: "Notification Center", bundleID: KnownBundleIDs.notificationCenter)
        let rules = ExclusionRules(ownBundleID: "test.clearshot", keepOwnWindowIDs: [], hideDesktopIcons: true)
        #expect(!rules.shouldExclude(banner))
    }

    /// While the cover hides the desktop, captures leave out the icons and widgets under it whatever the setting says,
    /// so a capture shows what is on screen: the wallpaper.
    @Test func theDesktopCoverForcesIconExclusionWithTheSettingOff() {
        let rules = ExclusionRules.forCapture(ownBundleID: "test.clearshot", pinWindowIDs: [],
                                              hideDesktopIconsSetting: false, desktopIconsHidden: true)
        #expect(rules.hideDesktopIcons)
        #expect(rules.excludedWindowIDs(from: [desktopIcons, widgets, windowManagerWallpaper, wallpaper, finderWindow, cover])
            == [1, 2, 11])
        #expect(!rules.shouldExclude(windowManagerWallpaper))
    }

    @Test func forCaptureKeepsPinsAndDropsOtherOwnWindows() {
        let rules = ExclusionRules.forCapture(ownBundleID: "test.clearshot", pinWindowIDs: [5],
                                              hideDesktopIconsSetting: false, desktopIconsHidden: false)
        #expect(rules == ExclusionRules(ownBundleID: "test.clearshot", keepOwnWindowIDs: [5], hideDesktopIcons: false))
        #expect(rules.excludedWindowIDs(from: [ownOverlay, ownPin, cover, desktopIcons, finderWindow]) == [4, 11])
        let settingOn = ExclusionRules.forCapture(ownBundleID: "test.clearshot", pinWindowIDs: [5],
                                                  hideDesktopIconsSetting: true, desktopIconsHidden: false)
        #expect(settingOn.hideDesktopIcons)
    }
}
