import CoreGraphics
import CSCore
import Foundation
import ScreenCaptureKit

public struct DisplaySnapshot: Sendable {
    public let display: DisplayInfo
    public let image: CGImage

    public init(display: DisplayInfo, image: CGImage) {
        self.display = display
        self.image = image
    }
}

extension WindowRecord {
    init(_ window: SCWindow) {
        self.init(id: window.windowID, frame: window.frame, layer: window.windowLayer,
                  ownerPID: window.owningApplication?.processID ?? 0,
                  ownerName: window.owningApplication?.applicationName ?? "",
                  ownerBundleID: window.owningApplication?.bundleIdentifier,
                  title: window.title, alpha: 1, isOnScreen: window.isOnScreen)
    }
}

/// The only code that talks to ScreenCaptureKit. Every call checks Screen Recording permission first.
public final class ScreenCaptureService: Sendable {
    public init() {}

    /// One full-display image per display, without the windows `rules` exclude. Taken before the overlay
    /// appears, so it's what Freeze shows and what the magnifier samples.
    public func snapshot(displays: [DisplayInfo], rules: ExclusionRules, showsCursor: Bool) async throws -> [DisplaySnapshot] {
        let content = try await Self.content()
        var snapshots: [DisplaySnapshot] = []
        for display in displays {
            let image = try await Self.capture(display: display, content: content, rules: rules, sourceRect: nil, showsCursor: showsCursor)
            snapshots.append(DisplaySnapshot(display: display, image: image))
        }
        return snapshots
    }

    /// `localRect` is in points relative to the display's top-left corner.
    public func captureArea(_ localRect: CGRect, on display: DisplayInfo, rules: ExclusionRules, showsCursor: Bool) async throws -> CGImage {
        let content = try await Self.content()
        return try await Self.capture(display: display, content: content, rules: rules, sourceRect: localRect, showsCursor: showsCursor)
    }

    public func captureDisplay(_ display: DisplayInfo, rules: ExclusionRules, showsCursor: Bool) async throws -> CGImage {
        let content = try await Self.content()
        return try await Self.capture(display: display, content: content, rules: rules, sourceRect: nil, showsCursor: showsCursor)
    }

    /// The window alone, with real transparency around it; the shadow is optional.
    public func captureWindow(id: UInt32, includeShadow: Bool) async throws -> CGImage {
        let content = try await Self.content()
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowNotFound }
        return try await Self.captureSingleWindow(window, includeShadow: includeShadow)
    }

    /// The desktop picture as macOS draws it on the display (dynamic and per-Space wallpapers included),
    /// or nil when no wallpaper window matches. On some displays WindowManager draws the wallpaper (a window
    /// titled "Wallpaper") and the wallpaper agent's window is off-screen, so WindowManager's window is preferred.
    public func captureWallpaper(displayCGFrame: CGRect) async throws -> CGImage? {
        let content = try await Self.content()
        let onScreen = content.windows.filter(\.isOnScreen)
        let windowManager = onScreen.filter {
            $0.owningApplication?.bundleIdentifier == KnownBundleIDs.windowManager && $0.title == "Wallpaper"
        }
        let agent = onScreen.filter { $0.owningApplication?.bundleIdentifier == KnownBundleIDs.wallpaper }
        let candidates = windowManager + agent
        let match = candidates.first { $0.frame.equalTo(displayCGFrame) }
            ?? candidates.first { $0.frame.size == displayCGFrame.size }
        guard let match else { return nil }
        return try await Self.captureSingleWindow(match, includeShadow: false)
    }

    // MARK: Private

    private static func content() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw map(error)
        }
    }

    private static func capture(display: DisplayInfo, content: SCShareableContent, rules: ExclusionRules,
                                sourceRect: CGRect?, showsCursor: Bool) async throws -> CGImage {
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else { throw CaptureError.displayNotFound }
        let excluded = content.windows.filter { rules.shouldExclude(WindowRecord($0)) }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
        let rect = sourceRect ?? CGRect(origin: .zero, size: display.frame.size)
        let configuration = SCScreenshotConfiguration()
        configuration.sourceRect = rect
        configuration.width = max(1, Int((rect.width * display.scale).rounded()))
        configuration.height = max(1, Int((rect.height * display.scale).rounded()))
        configuration.showsCursor = showsCursor
        return try await screenshot(filter: filter, configuration: configuration)
    }

    private static func captureSingleWindow(_ window: SCWindow, includeShadow: Bool) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        // Width and height stay at ScreenCaptureKit's default (the captured content, 1:1 in pixels). Setting them from
        // `filter.contentRect` would squeeze a shadow-inclusive capture into the window's own size.
        let configuration = SCScreenshotConfiguration()
        configuration.ignoreShadows = !includeShadow
        configuration.includeChildWindows = true
        configuration.showsCursor = false
        return try await screenshot(filter: filter, configuration: configuration)
    }

    private static func screenshot(filter: SCContentFilter, configuration: SCScreenshotConfiguration) async throws -> CGImage {
        do {
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
            guard let image = output.sdrImage else { throw CaptureError.captureFailed("macOS returned no image.") }
            return image
        } catch let error as CaptureError {
            throw error
        } catch {
            throw map(error)
        }
    }

    static func map(_ error: Error) -> CaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .permissionDenied
        }
        return .captureFailed(nsError.localizedDescription)
    }
}
