import Foundation
import Testing
import CSUpdate

/// After the swap of the running app for the new copy fails, what to do with what is on disk.
///
/// `NSFileOriginalItemLocationKey` (NSFileManager.h) comes with the error only when the old app isn't at its original
/// location, so the key together with something at the app's place means the swap took effect: the new copy is at the
/// app's place and the old one is where the key says. Without the key, something at the app's place is the old app,
/// untouched. With nothing at the app's place, the old copy is put back from wherever it is; and when it can't be, the
/// verified staged copy takes the app's place, so the app is never left missing while a good copy sits hidden beside it.
struct ReplaceRecoveryTests {
    typealias Plan = ReplaceRecovery.Plan

    func plan(inPlace: Bool = false, reported: Bool = false, original: Bool = false, backup: Bool = false,
              staged: Bool = true) -> Plan {
        ReplaceRecovery.plan(appInPlace: inPlace, originalLocationReported: reported, originalLocationExists: original,
                             backupExists: backup, stagedExists: staged)
    }

    // MARK: Every combination

    /// The whole table. Something at the app's place without the key is the old app, nothing moved, and the staged copy
    /// can go. With the key, the swap took effect: nothing is deleted or put back, the new copy stays, and the old one
    /// (where the key says) is deleted as after a clean swap. With nothing at the app's place, an old copy is restored
    /// first, from where the error says it is, else from its backup name (a key whose place has nothing in it doesn't
    /// stop the backup name being looked at), whether or not the staged copy is there. When neither old copy can be
    /// found the verified staged copy takes the app's place, and only with nothing to put there is the app lost.
    @Test(arguments: [
        // (app in place, original location reported, original location exists, backup exists, staged exists, plan)
        (false, false, false, false, false, .appLost),
        (false, false, false, false, true, .promoteStaged),
        (false, false, false, true, false, .restoreFromBackup),
        (false, false, false, true, true, .restoreFromBackup),
        (false, false, true, false, false, .appLost),
        (false, false, true, false, true, .promoteStaged),
        (false, false, true, true, false, .restoreFromBackup),
        (false, false, true, true, true, .restoreFromBackup),
        (false, true, false, false, false, .appLost),
        (false, true, false, false, true, .promoteStaged),
        (false, true, false, true, false, .restoreFromBackup),
        (false, true, false, true, true, .restoreFromBackup),
        (false, true, true, false, false, .restoreFromOriginalLocation),
        (false, true, true, false, true, .restoreFromOriginalLocation),
        (false, true, true, true, false, .restoreFromOriginalLocation),
        (false, true, true, true, true, .restoreFromOriginalLocation),
        (true, false, false, false, false, .discardStaged),
        (true, false, false, false, true, .discardStaged),
        (true, false, false, true, false, .discardStaged),
        (true, false, false, true, true, .discardStaged),
        (true, false, true, false, false, .discardStaged),
        (true, false, true, false, true, .discardStaged),
        (true, false, true, true, false, .discardStaged),
        (true, false, true, true, true, .discardStaged),
        (true, true, false, false, false, .keepNewCopy),
        (true, true, false, false, true, .keepNewCopy),
        (true, true, false, true, false, .keepNewCopy),
        (true, true, false, true, true, .keepNewCopy),
        (true, true, true, false, false, .keepNewCopy),
        (true, true, true, false, true, .keepNewCopy),
        (true, true, true, true, false, .keepNewCopy),
        (true, true, true, true, true, .keepNewCopy),

    ] as [(Bool, Bool, Bool, Bool, Bool, Plan)])
    func everyCombinationHasItsPlan(inPlace: Bool, reported: Bool, original: Bool, backup: Bool, staged: Bool,
                                    expected: Plan) {
        #expect(plan(inPlace: inPlace, reported: reported, original: original, backup: backup, staged: staged) == expected)
    }

    // MARK: When the restore itself fails

