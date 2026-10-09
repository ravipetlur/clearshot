import CoreGraphics
import Foundation

public enum ImageFormat: String, CaseIterable, Sendable, Identifiable, PrefValue {
    case png, jpeg, heic, webp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .webp: "WebP"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        case .webp: "webp"
        }
    }

    public var utType: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .webp: "org.webmproject.webp"
        }
    }

    /// The format a file extension stands for, ignoring case; nil for anything ClearShot doesn't write.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "heic": self = .heic
        case "webp": self = .webp
        default: return nil
        }
    }

    /// Whether the format is lossy, so a quality setting means something: JPEG and HEIC. PNG and WebP are always lossless.
    public var supportsQuality: Bool { self != .png && self != .webp }
    public var supportsTransparency: Bool { self != .jpeg }
}

public enum CrosshairMode: String, CaseIterable, Sendable, Identifiable, PrefValue {
    case always, whileCommandHeld, off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .always: "Always enabled"
        case .whileCommandHeld: "When ⌘ Command is pressed"
        case .off: "Disabled"
        }
    }
}

public enum WindowBackgroundMode: String, CaseIterable, Sendable, Identifiable, PrefValue {
    case wallpaper, transparent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .wallpaper: "With wallpaper"
        case .transparent: "Transparent"
        }
    }
}

public enum WallpaperSource: String, CaseIterable, Sendable, Identifiable, PrefValue {
    case desktop, customImage, plainColor

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .desktop: "Desktop wallpaper"
        case .customImage: "Custom wallpaper"
        case .plainColor: "Plain color"
        }
    }
}

public enum ShutterSound: String, CaseIterable, Sendable, Identifiable, PrefValue {
    case screenCapture, grab, pop, tink, glass

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenCapture: "Screen Capture"
        case .grab: "Grab"
        case .pop: "Pop"
        case .tink: "Tink"
        case .glass: "Glass"
        }
    }

    public var fileURL: URL {
        let systemSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
        switch self {
        case .screenCapture: return URL(filePath: systemSounds + "Screen Capture.aif")
        case .grab: return URL(filePath: systemSounds + "Grab.aif")
        case .pop: return URL(filePath: "/System/Library/Sounds/Pop.aiff")
        case .tink: return URL(filePath: "/System/Library/Sounds/Tink.aiff")
        case .glass: return URL(filePath: "/System/Library/Sounds/Glass.aiff")
        }
    }
}

/// The last selected area, for Capture Previous Area. AppKit global points.
public struct SavedArea: JSONPrefValue, Equatable {
    public var rect: CGRect
    public var displayID: UInt32

    public init(rect: CGRect, displayID: UInt32) {
        self.rect = rect
        self.displayID = displayID
    }

    public static let none = SavedArea(rect: .zero, displayID: 0)
    public var isEmpty: Bool { rect.width < 1 || rect.height < 1 }

    /// The area as it can be selected now: clamped to its display, with that display. Nil when the area is empty, its
    /// display is gone, or less than `minimumSide` of it is on the display in either direction. Capture Previous Area
    /// and All-In-One's remembered selection both resolve through this.
    public func resolved(in layout: DisplayLayout, minimumSide: CGFloat = 4) -> (rect: CGRect, display: DisplayInfo)? {
        guard !isEmpty, let display = layout.display(id: displayID) else { return nil }
        let clamped = rect.standardized.intersection(display.frame)
        guard !clamped.isNull, clamped.width >= minimumSide, clamped.height >= minimumSide else { return nil }
        return (clamped, display)
    }
}

public extension Prefs {
    static let selfTimerChoices = [3, 5, 10]

    // Output (Screenshots pane)
    static let imageFormat = PrefKey("imageFormat", default: ImageFormat.jpeg)
    static let imageQuality = PrefKey("imageQuality", default: 0.9)
    static let convertToSRGB = PrefKey("convertToSRGB", default: false)
    static let scaleRetinaTo1x = PrefKey("scaleRetinaTo1x", default: false)
    static let addBorderToScreenshots = PrefKey("addBorderToScreenshots", default: true)

    // Capture
    static let showCursorInScreenshots = PrefKey("showCursorInScreenshots", default: false)
    static let selfTimerSeconds = PrefKey("selfTimerSeconds", default: 5)
    static let freezeScreen = PrefKey("freezeScreen", default: false)
    static let crosshairMode = PrefKey("crosshairMode", default: CrosshairMode.whileCommandHeld)
    static let showMagnifier = PrefKey("showMagnifier", default: true)
    static let dimScreenWhileSelecting = PrefKey("dimScreenWhileSelecting", default: true)
    static let fullscreenCapturesAllDisplays = PrefKey("fullscreenCapturesAllDisplays", default: false)
    static let captureAreaShortcutsIgnoreAfterCapture = PrefKey("captureAreaShortcutsIgnoreAfterCapture", default: true)
    static let lastCaptureArea = PrefKey("lastCaptureArea", default: SavedArea.none)

    // All-In-One. The last area is written on every area command, whatever the setting; it is only read while the
    // setting is on.
    static let allInOneRememberSelection = PrefKey("allInOneRememberSelection", default: true)
    static let allInOneLastArea = PrefKey("allInOneLastArea", default: SavedArea.none)

    // Scrolling capture: the tips open over the first scrolling capture's overlay; closing them sets this.
    static let scrollingTipsShown = PrefKey("scrollingTipsShown", default: false)

    // Window screenshots
    static let windowBackground = PrefKey("windowBackground", default: WindowBackgroundMode.transparent)
    static let windowPadding = PrefKey("windowPadding", default: 48)
    static let captureWindowShadow = PrefKey("captureWindowShadow", default: true)

    // Wallpaper pane
    static let wallpaperSource = PrefKey("wallpaperSource", default: WallpaperSource.desktop)
    static let customWallpaperPath = PrefKey("customWallpaperPath", default: "")
    static let wallpaperPlainColor = PrefKey("wallpaperPlainColor", default: "#1E1E1E")
    static let updateWallpaperOnSpaceChange = PrefKey("updateWallpaperOnSpaceChange", default: true)

    // Sounds (General pane)
    static let shutterSound = PrefKey("shutterSound", default: ShutterSound.screenCapture)
}
