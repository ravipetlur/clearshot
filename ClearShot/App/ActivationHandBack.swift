import AppKit
import CSAPI
import CSCore

/// Opening a URL activates ClearShot, so a command that captures or selects on screen would see the app that sent it
/// inactive: a window shot with grey traffic lights. Before such a command the activation goes back to the app that had
/// it; commands that open ClearShot's own windows keep it (`APICommand.keepsActivation`). So does a command that is
/// dropped or refused, which leaves nothing of ClearShot's on screen.
final class ActivationHandBack {
    /// The last app other than ClearShot to become active.
    private(set) var lastOtherApp: NSRunningApplication?
    /// When ClearShot last became active; nil while it isn't. A URL that arrives about then, or before, is what activated
    /// it (`URLActivation.handsBack`).
    private var activeSince: Date?
    private var observers: [any NSObjectProtocol] = []

    /// In `applicationWillFinishLaunching`, so a URL that launches ClearShot finds the app that was in front.
    init() {
        if let front = NSWorkspace.shared.frontmostApplication, !Self.isClearShot(front) {
            lastOtherApp = front
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated {
                guard let pid, let app = NSRunningApplication(processIdentifier: pid), !Self.isClearShot(app) else { return }
                self?.lastOtherApp = app
            }
        })
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSince = Date() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSince = nil }
        })
    }

    /// When ClearShot is active only because of the URL that arrived at `receivedAt` (`URLActivation.handsBack`: no key
    /// window of its own, or a document window it became key in as the URL arrived or since; never a key panel such as
    /// the capture overlay), hands the activation back to the last other
    /// app, if it still runs, then lets it settle. Checked again a settle later, just before the command starts:
    /// LaunchServices may activate ClearShot a moment after it delivered the URL.
    func yieldIfNeeded(since receivedAt: Date) async {
        handBackIfNeeded(since: receivedAt)
        await Self.settle()
        if handBackIfNeeded(since: receivedAt) {
            await Self.settle()
        }
    }

    /// ClearShot's key window as the rule sees it: a panel that takes keys without activating ClearShot (the overlay,
    /// its toolbar, the countdown, a pin, a thumbnail) is never one the URL made key.
    private static var keyWindow: URLActivation.KeyWindow {
        guard let window = NSApp.keyWindow else { return .none }
        return window.styleMask.contains(.nonactivatingPanel) ? .panel : .document
    }

    /// True when it handed the activation back.
    @discardableResult
    private func handBackIfNeeded(since receivedAt: Date) -> Bool {
        guard URLActivation.handsBack(isActive: NSApp.isActive, keyWindow: Self.keyWindow,
                                      activeSince: activeSince, receivedAt: receivedAt),
              let app = lastOtherApp, !app.isTerminated else { return false }
        NSApp.yieldActivation(to: app)
        if !app.activate(from: .current) {
            Log.api.warning("Couldn't hand the activation back to \(app.localizedName ?? "the previous app")")
        }
        return true
    }

    /// One run-loop turn and 40 ms, the overlay's own wait (`CaptureFlow.capturePickedArea`).
    private static func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// Any ClearShot: this copy, or another that shares the bundle ID.
    private static func isClearShot(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == getpid() || app.bundleIdentifier == CSCore.bundleIdentifier
    }
}
