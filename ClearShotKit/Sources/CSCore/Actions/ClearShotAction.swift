import Foundation

/// Sections of the Shortcuts settings pane.
public enum ActionGroup: String, CaseIterable, Sendable, Identifiable {
    case general, screenshots, screenRecording, scrollingCapture, textRecognition, quickAccess, pin

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .screenshots: "Screenshots"
        case .screenRecording: "Screen Recording"
        case .scrollingCapture: "Scrolling Capture"
        case .textRecognition: "Text Recognition"
        case .quickAccess: "Quick Access Overlay"
        case .pin: "Pin"
        }
    }
}

/// Every action that can have a global hotkey. Raw values are the persisted shortcut names.
public enum ClearShotAction: String, CaseIterable, Sendable, Identifiable {
    // Screenshots
    case allInOne, captureArea, capturePreviousArea, captureFullscreen, captureWindow, selfTimer
    case captureAreaAndAnnotate, captureAreaAndCopy, captureAreaAndSave, captureAreaAndPin, captureAreaAndSendToRaycast
    // General
    case openFile, openFromClipboard, annotateLastScreenshot, openCaptureHistory, restoreLastCapture, toggleDesktopIcons
    // Quick Access Overlay
    case toggleOverlaysVisibility, closeAllOverlays, saveAllOverlays
    // Screen Recording
    case recordScreen, recordWindow, pauseResumeRecording, restartRecording
    // Scrolling Capture
    case scrollingCapture, startStopScrollingCapture
    // Text Recognition
    case captureText, captureTextWithLineBreaks, captureTextWithoutLineBreaks
    // Pin
    case chooseAndPinImage, pinLastScreenshot, togglePinsVisibility, closeAllPins

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .allInOne: "All-In-One"
        case .captureArea: "Capture Area"
        case .capturePreviousArea: "Capture Previous Area"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureWindow: "Capture Window"
        case .selfTimer: "Self-Timer"
        case .captureAreaAndAnnotate: "Capture Area & Annotate"
        case .captureAreaAndCopy: "Capture Area & Copy to Clipboard"
        case .captureAreaAndSave: "Capture Area & Save"
        case .captureAreaAndPin: "Capture Area & Pin to the Screen"
        case .captureAreaAndSendToRaycast: "Capture Area & Send to Raycast AI Chat"
        case .openFile: "Open File"
        case .openFromClipboard: "Open from Clipboard"
        case .annotateLastScreenshot: "Annotate Last Screenshot"
        case .openCaptureHistory: "Open Capture History"
        case .restoreLastCapture: "Restore Last Capture"
        case .toggleDesktopIcons: "Toggle Desktop Icons"
        case .toggleOverlaysVisibility: "Hide/Show Overlays"
        case .closeAllOverlays: "Close All Overlays"
        case .saveAllOverlays: "Save All Overlays"
        case .recordScreen: "Record Screen / Stop Recording"
        case .recordWindow: "Record Window"
        case .pauseResumeRecording: "Pause/Resume Recording"
        case .restartRecording: "Restart Recording"
        case .scrollingCapture: "Scrolling Capture"
        case .startStopScrollingCapture: "Start/Stop Capturing"
        case .captureText: "Capture Text"
        case .captureTextWithLineBreaks: "Capture Text With Line Breaks"
        case .captureTextWithoutLineBreaks: "Capture Text Without Line Breaks"
        case .chooseAndPinImage: "Choose and Pin an Image"
        case .pinLastScreenshot: "Pin Last Screenshot"
        case .togglePinsVisibility: "Toggle Pins Visibility"
        case .closeAllPins: "Close All Pins"
        }
    }

    /// The status menu's wording, where it differs from the Shortcuts pane.
    public var menuTitle: String {
        switch self {
        case .captureText: "Capture Text (OCR)"
        case .recordScreen: "Record Screen"
        case .openFile: "Open…"
        case .chooseAndPinImage: "Pin to the Screen…"
        case .openCaptureHistory: "Capture History…"
        case .toggleDesktopIcons: "Hide Desktop Icons"
        default: title
        }
    }

    /// The status menu's wording now: the desktop-icons item says what choosing it will do.
    public func menuTitle(desktopIconsHidden: Bool) -> String {
        guard self == .toggleDesktopIcons else { return menuTitle }
        return desktopIconsHidden ? "Show Desktop Icons" : "Hide Desktop Icons"
    }

    public var group: ActionGroup {
        switch self {
        case .allInOne, .captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer,
             .captureAreaAndAnnotate, .captureAreaAndCopy, .captureAreaAndSave, .captureAreaAndPin, .captureAreaAndSendToRaycast:
            .screenshots
        case .openFile, .openFromClipboard, .annotateLastScreenshot, .openCaptureHistory, .restoreLastCapture, .toggleDesktopIcons:
            .general
        case .toggleOverlaysVisibility, .closeAllOverlays, .saveAllOverlays:
            .quickAccess
        case .recordScreen, .recordWindow, .pauseResumeRecording, .restartRecording:
            .screenRecording
        case .scrollingCapture, .startStopScrollingCapture:
            .scrollingCapture
        case .captureText, .captureTextWithLineBreaks, .captureTextWithoutLineBreaks:
            .textRecognition
        case .chooseAndPinImage, .pinLastScreenshot, .togglePinsVisibility, .closeAllPins:
            .pin
        }
    }

    /// Extra search words for the Shortcuts pane.
    public var keywords: [String] {
        switch self {
        case .allInOne: ["mode", "picker", "everything"]
        case .captureArea: ["region", "selection", "screenshot"]
        case .capturePreviousArea: ["repeat", "last", "again"]
        case .captureFullscreen: ["screen", "display", "whole"]
        case .captureWindow: ["app", "window"]
        case .selfTimer: ["delay", "timer", "countdown"]
        case .captureAreaAndAnnotate: ["edit", "markup", "draw"]
        case .captureAreaAndCopy: ["clipboard"]
        case .captureAreaAndSave: ["file", "export"]
        case .captureAreaAndPin: ["float", "sticky"]
        case .captureAreaAndSendToRaycast: ["ai", "chat", "raycast"]
        case .openFile: ["open", "image", "video"]
        case .openFromClipboard: ["paste"]
        case .annotateLastScreenshot: ["edit", "markup", "recent"]
        case .openCaptureHistory: ["recent", "history"]
        case .restoreLastCapture: ["undo", "recover", "recent"]
        case .toggleDesktopIcons: ["desktop", "icons", "hide", "clean"]
        case .toggleOverlaysVisibility: ["thumbnail", "hide", "overlay"]
        case .closeAllOverlays: ["thumbnail", "dismiss"]
        case .saveAllOverlays: ["thumbnail", "export"]
        case .recordScreen: ["video", "gif", "record", "stop"]
        case .recordWindow: ["video", "window", "record"]
        case .pauseResumeRecording: ["pause", "resume"]
        case .restartRecording: ["again", "restart"]
        case .scrollingCapture: ["long", "page", "scroll", "full page"]
        case .startStopScrollingCapture: ["scroll", "start", "stop", "done"]
        case .captureText, .captureTextWithLineBreaks, .captureTextWithoutLineBreaks: ["ocr", "text", "recognize"]
        case .chooseAndPinImage, .pinLastScreenshot: ["float", "pin"]
        case .togglePinsVisibility, .closeAllPins: ["float", "pin", "hide"]
        }
    }

    public var symbolName: String {
        switch self {
        case .allInOne: "square.grid.2x2"
        case .captureArea, .captureAreaAndAnnotate, .captureAreaAndCopy, .captureAreaAndSave,
             .captureAreaAndPin, .captureAreaAndSendToRaycast: "rectangle.dashed"
        case .capturePreviousArea: "arrow.counterclockwise"
        case .captureFullscreen: "display"
        case .captureWindow, .recordWindow: "macwindow"
        case .selfTimer: "timer"
        case .openFile: "folder"
        case .openFromClipboard: "doc.on.clipboard"
        case .annotateLastScreenshot: "pencil.tip.crop.circle"
        case .openCaptureHistory, .restoreLastCapture: "clock.arrow.circlepath"
        case .toggleDesktopIcons: "menubar.dock.rectangle"
        case .toggleOverlaysVisibility, .closeAllOverlays, .saveAllOverlays: "square.stack"
        case .recordScreen, .pauseResumeRecording, .restartRecording: "record.circle"
        case .scrollingCapture, .startStopScrollingCapture: "arrow.up.and.down.text.horizontal"
        case .captureText, .captureTextWithLineBreaks, .captureTextWithoutLineBreaks: "text.viewfinder"
        case .chooseAndPinImage, .pinLastScreenshot, .togglePinsVisibility, .closeAllPins: "pin"
        }
    }

    /// ⇧⌘3 (Fullscreen), ⇧⌘4 (Capture Area) and ⇧⌘5 (All-In-One); everything else starts unassigned.
    public var defaultShortcut: ShortcutSpec? {
        switch self {
        case .captureFullscreen: .commandShift(KeyCode.digit3)
        case .captureArea: .commandShift(KeyCode.digit4)
        case .allInOne: .commandShift(KeyCode.digit5)
        default: nil
        }
    }

    /// Case-insensitive search over title, keywords and group title. A blank query returns everything.
    public static func matching(_ query: String) -> [ClearShotAction] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return allCases }
        return allCases.filter { action in
            action.title.lowercased().contains(needle)
                || action.keywords.contains { $0.contains(needle) }
                || action.group.title.lowercased().contains(needle)
        }
    }
}
