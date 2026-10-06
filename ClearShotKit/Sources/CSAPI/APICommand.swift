import Foundation

/// What a screenshot command does after the capture (`action=`), instead of the After Capture settings. `upload` is
/// refused: ClearShot doesn't upload. The app maps these onto its own `CaptureOverride`.
public enum APIAction: String, Sendable, CaseIterable {
    case copy, save, annotate, pin
}

/// How Scrolling Capture starts on a given area.
public enum APIScrollStart: Sendable, Equatable {
    /// Ready on the area; the person starts it.
    case none
    /// Capturing at once; the person scrolls.
    case manual
    /// Capturing at once with Auto-Scroll.
    case autoScroll
}

/// Where Capture Text reads from.
public enum APITextSource: Sendable, Equatable {
    /// The selection overlay.
    case overlay
    /// That area of the screen, at once.
    case area(APIArea)
    /// That image file, as given (`APIFiles.validate` checks it).
    case file(String)
}

/// The Settings tab names `tab=` takes. The app maps them onto its own panes; `cloud` has none.
public enum APISettingsTab: String, Sendable, CaseIterable {
    case general, wallpaper, shortcuts, quickaccess, recording, screenshots, annotate, cloud, advanced, about
}

/// One `clearshot://` command with its parameters, checked for syntax and types (`APIRequest.parse`). Areas and files
/// are checked against the screen and the disk when the command runs (`APIArea.resolve`, `APIFiles.validate`).
public enum APICommand: Sendable, Equatable {
    case allInOne(APIArea?)
    case captureArea(APIArea?, action: APIAction?)
    /// `capture-area-raycast-aichat`: Capture Area & Send to Raycast. Takes an area like capture-area, no action.
    case captureAreaForRaycast(APIArea?)
    case capturePreviousArea(action: APIAction?), captureFullscreen(action: APIAction?)
    case captureWindow(action: APIAction?), selfTimer(action: APIAction?)
    /// `start` is always `.none` without an area: Ready needs a region.
    case scrollingCapture(APIArea?, start: APIScrollStart)
    case recordScreen(APIArea?)
    /// `keepLineBreaks` nil: the Keep line breaks setting.
    case captureText(APITextSource, keepLineBreaks: Bool?)
    case pin(filePath: String?), openAnnotate(filePath: String?), openFromClipboard
    case addQuickAccessOverlay(filePath: String)
    case openHistory, restoreRecentlyClosed, openSettings(APISettingsTab?)
    /// `debug-selftest` exists only where the app allows debug commands (Debug builds).
    case toggleDesktopIcons, hideDesktopIcons, showDesktopIcons, debugSelfTest

    /// The URL's command name, as in `clearshot://capture-area`.
    public var name: String {
        switch self {
        case .allInOne: "all-in-one"
        case .captureArea: "capture-area"
        case .captureAreaForRaycast: "capture-area-raycast-aichat"
        case .capturePreviousArea: "capture-previous-area"
        case .captureFullscreen: "capture-fullscreen"
        case .captureWindow: "capture-window"
        case .selfTimer: "self-timer"
        case .scrollingCapture: "scrolling-capture"
        case .recordScreen: "record-screen"
        case .captureText: "capture-text"
        case .pin: "pin"
        case .openAnnotate: "open-annotate"
        case .openFromClipboard: "open-from-clipboard"
        case .addQuickAccessOverlay: "add-quick-access-overlay"
        case .openHistory: "open-history"
        case .restoreRecentlyClosed: "restore-recently-closed"
        case .openSettings: "open-settings"
        case .toggleDesktopIcons: "toggle-desktop-icons"
        case .hideDesktopIcons: "hide-desktop-icons"
        case .showDesktopIcons: "show-desktop-icons"
        case .debugSelfTest: "debug-selftest"
        }
    }

    /// Whether the command takes the picture with no on-screen choice by the person, so the app shows the "is capturing
    /// your screen" notice. Commands that open an overlay are their own notice. Every case is listed, so a new command
    /// doesn't compile until this is decided for it.
    public var capturesWithoutChoice: Bool {
        switch self {
        case let .captureArea(area, _), let .captureAreaForRaycast(area): area != nil
        case .captureText(.area, _), .capturePreviousArea, .captureFullscreen: true
        case let .scrollingCapture(area, start): area != nil && start != .none
        case .captureText(.overlay, _), .captureText(.file, _), .allInOne, .captureWindow, .selfTimer, .recordScreen,
             .pin, .openAnnotate, .openFromClipboard, .addQuickAccessOverlay, .openHistory, .restoreRecentlyClosed,
             .openSettings, .toggleDesktopIcons, .hideDesktopIcons, .showDesktopIcons, .debugSelfTest:
            false
        }
    }

    /// What the app checks before the command runs: the area it gives, against the screen (`APIArea.resolve`), and the
    /// file it gives with what that must be, on the disk (`APIFiles.validate`). Every case is listed, so a new command
    /// doesn't compile until this is decided for it.
    public var checks: (area: APIArea?, file: (path: String, kind: APIFileKind)?) {
        switch self {
        case let .allInOne(area), let .captureArea(area, _), let .captureAreaForRaycast(area),
             let .scrollingCapture(area, _), let .recordScreen(area):
            (area, nil)
        case let .captureText(.area(area), _): (area, nil)
        case let .captureText(.file(path), _): (nil, (path, .image))
        case let .pin(path): (nil, path.map { ($0, .image) })
        case let .openAnnotate(path): (nil, path.map { ($0, .imageOrProject) })
        case let .addQuickAccessOverlay(path): (nil, (path, .imageOrMovie))
        case .captureText(.overlay, _), .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer,
             .openFromClipboard, .openHistory, .restoreRecentlyClosed, .openSettings, .toggleDesktopIcons,
             .hideDesktopIcons, .showDesktopIcons, .debugSelfTest:
            (nil, nil)
        }
    }

    /// Whether the command keeps the activation the URL gave ClearShot, because it opens a ClearShot window or a
    /// chooser. Every other command hands the activation back first. Every case is listed, so a new command doesn't
    /// compile until this is decided for it.
    public var keepsActivation: Bool {
        switch self {
        case .openSettings, .openHistory, .openAnnotate, .pin, .openFromClipboard: true
        case .allInOne, .captureArea, .captureAreaForRaycast, .capturePreviousArea, .captureFullscreen, .captureWindow,
             .selfTimer, .scrollingCapture, .recordScreen, .captureText, .addQuickAccessOverlay, .restoreRecentlyClosed,
             .toggleDesktopIcons, .hideDesktopIcons, .showDesktopIcons, .debugSelfTest:
            false
        }
    }
}
