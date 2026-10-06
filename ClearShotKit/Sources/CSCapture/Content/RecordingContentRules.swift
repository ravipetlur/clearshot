/// What a recording leaves out: ClearShot and Notification Center as whole apps, so their windows that open later are
/// left out too, except ClearShot's own windows that belong in the recording (the click overlay, the pins on screen at
/// the start); and, while Hide Desktop Icons or the cover is on, the desktop-icon windows.
///
/// ScreenCaptureKit's `exceptingWindows` toggles (`SCStream.h:180-185`): with `excludingApplications`, a listed window
/// of an excluded app is shown, and a listed window of any other app is hidden. So ClearShot's kept windows are listed
/// to show them, Finder's desktop icons to hide them, and Notification Center's windows never (listed, its desktop
/// widgets would come back; they stay hidden through the app's exclusion).
public struct RecordingContentRules: Sendable, Equatable {
    public let ownBundleID: String
    /// ClearShot's windows that stay in the recording: the single keep list.
    public let keptOwnWindowIDs: Set<UInt32>
    /// What decides other apps' windows (the desktop icons); its own keep list and bundle ID give way to the two above.
    private let exclusion: ExclusionRules

    public init(ownBundleID: String, keptOwnWindowIDs: Set<UInt32>, exclusion: ExclusionRules) {
        self.ownBundleID = ownBundleID
        self.keptOwnWindowIDs = keptOwnWindowIDs
        self.exclusion = ExclusionRules(ownBundleID: ownBundleID, keepOwnWindowIDs: keptOwnWindowIDs,
                                        hideDesktopIcons: exclusion.hideDesktopIcons)
    }

    /// The apps the filter excludes: ClearShot, then Notification Center.
    public var excludedBundleIDs: [String] {
        [ownBundleID, KnownBundleIDs.notificationCenter]
    }

    /// The IDs of the windows to list in `exceptingWindows`: ClearShot's kept windows (shown) and the other apps'
    /// windows `ExclusionRules` leaves out (hidden). Notification Center's are never listed.
    public func exceptedWindowIDs(from windows: [WindowRecord]) -> Set<UInt32> {
        exceptedWindowIDs(from: windows, ownAppExcluded: true)
    }

    /// As `exceptedWindowIDs(from:)`; with `ownAppExcluded` false (ClearShot missing from the shareable applications, so
    /// it can't be excluded as an app), its windows that aren't kept are listed instead, which hides them, and the kept
    /// ones stay by not being listed.
    func exceptedWindowIDs(from windows: [WindowRecord], ownAppExcluded: Bool) -> Set<UInt32> {
        Set(windows.filter { window in
            if window.ownerBundleID == ownBundleID {
                return keptOwnWindowIDs.contains(window.id) == ownAppExcluded
            }
            if let bundleID = window.ownerBundleID, excludedBundleIDs.contains(bundleID) {
                return false
            }
            return exclusion.shouldExclude(window)
        }.map(\.id))
    }
}
