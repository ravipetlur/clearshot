import CoreGraphics
import CSCapture
import Foundation
import Testing
@testable import CSRecording

struct RecoveryPlannerTests {
    let hours: TimeInterval = 3_600
    let days: TimeInterval = 86_400

    func journal(focusTurnedOn: Bool = false) -> RecordingJournal {
        RecordingJournal(startedAt: Date(timeIntervalSinceReferenceDate: 812_000_000), mode: .video,
                         framesPerSecond: 60, pixelWidth: 3360, pixelHeight: 1890, scale: 1, displayID: 1,
                         globalRect: CGRect(x: 0, y: 0, width: 3360, height: 1890), captureKind: .display,
                         systemAudio: true, microphone: false, focusTurnedOn: focusTurnedOn)
    }

    func folder(_ name: String) -> URL {
        URL(filePath: "/tmp/Recordings/\(name)", directoryHint: .isDirectory)
    }

    @Test func everyJournalAndFileStateMapsToItsAction() {
        let playable = RecoveryCandidate(folder: folder("a"), journal: journal(), playableDuration: 3, age: 2 * hours)
        let tooShort = RecoveryCandidate(folder: folder("b"), journal: journal(), playableDuration: 0.3, age: 2 * hours)
        let halfSecond = RecoveryCandidate(folder: folder("c"), journal: journal(), playableDuration: 0.5, age: 2 * hours)
        let unreadableRecent = RecoveryCandidate(folder: folder("d"), journal: journal(), playableDuration: nil, age: 2 * hours)
        let unreadableOld = RecoveryCandidate(folder: folder("e"), journal: journal(), playableDuration: nil, age: 2 * days)
        let noJournalRecent = RecoveryCandidate(folder: folder("f"), journal: nil, playableDuration: 3, age: 2 * hours)
        let noJournalOld = RecoveryCandidate(folder: folder("g"), journal: nil, playableDuration: nil, age: 2 * days)
        let plan = RecoveryPlanner.plan([playable, tooShort, halfSecond, unreadableRecent, unreadableOld, noJournalRecent,
                                         noJournalOld])
        #expect(plan.actions == [
            .recover(playable), .delete(folder("b")), .delete(folder("c")), .keep(folder("d")), .delete(folder("e")),
            .keep(folder("f")), .delete(folder("g")),
        ])
        #expect(!plan.runsFocusOff)
        #expect(RecoveryPlanner.minimumDuration == 0.5)
        #expect(RecoveryPlanner.unreadableAge == 86_400)
        #expect(RecoveryPlanner.plan([]) == RecoveryPlan(actions: [], runsFocusOff: false))
    }

    /// A recording whose recovery keeps failing (the export of its file fails, or its history item can't be made) is
    /// tried `maximumAttempts` times, one a launch, then set aside rather than tried on every launch for ever.
    @Test func aRecordingThatKeepsFailingIsSetAsideAfterThreeAttempts() {
        var tried = journal()
        #expect(tried.recoveryAttempts == nil)
        func plan(after attempts: Int) -> RecoveryAction? {
            var journal = journal()
            for _ in 0..<attempts { journal.noteRecoveryAttempt() }
            let candidate = RecoveryCandidate(folder: folder("a"), journal: journal, playableDuration: 3, age: 2 * days)
            return RecoveryPlanner.plan([candidate]).actions.first
        }
        #expect(RecoveryPlanner.maximumAttempts == 3)
        if case .recover = plan(after: 0) {} else { Issue.record("a fresh recording isn't recovered") }
        if case .recover = plan(after: 2) {} else { Issue.record("a recording tried twice isn't tried again") }
        #expect(plan(after: 3) == .setAside(folder("a")))
        #expect(plan(after: 4) == .setAside(folder("a")))
        tried.noteRecoveryAttempt()
        tried.noteRecoveryAttempt()
        #expect(tried.recoveryAttempts == 2)
    }

    /// Even a recording too short to keep turned Focus on, and Focus Off still runs for it.
    @Test func focusOffRunsWhenAnyJournalTurnedItOn() {
        let plan = RecoveryPlanner.plan([
            RecoveryCandidate(folder: folder("a"), journal: journal(), playableDuration: 3, age: hours),
            RecoveryCandidate(folder: folder("b"), journal: journal(focusTurnedOn: true), playableDuration: 0.1, age: hours),
        ])
        #expect(plan.runsFocusOff)
        #expect(plan.actions.count == 2)
    }

    @Test func aJournalRoundTripsThroughJSON() throws {
        var full = journal(focusTurnedOn: true)
        full.mode = .gif
        full.state = .finishing
        full.gifFrameRate = 50
        full.gifQuality = 90
        full.gifOptimize = true
        full.appName = "Safari"
        full.appBundleID = "com.apple.Safari"
        full.windowTitle = "Start Page"
        full.noteRecoveryAttempt()
        let data = try JSONEncoder().encode(full)
        #expect(try JSONDecoder().decode(RecordingJournal.self, from: data) == full)
        // A plain video journal leaves the optional fields out, and starts recording, at the current version.
        let plain = journal()
        #expect(plain.version == RecordingJournal.currentVersion)
        #expect(plain.state == .recording)
        #expect(try JSONDecoder().decode(RecordingJournal.self, from: JSONEncoder().encode(plain)) == plain)
        #expect(RecordingJournal.fileName == "journal.json")
        #expect(RecordingJournal.currentVersion == 1)
        let json = String(decoding: try JSONEncoder().encode(full), as: UTF8.self)
        #expect(json.contains(#""state":"finishing""#))
        #expect(json.contains(#""mode":"gif""#))
    }
}
