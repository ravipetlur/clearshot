import CoreGraphics

/// One window, in CoreGraphics global coordinates (origin at the main display's top-left, y down).
public struct WindowRecord: Sendable, Equatable, Identifiable {
    public let id: UInt32
    public let frame: CGRect
    public let layer: Int
    public let ownerPID: Int32
    public let ownerName: String
    public let ownerBundleID: String?
    public let title: String?
    public let alpha: Double
    public let isOnScreen: Bool

    public init(id: UInt32, frame: CGRect, layer: Int, ownerPID: Int32, ownerName: String, ownerBundleID: String?,
                title: String?, alpha: Double, isOnScreen: Bool) {
        self.id = id
        self.frame = frame
        self.layer = layer
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.ownerBundleID = ownerBundleID
        self.title = title
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }
}

/// Window levels (layers) that matter for exclusion, the desktop cover and pins.
///
/// The desktop levels were measured on macOS 27 (2026-10-04) with `CGWindowListCopyWindowInfo([.optionAll],
/// kCGNullWindowID)`, reading each window's `kCGWindowLayer`, and `CGWindowLevelForKey`. From the bottom: WindowManager
/// "Wallpaper" −2147483624, `kCGDesktopWindowLevel` −2147483623, WindowManager's full-display backdrop −2147483622,
/// Finder's icons −2147483603, Window Server strips −2147483602, Notification Center widgets −2147483601; normal windows
/// 0; Dock and Mission Control 20 and above. Stage Manager was off, so its strip wasn't measured.
public enum WindowLevels {
    /// WindowManager's full-display window titled "Wallpaper" (measured 2026-10-04, `CGWindowListCopyWindowInfo`).
    public static let wallpaper = -2147483624
    /// Finder's desktop icons (`kCGDesktopIconWindowLevel`, read with `CGWindowLevelForKey(.desktopIconWindow)` and
    /// matching the icon window's layer in `CGWindowListCopyWindowInfo`).
    public static let desktopIcon = -2147483603
    /// Notification Center's desktop widgets (measured 2026-10-04, `CGWindowListCopyWindowInfo`).
    public static let desktopWidget = -2147483601
    /// ClearShot's desktop cover (Hide Desktop Icons), chosen from the 2026-10-04 measurement above: the lowest level
    /// above the widgets, so it hides them and the icons, and below normal windows, the Dock and Mission Control.
    public static let desktopCover = -2147483600
    /// A pin: one above `.floating` (3 on macOS 27, `CGWindowLevelForKey`), so Annotate's always-on-top window can't
    /// cover it, and below modal panels (alerts, 8) and `.statusBar` (thumbnails and the HUD, 25).
    public static let pin = Int(CGWindowLevelForKey(.floatingWindow)) + 1
}

/// System processes whose windows matter for exclusion and wallpaper (measured with lsappinfo).
public enum KnownBundleIDs {
    public static let finder = "com.apple.finder"
    /// Hosts desktop widgets.
    public static let notificationCenter = "com.apple.notificationcenterui"
    /// Draws the wallpaper on some displays (a full-display window titled "Wallpaper"), so its windows stay in captures.
    public static let windowManager = "com.apple.WindowManager"
    public static let wallpaper = "com.apple.wallpaper.agent"
}
