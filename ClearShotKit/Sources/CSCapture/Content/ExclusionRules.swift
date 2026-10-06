/// Which windows a capture leaves out.
public struct ExclusionRules: Sendable, Equatable {
    public var ownBundleID: String
    /// ClearShot windows that are content (pins) and stay in captures.
    public var keepOwnWindowIDs: Set<UInt32>
    public var hideDesktopIcons: Bool

    public init(ownBundleID: String, keepOwnWindowIDs: Set<UInt32>, hideDesktopIcons: Bool) {
        self.ownBundleID = ownBundleID
        self.keepOwnWindowIDs = keepOwnWindowIDs
        self.hideDesktopIcons = hideDesktopIcons
    }

    /// The rules for a capture: pins stay in it and every other ClearShot window is left out. The desktop icons and
    /// widgets are left out when the setting says so, or while Hide Desktop Icons covers them, so the capture shows the
    /// wallpaper the cover shows.
    public static func forCapture(ownBundleID: String, pinWindowIDs: Set<UInt32>, hideDesktopIconsSetting: Bool,
                                  desktopIconsHidden: Bool) -> ExclusionRules {
        ExclusionRules(ownBundleID: ownBundleID, keepOwnWindowIDs: pinWindowIDs,
                       hideDesktopIcons: hideDesktopIconsSetting || desktopIconsHidden)
    }

    public func shouldExclude(_ window: WindowRecord) -> Bool {
        if window.ownerBundleID == ownBundleID {
            return !keepOwnWindowIDs.contains(window.id)
        }
        guard hideDesktopIcons else { return false }
        if isOwned(window, bundleID: KnownBundleIDs.finder, name: "Finder"), window.layer == WindowLevels.desktopIcon {
            return true
        }
        // Desktop widgets live in Notification Center windows below the normal layer. WindowManager windows are
        // never excluded: on some displays WindowManager draws the wallpaper itself.
        if isOwned(window, bundleID: KnownBundleIDs.notificationCenter, name: "Notification Center"), window.layer < 0 {
            return true
        }
        return false
    }

    public func excludedWindowIDs(from windows: [WindowRecord]) -> Set<UInt32> {
        Set(windows.filter(shouldExclude).map(\.id))
    }

    private func isOwned(_ window: WindowRecord, bundleID: String, name: String) -> Bool {
        window.ownerBundleID == bundleID || (window.ownerBundleID == nil && window.ownerName == name)
    }
}
