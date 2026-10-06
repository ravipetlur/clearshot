import AppKit
import CSCore

enum SingleInstance {
    /// Deliveries to the running copy still on their way; this copy quits once none is left.
    private static var deliveries = 0
    private static var isHandingOff = false

    /// Another ClearShot already running, which this copy hands off to rather than starting. The Debug build and
    /// /Applications share the bundle ID.
    static func runningInstance() -> NSRunningApplication? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: CSCore.bundleIdentifier)
        let running = apps.map { RunningInstance(pid: $0.processIdentifier, isTerminated: $0.isTerminated) }
        guard let target = SingleInstancePolicy.instanceToHandOffTo(running: running, currentPID: getpid()) else {
            return nil
        }
        return apps.first { $0.processIdentifier == target.pid && $0.bundleURL != nil }
    }

    /// Hands `urls` to `running`, then quits this copy once they are delivered (3 s at most). `clearshot://` URLs and
    /// files (Open With) go to that copy's own bundle, never by bundle ID, which both copies share, and without
    /// activating it. With nothing to forward the running copy is reopened, which shows Settings (or an open editor).
    /// Called again for URLs and files that arrive while handing off: this copy waits for those too.
    static func handOff(to running: NSRunningApplication, forwarding urls: [URL]) {
        let isFirst = !isHandingOff
        if isFirst {
            isHandingOff = true
            Log.app.warning("Another ClearShot is running (pid \(running.processIdentifier)); handing off and quitting.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        }
        // The quit is armed first, so this copy never stays without starting.
        guard let appURL = running.bundleURL else {
            Log.app.error("The running ClearShot has no bundle URL; \(urls.count) URLs or files weren't forwarded")
            return
        }
        // The requests are asynchronous, so quit only once LaunchServices has delivered them.
        guard !urls.isEmpty else {
            if isFirst {
                deliveries += 1
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { Log.app.error("Hand-off failed: \(error.localizedDescription)") }
                    DispatchQueue.main.async { delivered() }
                }
            }
            return
        }
        Log.app.info("Forwarding \(urls.count) URLs or files to the running ClearShot")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // Commands and files apart: each kind reaches the running copy as its own Apple event.
        for batch in [urls.filter { !$0.isFileURL }, urls.filter(\.isFileURL)] where !batch.isEmpty {
            deliveries += 1
            NSWorkspace.shared.open(batch, withApplicationAt: appURL, configuration: configuration) { _, error in
                if let error {
                    Log.app.error("Couldn't forward \(batch.count) URLs or files to the running ClearShot: \(error.localizedDescription)")
                }
                DispatchQueue.main.async { delivered() }
            }
        }
    }

    private static func delivered() {
        deliveries -= 1
        if deliveries == 0 { NSApp.terminate(nil) }
    }
}