    @Test(arguments: [(true, Plan.promoteStaged), (false, .appLost)])
    func aFailedRestoreFallsBackToTheStagedCopyIfThereIsOne(stagedExists: Bool, expected: Plan) {
        #expect(ReplaceRecovery.planAfterFailedRestore(stagedExists: stagedExists) == expected)
    }

    // MARK: The running app is never the old copy

    let running = URL(filePath: "/Users/someone/Apps/ClearShot.app", directoryHint: .isDirectory)

    /// What the error names as the old app's place is deleted after the swap, so it must never be the running app's own
    /// place (where the new copy now is): that is taken as the key not being there.
    @Test func aReportedLocationThatIsTheRunningAppIsNotReported() {
        #expect(ReplaceRecovery.reportedOriginalLocation(running, running: running) == nil)
        // The same place spelled differently: a trailing slash or not (a directory URL keeps its slash), a "." or ".." in
        // the path, a doubled slash.
        let spellings = ["/Users/someone/Apps/ClearShot.app/", "/Users/someone/Apps/./ClearShot.app",
                         "/Users/someone/Apps/Other/../ClearShot.app", "/Users/someone/Apps//ClearShot.app",
                         "/Users/someone/Apps/ClearShot.app"]
        for spelling in spellings {
            for hint in [URL.DirectoryHint.isDirectory, .notDirectory, .inferFromPath] {
                let reported = URL(filePath: spelling, directoryHint: hint)
                #expect(ReplaceRecovery.reportedOriginalLocation(reported, running: running) == nil, "\(spelling) \(hint)")
            }
        }
    }

    @Test func aReportedLocationElsewhereIsKept() {
        let old = URL(filePath: "/Users/someone/Apps/ClearShot 1.1.app", directoryHint: .isDirectory)
        #expect(ReplaceRecovery.reportedOriginalLocation(old, running: running) == old)
        let sameNameElsewhere = URL(filePath: "/Users/someone/Other/ClearShot.app", directoryHint: .isDirectory)
        #expect(ReplaceRecovery.reportedOriginalLocation(sameNameElsewhere, running: running) == sameNameElsewhere)
        // Inside the running app is somewhere else too: only the app's own place is the new copy.
        let inside = running.appending(path: "Contents", directoryHint: .isDirectory)
        #expect(ReplaceRecovery.reportedOriginalLocation(inside, running: running) == inside)
    }

    @Test func noReportedLocationIsNone() {
        #expect(ReplaceRecovery.reportedOriginalLocation(nil, running: running) == nil)
    }

    /// With the running app's own place reported, something at the app's place is read as the old app (no key): the
    /// staged copy goes, and nothing at the app's place is ever named as the old copy to delete.
    @Test func aReportedRunningAppIsPlannedAsIfNothingWasReported() {
        let reported = ReplaceRecovery.reportedOriginalLocation(running, running: running)
        #expect(plan(inPlace: true, reported: reported != nil, original: true) == .discardStaged)
        #expect(plan(reported: reported != nil, original: true, backup: true) == .restoreFromBackup)
        #expect(plan(reported: reported != nil, original: true) == .promoteStaged)
    }

    @Test func theRunningAppIsTheOneAtItsOwnPlaceHoweverItIsSpelled() {
        #expect(ReplaceRecovery.isRunningApp(running, running: running))
        #expect(ReplaceRecovery.isRunningApp(URL(filePath: "/Users/someone/Apps/ClearShot.app/"), running: running))
        #expect(ReplaceRecovery.isRunningApp(URL(filePath: "/Users/someone/Apps/x/../ClearShot.app"), running: running))
        #expect(!ReplaceRecovery.isRunningApp(URL(filePath: "/Users/someone/Apps/ClearShot 1.1.app"), running: running))
        #expect(!ReplaceRecovery.isRunningApp(URL(filePath: "/Users/someone/Apps"), running: running))
    }
}
