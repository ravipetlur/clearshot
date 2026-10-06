import CoreGraphics
import CSAPI
import CSCore
import Foundation

/// Copied from CSCoreTests (`DisplayLayoutTests.swift`), which another test target can't see.
extension DisplayLayout {
    /// Two displays, as NSScreen and CGDisplayBounds report them: the main display, 3360×1890 pt @2x, and a second
    /// display in portrait, 1800×3200 pt @2x, placed left of and below the main display. Its CGDisplayBounds is
    /// (-1800, -491, 1800, 3200).
    static let twoDisplaysWithPortraitSecondary = DisplayLayout(displays: [
        DisplayInfo(id: 3, name: "Main Display", frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
                    scale: 2, isBuiltIn: false, safeAreaTop: 0),
        DisplayInfo(id: 2, name: "Portrait Display", frame: CGRect(x: -1800, y: -819, width: 1800, height: 3200),
                    scale: 2, isBuiltIn: false, safeAreaTop: 0),
    ])

    /// The same displays with the portrait display unplugged.
    static let mainOnly = DisplayLayout(displays: [
        DisplayInfo(id: 3, name: "Main Display", frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
                    scale: 2, isBuiltIn: false, safeAreaTop: 0),
    ])
}

/// A `clearshot://` URL from a literal the tests spell out.
func api(_ string: String) -> URL {
    URL(string: string)!
}

/// The documented example area, `x=100&y=120&width=200&height=150&display=1`.
let areaA = APIArea(rect: CGRect(x: 100, y: 120, width: 200, height: 150), display: 1)
/// The same rect as query parameters, without a display.
let rectQuery = "x=100&y=120&width=200&height=150"

/// One value of every `APICommand` case, with its required parameters.
let everyCommand: [APICommand] = [
    .allInOne(nil), .captureArea(nil, action: nil), .captureAreaForRaycast(nil), .capturePreviousArea(action: nil),
    .captureFullscreen(action: nil), .captureWindow(action: nil), .selfTimer(action: nil),
    .scrollingCapture(nil, start: .none), .recordScreen(nil), .captureText(.overlay, keepLineBreaks: nil),
    .pin(filePath: nil), .openAnnotate(filePath: nil), .openFromClipboard, .addQuickAccessOverlay(filePath: "/tmp/a.png"),
    .openHistory, .restoreRecentlyClosed, .openSettings(nil), .toggleDesktopIcons, .hideDesktopIcons,
    .showDesktopIcons, .debugSelfTest,
]

/// `APICommand`'s cases without their values. `kind(of:)` switches over every case with no default, so a new command
/// won't compile until it has a kind here; `allCases` then counts it, and the tests that check they cover every kind
/// fail until they list it.
enum CommandKind: CaseIterable {
    case allInOne, captureArea, captureAreaForRaycast, capturePreviousArea, captureFullscreen, captureWindow, selfTimer
    case scrollingCapture, recordScreen, captureText, pin, openAnnotate, openFromClipboard, addQuickAccessOverlay
    case openHistory, restoreRecentlyClosed, openSettings, toggleDesktopIcons, hideDesktopIcons, showDesktopIcons
    case debugSelfTest
}

func kind(of command: APICommand) -> CommandKind {
    switch command {
    case .allInOne: .allInOne
    case .captureArea: .captureArea
    case .captureAreaForRaycast: .captureAreaForRaycast
    case .capturePreviousArea: .capturePreviousArea
    case .captureFullscreen: .captureFullscreen
    case .captureWindow: .captureWindow
    case .selfTimer: .selfTimer
    case .scrollingCapture: .scrollingCapture
    case .recordScreen: .recordScreen
    case .captureText: .captureText
    case .pin: .pin
    case .openAnnotate: .openAnnotate
    case .openFromClipboard: .openFromClipboard
    case .addQuickAccessOverlay: .addQuickAccessOverlay
    case .openHistory: .openHistory
    case .restoreRecentlyClosed: .restoreRecentlyClosed
    case .openSettings: .openSettings
    case .toggleDesktopIcons: .toggleDesktopIcons
    case .hideDesktopIcons: .hideDesktopIcons
    case .showDesktopIcons: .showDesktopIcons
    case .debugSelfTest: .debugSelfTest
    }
}
