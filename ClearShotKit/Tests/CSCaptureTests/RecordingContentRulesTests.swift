import CoreGraphics
import Testing
@testable import CSCapture

/// What a recording's filter lists in `exceptingWindows`. The filter excludes ClearShot and Notification Center, so a
/// listed window of theirs is shown, and a listed window of any other app is hidden (`SCStream.h:180-185`).
struct RecordingContentRulesTests {
    static let clearShot = "test.clearshot"
    // Measured window levels (2026-10-04, `CGWindowListCopyWindowInfo`).
    static let finderIcons = WindowRecord.fixture(id: 30, layer: -2147483603, owner: "Finder", bundleID: "com.apple.finder")
    static let widgets = WindowRecord.fixture(id: 40, layer: -2147483601, owner: "Notification Center",
                                              bundleID: "com.apple.notificationcenterui")
    static let banner = WindowRecord.fixture(id: 41, layer: 23, owner: "Notification Center",
                                             bundleID: "com.apple.notificationcenterui")
    static let safari = WindowRecord.fixture(id: 50)

    static func clearShotWindow(_ id: UInt32) -> WindowRecord {
        .fixture(id: id, layer: 1000, owner: "ClearShot", bundleID: clearShot)
    }

    /// The click overlay (11), a pin on screen at the start (12) and the control bar (13).
    let windows = [11, 12, 13].map(Self.clearShotWindow) + [Self.finderIcons, Self.widgets, Self.banner, Self.safari]

    func rules(kept: Set<UInt32> = [11, 12], hideDesktopIconsSetting: Bool = false,
               desktopIconsHidden: Bool = false) -> RecordingContentRules {
        RecordingContentRules(ownBundleID: Self.clearShot, keptOwnWindowIDs: kept,
                              exclusion: .forCapture(ownBundleID: Self.clearShot, pinWindowIDs: [],
                                                     hideDesktopIconsSetting: hideDesktopIconsSetting,
                                                     desktopIconsHidden: desktopIconsHidden))
    }

    @Test func theClickOverlayAndStartPinsAreShown() {
        let rules = rules()
        #expect(rules.excludedBundleIDs.contains(Self.clearShot))
        let excepted = rules.exceptedWindowIDs(from: windows)
        #expect(excepted.isSuperset(of: [11, 12]))
    }

    @Test func otherClearShotWindowsAreLeftOut() {
        let excepted = rules().exceptedWindowIDs(from: windows)
        #expect(!excepted.contains(13))
        #expect(excepted == [11, 12])
    }

    @Test func desktopIconsAreHiddenWhileTheCoverOrSettingIsOn() {
        #expect(rules(hideDesktopIconsSetting: true).exceptedWindowIDs(from: windows).contains(30))
        #expect(rules(desktopIconsHidden: true).exceptedWindowIDs(from: windows).contains(30))
    }

    @Test func desktopIconsStayWhenNeitherIsOn() {
        #expect(!rules().exceptedWindowIDs(from: windows).contains(30))
    }

    @Test func notificationCenterIsExcludedAndItsWidgetsAreNeverExcepted() {
        let rules = rules(hideDesktopIconsSetting: true, desktopIconsHidden: true)
        #expect(rules.excludedBundleIDs.contains("com.apple.notificationcenterui"))
        let excepted = rules.exceptedWindowIDs(from: windows)
        // Listed, they would be shown.
        #expect(!excepted.contains(40))
        #expect(!excepted.contains(41))
    }

    @Test func anOrdinaryAppWindowIsUntouched() {
        let rules = rules(hideDesktopIconsSetting: true)
        #expect(!rules.excludedBundleIDs.contains("com.apple.Safari"))
        #expect(!rules.exceptedWindowIDs(from: windows).contains(50))
    }

    /// The kept own IDs are the only keep list, whatever the exclusion rules carry.
    @Test func keptOwnWindowIDsAreTheOnlyKeepList() {
        let rules = RecordingContentRules(ownBundleID: Self.clearShot, keptOwnWindowIDs: [11],
                                          exclusion: ExclusionRules(ownBundleID: "com.example.other", keepOwnWindowIDs: [13],
                                                                    hideDesktopIcons: false))
        #expect(rules.ownBundleID == Self.clearShot)
        #expect(rules.exceptedWindowIDs(from: windows) == [11])
    }

    /// Without ClearShot among the shareable applications it can't be excluded as an app; listed, its windows are then
    /// hidden, so the ones not kept are listed instead.
    @Test func withoutClearShotAmongTheAppsItsOtherWindowsAreListedToHideThem() {
        let excepted = rules(hideDesktopIconsSetting: true).exceptedWindowIDs(from: windows, ownAppExcluded: false)
        #expect(excepted == [13, 30])
    }
}
