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

    // MARK: Something is at the app's place

    /// No key, something at the app's place: it is the old app, nothing moved, and the staged copy can go.
    @Test func anAppThatIsStillInPlaceNeedsNothingRestored() {
        #expect(plan(inPlace: true) == .discardStaged)
        #expect(plan(inPlace: true, backup: true) == .discardStaged)
        #expect(plan(inPlace: true, staged: false) == .discardStaged)
    }

    /// Key and something at the app's place: the swap took effect. Nothing is deleted or put back; the new copy stays,
    /// and the old one (where the key says) is deleted as after a clean swap.
    @Test func aSwapThatTookEffectKeepsTheNewCopy() {
        #expect(plan(inPlace: true, reported: true) == .keepNewCopy)
        #expect(plan(inPlace: true, reported: true, original: true) == .keepNewCopy)
        #expect(plan(inPlace: true, reported: true, original: true, backup: true) == .keepNewCopy)
        #expect(plan(inPlace: true, reported: true, staged: false) == .keepNewCopy)
    }

    // MARK: Nothing is at the app's place

    @Test func anAppMovedAwayIsRestoredFromWhereTheErrorSaysItIs() {
        #expect(plan(reported: true, original: true) == .restoreFromOriginalLocation)
        #expect(plan(reported: true, original: true, backup: true) == .restoreFromOriginalLocation)
    }

    @Test func anAppMovedToItsBackupNameIsRestoredFromThere() {
        #expect(plan(backup: true) == .restoreFromBackup)
        // A key whose place has nothing in it doesn't stop the backup name being looked at.
        #expect(plan(reported: true, original: false, backup: true) == .restoreFromBackup)
    }

    /// Neither old copy can be found: the verified staged copy takes the app's place.
    @Test func whenNoOldCopyCanBeFoundTheStagedCopyTakesItsPlace() {
        #expect(plan() == .promoteStaged)
        #expect(plan(reported: true) == .promoteStaged)
    }

    /// Nothing at the app's place and nothing to put there: the one case that leaves the app missing.
    @Test func whenThereIsNothingToPutInItsPlaceTheAppIsLost() {
        #expect(plan(staged: false) == .appLost)
        #expect(plan(reported: true, staged: false) == .appLost)
    }

    /// The staged copy doesn't matter while an old copy can be restored: that comes first.
    @Test func anOldCopyIsRestoredWhetherOrNotTheStagedCopyIsThere() {
        #expect(plan(reported: true, original: true, staged: false) == .restoreFromOriginalLocation)
        #expect(plan(backup: true, staged: false) == .restoreFromBackup)
    }

    // MARK: When the restore itself fails

    @Test func aFailedRestoreFallsBackToTheStagedCopy() {
        #expect(ReplaceRecovery.planAfterFailedRestore(stagedExists: true) == .promoteStaged)
    }

    @Test func aFailedRestoreWithNoStagedCopyLeavesTheAppLost() {
        #expect(ReplaceRecovery.planAfterFailedRestore(stagedExists: false) == .appLost)
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

    // MARK: Every combination

    /// The staged copy is deleted only when the old app is in place and nothing happened to it; the new copy is kept
    /// only when the key says the swap happened; the app is lost only when nothing is at its place and nothing can be.
    @Test func everyCombinationHasTheRightPlan() {
        for inPlace in [false, true] {
            for reported in [false, true] {
                for original in [false, true] {
                    for backup in [false, true] {
                        for staged in [false, true] {
                            let result = plan(inPlace: inPlace, reported: reported, original: original, backup: backup,
                                              staged: staged)
                            let context = "inPlace \(inPlace), reported \(reported), original \(original), backup \(backup), staged \(staged)"
                            #expect((result == .discardStaged) == (inPlace && !reported), "\(context)")
                            #expect((result == .keepNewCopy) == (inPlace && reported), "\(context)")
                            let restores = !inPlace && ((reported && original) || backup)
                            #expect((result == .restoreFromOriginalLocation || result == .restoreFromBackup) == restores, "\(context)")
                            #expect((result == .appLost) == (!inPlace && !restores && !staged), "\(context)")
                            #expect((result == .promoteStaged) == (!inPlace && !restores && staged), "\(context)")
                        }
                    }
                }
            }
        }
    }
}
