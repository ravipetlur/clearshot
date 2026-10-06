import Synchronization
import Testing
@testable import CSRecording

/// Do Not Disturb through the user's two Shortcuts. The real `shortcuts` command is never run here: a fake runner
/// answers from a list and records what it was asked.
struct FocusShortcutsTests {
    @Test func bothNamesAreFoundInAList() async {
        #expect(FocusShortcuts.onName == "ClearShot Focus On")
        #expect(FocusShortcuts.offName == "ClearShot Focus Off")
        let both = FocusShortcuts.areInstalled(in: ["Morning", "ClearShot Focus Off", "ClearShot Focus On"])
        #expect(both.on && both.off)
        // Exact names only: other cases and look-alikes don't count.
        let lookAlikes = FocusShortcuts.areInstalled(in: ["clearshot focus on", "ClearShot Focus On 2", "ClearShot Focus"])
        #expect(!lookAlikes.on && !lookAlikes.off)
        // Settings' check reads the list through the runner.
        let runner = FakeShortcutRunner(installed: ["ClearShot Focus On", "ClearShot Focus Off"])
        let checked = await FocusShortcuts.check(using: runner)
        #expect(checked?.on == true)
        #expect(checked?.off == true)
    }

    @Test func aMissingShortcutIsReportedAsMissing() async {
        let onlyOn = FocusShortcuts.areInstalled(in: ["ClearShot Focus On"])
        #expect(onlyOn.on && !onlyOn.off)
        // Settings' check says which one is missing, and only lists: it never runs a shortcut.
        let runner = FakeShortcutRunner(installed: ["ClearShot Focus On"])
        let checked = await FocusShortcuts.check(using: runner)
        #expect(checked?.on == true)
        #expect(checked?.off == false)
        #expect(runner.calls == ["list"])
        // Without the list (the command failed), nothing is known.
        #expect(await FocusShortcuts.check(using: FakeShortcutRunner(installed: nil)) == nil)
        // What `shortcuts run` says for a name it doesn't have (measured: "Couldn't find shortcut").
        #expect(SystemShortcutRunner.outcome(status: 1, output: "Error: Couldn't find shortcut \"ClearShot Focus On\"") == .missing)
        #expect(SystemShortcutRunner.outcome(status: 1, output: "Couldn’t find shortcut") == .missing)
        // The words count whatever the exit status says (never measured for a missing name).
        #expect(SystemShortcutRunner.outcome(status: 0, output: "Error: Couldn't find shortcut") == .missing)
        #expect(SystemShortcutRunner.outcome(status: 0, output: "") == .ran)
        #expect(SystemShortcutRunner.outcome(status: 1, output: " Error: The operation couldn’t be completed.\n")
            == .failed("Error: The operation couldn’t be completed."))
        #expect(SystemShortcutRunner.outcome(status: 3, output: "") == .failed("The shortcuts command exited with status 3."))
    }

    /// Off only after a successful On, exactly once on whichever ending comes, and the journal says Focus is on only
    /// between a successful On and the Off.
    @Test func turnOffRunsOnlyAfterASuccessfulTurnOn() async {
        // On ran: it starts once, the journal records it, the first ending runs Off and the journal lets it go.
        var ran = FocusSessionState()
        let starts = [ran.beginTurningOn(), ran.beginTurningOn()]
        #expect(starts == [true, false])
        let ranOn = ran.turnOnFinished(succeeded: true)
        #expect(ranOn == .recordInJournal)
        #expect(ran.journalSaysOn)
        let ranEndings = [ran.sessionEnded(), ran.sessionEnded()]
        #expect(ranEndings == [true, false])
        #expect(!ran.journalSaysOn)

        // On missing (the fake has no shortcuts): no ending runs Off, and the journal never says Focus is on.
        let runner = FakeShortcutRunner(installed: [])
        var missing = FocusSessionState()
        let missingStart = missing.beginTurningOn()
        let outcome = await runner.run(FocusShortcuts.onName)
        let missingOn = missing.turnOnFinished(succeeded: outcome == .ran)
        let missingEnding = missing.sessionEnded()
        #expect(missingStart && outcome == .missing && missingOn == .none && !missingEnding)
        #expect(!missing.journalSaysOn)
        #expect(runner.calls == ["run ClearShot Focus On"])

        // The session ended while On was still running: Off runs as soon as On has, and the journal is left alone.
        var late = FocusSessionState()
        let lateStart = late.beginTurningOn()
        let lateEnding = late.sessionEnded()
        let lateOn = late.turnOnFinished(succeeded: true)
        let lateSecondEnding = late.sessionEnded()
        #expect(lateStart && !lateEnding && lateOn == .turnOff && !lateSecondEnding)
        #expect(!late.journalSaysOn)

        // Ended before On started (a countdown cancelled at once): On never starts, so nothing needs Off.
        var never = FocusSessionState()
        let neverEnding = never.sessionEnded()
        let neverStart = never.beginTurningOn()
        #expect(!neverEnding && !neverStart)
    }
}

/// Answers from `installed` (nil: the command failed) and records each call, "run <name>" or "list".
private final class FakeShortcutRunner: ShortcutRunning {
    private let installed: [String]?
    private let recorded = Mutex<[String]>([])

    init(installed: [String]?) {
        self.installed = installed
    }

    var calls: [String] {
        recorded.withLock { $0 }
    }

    @concurrent func run(_ name: String) async -> ShortcutOutcome {
        recorded.withLock { $0.append("run \(name)") }
        guard let installed else { return .failed("The shortcuts command failed.") }
        return installed.contains(name) ? .ran : .missing
    }

    @concurrent func names() async -> [String]? {
        recorded.withLock { $0.append("list") }
        return installed
    }
}
