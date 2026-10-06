import AppKit
import CSCore

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `NSApplication.delegate` is weak, so the delegate is retained here.
    private static var retained: AppDelegate?
    private var coordinator: AppCoordinator?
    /// Files that arrived before the coordinator existed (a double-clicked project launching the app).
    private var pendingURLs: [URL] = []
    /// `clearshot://` URLs, from the start of launch (`applicationWillFinishLaunching`).
    private var receiver: URLReceiver?
    /// The app in front before a URL activated ClearShot, from the start of launch.
    private var activation: ActivationHandBack?
    /// The running copy this one hands off to: files that arrive meanwhile are forwarded to it too.
    private var handingOffTo: NSRunningApplication?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retained = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// A URL that launches ClearShot arrives before `applicationDidFinishLaunching`, so its handler goes in now.
    func applicationWillFinishLaunching(_ notification: Notification) {
        activation = ActivationHandBack()
        let receiver = URLReceiver()
        receiver.install()
        self.receiver = receiver
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let receiver, let activation else {
            preconditionFailure("AppKit calls applicationWillFinishLaunching first, which makes both")
        }
        if let running = SingleInstance.runningInstance() {
            handingOffTo = running
            receiver.onForward = { url in SingleInstance.handOff(to: running, forwarding: [url]) }
            SingleInstance.handOff(to: running, forwarding: receiver.forwardFromNowOn() + pendingURLs)
            pendingURLs = []
            return
        }
        NSApp.mainMenu = MainMenu.make()
        let coordinator = AppCoordinator(preferences: Preferences(defaults: .standard))
        self.coordinator = coordinator
        coordinator.start(activation: activation)
        Log.app.info("ClearShot \(Bundle.main.versionString) started")
        receiver.open { [weak coordinator] received in coordinator?.urlCommands?.handle(received) }
        coordinator.openFiles(pendingURLs)
        pendingURLs = []
    }

    /// Files (Open With, a double-clicked project); `clearshot://` URLs go to the receiver instead. Opening a file can
    /// arrive before launch finishes; hold it until the coordinator exists, or forward it while handing off.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let handingOffTo {
            SingleInstance.handOff(to: handingOffTo, forwarding: urls)
        } else if let coordinator {
            coordinator.openFiles(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    /// Clicking the Dock icon while editors are open (Annotate's or the Video Editor's) brings back the frontmost one,
    /// minimised or not. Otherwise, launching ClearShot again while it runs (Finder, Spotlight) opens Settings: this is
    /// how you get back to Settings when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if coordinator?.presentFrontmostEditor() == true {
            Log.app.info("Reopen requested; presenting the frontmost editor")
            return false
        }
        Log.app.info("Reopen requested; showing Settings")
        coordinator?.showSettings()
        return false
    }

    /// A recording finishes first (saved as a video, no dialogs); then Annotate gives its reply, which asks about
    /// unapplied edits, and then the Video Editor, which asks about pending changes. The replies are chained, never
    /// nested: each comes once the one before it is in.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        guard coordinator.captureFlow.isRecording else { return editorsTerminateReply(coordinator) }
        Log.app.info("Quit requested during a recording; finishing it first")
        Task {
            await coordinator.captureFlow.finishRecordingForQuit()
            switch editorsTerminateReply(coordinator) {
            case .terminateNow: NSApp.reply(toApplicationShouldTerminate: true)
            case .terminateCancel:
                NSApp.reply(toApplicationShouldTerminate: false)
                coordinator.captureFlow.quitWasCancelled()
            case .terminateLater: break // the editors reply themselves, and say when they cancel (`onQuitCancelled`)
            @unknown default: NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// Annotate's reply, which goes on to the Video Editor's once its own edits are settled.
    private func editorsTerminateReply(_ coordinator: AppCoordinator) -> NSApplication.TerminateReply {
        coordinator.annotate.terminateReply(then: { [videoEditor = coordinator.videoEditor] in videoEditor.terminateReply() })
    }

    @objc func showSettingsAction(_ sender: Any?) { coordinator?.showSettings() }
    @objc func showAboutAction(_ sender: Any?) { coordinator?.showAbout() }
}
