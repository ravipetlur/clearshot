import AppKit
import CSCapture

/// The app and window in front when the capture started, for the %a and %t file name tokens and the history item's
/// source app.
struct FrontmostApp {
    var name: String?
    var bundleID: String?
    var windowTitle: String?
    var windowFrames: [CGRect]

    /// Nothing known: for captures that name no file after the app in front.
    static let none = FrontmostApp(name: nil, bundleID: nil, windowTitle: nil, windowFrames: [])

    static func current(windows: [WindowRecord]) -> FrontmostApp {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .none }
        let own = windows.filter { $0.ownerPID == app.processIdentifier && $0.layer == 0 }
        return FrontmostApp(name: app.localizedName, bundleID: app.bundleIdentifier, windowTitle: own.first?.title,
                            windowFrames: own.map(\.frame))
    }
}
