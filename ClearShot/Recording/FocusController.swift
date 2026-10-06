import CSCore
import CSRecording

/// Do Not Disturb while recording through the user's two Shortcuts, "ClearShot Focus On" and "ClearShot Focus Off"
/// (`FocusShortcuts`): macOS has no public way to set Focus. The shortcuts run off the main actor
/// (`ShortcutRunning.run` is `@concurrent`): 0.15 s to find one missing, seconds when Focus changes, so nothing waits
/// on them before the recording shows, and a recording's Off runs in the background, which only a quit waits for
/// (`waitForSwitches`). A missing shortcut never blocks a recording: it is logged once per launch, and the HUD says so
/// once per launch after the recording (`showMissingShortcutsIfNeeded`). One controller serves every recording, launch
/// recovery and Settings' check; each recording keeps its own `FocusSessionState`.
final class FocusController {
    private let runner: any ShortcutRunning
    private let hud: HUDController
    /// A shortcut was missing this launch, and whether that has been logged and shown.
    private var foundMissing = false
    private var loggedMissing = false
    private var shownMissing = false
    /// The latest Off nobody waits for (`turnOffInBackground`), which quitting waits for.
    private var pendingOff: Task<Void, Never>?
    /// Shortcuts running now, On or Off.
    private var running = 0

    init(runner: any ShortcutRunning, hud: HUDController) {
        self.runner = runner
        self.hud = hud
    }

    /// The runner, for Settings' check of the two shortcuts (it only lists them).
    var shortcuts: any ShortcutRunning {
        runner
    }

    /// Runs "ClearShot Focus On"; true when it ran.
    func turnOn() async -> Bool {
        await run(FocusShortcuts.onName)
    }

    /// Runs "ClearShot Focus Off".
    func turnOff() async {
        await run(FocusShortcuts.offName)
    }

    /// Runs "ClearShot Focus Off" without the caller waiting (a recording's ending); each waits for the one before.
    func turnOffInBackground() {
        let previous = pendingOff
        pendingOff = Task {
            await previous?.value
            await turnOff()
        }
    }

    /// Returns once no shortcut is running and the Offs started in the background have finished: quitting waits, so
    /// Focus isn't left on (an On still running queues its Off as it finishes). Each run stops at the runner's limit.
    func waitForSwitches() async {
        while running > 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await pendingOff?.value
    }

    /// After a recording, once its windows have gone: the HUD that the shortcuts are missing, the first time this launch
    /// found one missing.
    func showMissingShortcutsIfNeeded() {
        guard foundMissing, !shownMissing else { return }
        shownMissing = true
        hud.show("Do Not Disturb shortcuts are missing; see Settings › Screen Recording", symbol: "moon")
    }

    @discardableResult
    private func run(_ name: String) async -> Bool {
        running += 1
        let outcome = await runner.run(name)
        running -= 1
        switch outcome {
        case .ran:
            Log.recording.info("Ran the shortcut \"\(name)\"")
            return true
        case .missing:
            foundMissing = true
            if !loggedMissing {
                loggedMissing = true
                Log.recording.warning("The shortcut \"\(name)\" is missing; Do Not Disturb isn't switched while recording "
                    + "(see Settings › Screen Recording)")
            }
            return false
        case .failed(let message):
            Log.recording.error("The shortcut \"\(name)\" failed: \(message)")
            return false
        }
    }
}
