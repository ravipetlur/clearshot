import Testing
import CSUpdate

/// The cleanup of an install's work folder: the image is ejected once, and the folder is removed only when nothing is
/// mounted in it. An eject that was already tried (by the detach step) isn't tried again, so a stuck eject costs one
/// attempt, not two.
struct WorkFolderCleanupTests {
    @Test func nothingMountedMeansTheFolderGoes() {
        #expect(WorkFolderCleanup.next(ejectTried: false, mounted: false) == .remove)
        #expect(WorkFolderCleanup.next(ejectTried: true, mounted: false) == .remove)
    }

    @Test func aMountedImageIsEjectedFirst() {
        #expect(WorkFolderCleanup.next(ejectTried: false, mounted: true) == .eject)
    }

    /// The detach step already tried: the cleanup doesn't try a second time, and keeps the folder (it holds the mount).
    @Test func anImageThatStaysMountedAfterTheEjectKeepsTheFolder() {
        #expect(WorkFolderCleanup.next(ejectTried: true, mounted: true) == .keep)
    }

    @Test func aWholeCleanupEjectsAtMostOnce() {
        // Walk it as the caller does: ask, do what it says, ask again.
        func run(ejectTried alreadyTried: Bool, ejectWorks: Bool) -> (ejects: Int, ending: WorkFolderCleanup.Step) {
            var tried = alreadyTried
            var mounted = true
            var ejects = 0
            while true {
                let step = WorkFolderCleanup.next(ejectTried: tried, mounted: mounted)
                switch step {
                case .eject:
                    ejects += 1
                    tried = true
                    if ejectWorks { mounted = false }
                case .remove, .keep:
                    return (ejects, step)
                }
            }
        }
        #expect(run(ejectTried: false, ejectWorks: true) == (1, .remove))
        #expect(run(ejectTried: false, ejectWorks: false) == (1, .keep))
        #expect(run(ejectTried: true, ejectWorks: true) == (0, .keep))
    }
}
