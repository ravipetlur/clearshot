import Foundation
import Testing
import CSUpdate

/// The names an install puts on disk: the hidden staging copy and the backup beside the app, and the work folder.
struct InstallNamesTests {
    let old = VersionNumber("1.1.0")!
    let new = VersionNumber("1.2.0")!

    @Test func theAppInsideTheImageIsClearShotApp() {
        #expect(InstallNames.appName == "ClearShot.app")
    }

    @Test func theStagedCopyIsHiddenAndNamesTheVersion() {
        let name = InstallNames.stagedName(for: new)
        #expect(name == ".ClearShot-update-1.2.0.app")
        #expect(name.hasPrefix("."))
        #expect(name.hasSuffix(".app"))
    }

    @Test func theBackupNamesTheOldVersion() {
        #expect(InstallNames.backupName(for: old, isTaken: { _ in false }) == "ClearShot-1.1.0.app")
    }

    /// A backup of that name left beside the app by an earlier update isn't overwritten.
    @Test func aTakenBackupNameGetsANumber() {
        let taken: Set<String> = ["ClearShot-1.1.0.app", "ClearShot-1.1.0 2.app"]
        #expect(InstallNames.backupName(for: old, isTaken: { taken.contains($0) }) == "ClearShot-1.1.0 3.app")
        #expect(InstallNames.backupName(for: old, isTaken: { $0 == "ClearShot-1.1.0.app" }) == "ClearShot-1.1.0 2.app")
    }

    @Test func theBackupNameIsNotHidden() {
        #expect(!InstallNames.backupName(for: old, isTaken: { _ in false }).hasPrefix("."))
    }

    @Test func theWorkFolderIsRecognisedByItsName() {
        #expect(InstallNames.workFolderPrefix == "ClearShot-update-")
        #expect(InstallNames.isWorkFolder(named: "ClearShot-update-3F2B6C1E"))
        #expect(!InstallNames.isWorkFolder(named: "ClearShot-update-"))
        #expect(!InstallNames.isWorkFolder(named: "ClearShot"))
        #expect(!InstallNames.isWorkFolder(named: ".ClearShot-update-1.2.0.app"))
        #expect(!InstallNames.isWorkFolder(named: "my-ClearShot-update-3F2B"))
    }

    // MARK: Leftovers

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A work folder a crash or a hand-off left behind is cleared out later, once it is clearly nobody's: not one an
    /// install is using, and not one a person may still be dragging an app out of.
    @Test func onlyOldWorkFoldersAreLeftovers() {
        let hour: TimeInterval = 3600
        let folders: [(name: String, modified: Date)] = [
            ("ClearShot-update-FRESH", now.addingTimeInterval(-5 * 60)),
            ("ClearShot-update-HOURS", now.addingTimeInterval(-3 * hour)),
            ("ClearShot-update-OLD", now.addingTimeInterval(-13 * hour)),
            ("ClearShot-update-ANCIENT", now.addingTimeInterval(-40 * 24 * hour)),
            ("Other-folder", now.addingTimeInterval(-40 * 24 * hour)),
            ("ClearShot-update-", now.addingTimeInterval(-40 * 24 * hour)),
        ]
        #expect(InstallNames.staleWorkFolders(folders, now: now) == ["ClearShot-update-OLD", "ClearShot-update-ANCIENT"])
    }

    @Test func aFolderDatedInTheFutureIsNotALeftover() {
        let folders: [(name: String, modified: Date)] = [("ClearShot-update-X", now.addingTimeInterval(3600))]
        #expect(InstallNames.staleWorkFolders(folders, now: now).isEmpty)
    }

    @Test func aFolderBecomesALeftoverAfterHalfADay() {
        #expect(InstallNames.staleAfter == 12 * 3600)
        let exactly: [(name: String, modified: Date)] = [("ClearShot-update-X", now.addingTimeInterval(-InstallNames.staleAfter))]
        #expect(InstallNames.staleWorkFolders(exactly, now: now).isEmpty)
        let past: [(name: String, modified: Date)] = [("ClearShot-update-X", now.addingTimeInterval(-InstallNames.staleAfter - 1))]
        #expect(InstallNames.staleWorkFolders(past, now: now) == ["ClearShot-update-X"])
    }

    // MARK: Staged copies a crash left beside the app

    /// Only the staged copy's own name, exactly: a hidden folder named for the updater and a version `X.Y.Z`. Nothing else
    /// beside the app is ever removed, however similar its name.
    @Test func aStagedCopyIsRecognisedByItsExactName() {
        #expect(InstallNames.isStagedName(".ClearShot-update-1.2.0.app"))
        #expect(InstallNames.isStagedName(".ClearShot-update-10.0.12.app"))
        #expect(InstallNames.isStagedName(InstallNames.stagedName(for: new)))
    }

    @Test(arguments: [
        "ClearShot-update-1.2.0.app",           // not hidden
        ".ClearShot-update-1.2.app",            // not X.Y.Z
        ".ClearShot-update-1.2.0.0.app",
        ".ClearShot-update-1.2.0",              // no .app
        ".ClearShot-update-1.2.0.app.zip",
        ".ClearShot-update-1.2.0.app ",
        ".ClearShot-update-v1.2.0.app",         // a v is not our spelling
        ".ClearShot-update-1.02.0.app",
        ".ClearShot-update-1.2.0-beta.app",
        ".ClearShot-update-.app",
        ".ClearShot-update-x.app",
        ".clearshot-update-1.2.0.app",
        "..ClearShot-update-1.2.0.app",
        ".ClearShot-update-1.2.0.app/..",
        "ClearShot.app", "ClearShot-1.1.0.app", "Safari.app", ".DS_Store", ".localized", "",
    ])
    func nothingElseIsAStagedCopy(name: String) {
        #expect(!InstallNames.isStagedName(name))
    }

    @Test func onlyStagedCopiesAreChosenFromAFolder() {
        let names = [
            "ClearShot.app", ".ClearShot-update-1.2.0.app", "Notes.app", "ClearShot-1.1.0.app", ".DS_Store",
            ".ClearShot-update-1.3.1.app", ".ClearShot-update-1.2.app", "ClearShot-update-1.2.0.app",
        ]
        #expect(InstallNames.stagedCopies(in: names) == [".ClearShot-update-1.2.0.app", ".ClearShot-update-1.3.1.app"])
        #expect(InstallNames.stagedCopies(in: []).isEmpty)
    }
}
