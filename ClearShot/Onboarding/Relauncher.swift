import AppKit
import CSCore

/// macOS often applies a new Screen Recording grant only after a restart, so this restarts ClearShot.
enum Relauncher {
    /// Starts a shell that waits for this process to exit (so the single-instance check passes) and then opens the app
    /// again (`RelaunchCommand`), and quits. False, with ClearShot still running, when the shell couldn't start; the caller
    /// says so.
    static func relaunch() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = RelaunchCommand.arguments(pid: ProcessInfo.processInfo.processIdentifier,
                                                      appPath: Bundle.main.bundleURL.path(percentEncoded: false))
        do {
            try process.run()
        } catch {
            Log.app.error("Couldn't start the restart: \(error.localizedDescription)")
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}
