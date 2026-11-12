import Testing
import CSUpdate

/// The cleanup of an install's work folder: the image is ejected once, and the folder is removed only when nothing is
/// mounted in it. An eject that was already tried (by the detach step) isn't tried again, so a stuck eject costs one
/// attempt, not two.
struct WorkFolderCleanupTests {
    /// Nothing mounted means the folder goes. A mounted image is ejected first; once the eject was tried (the detach
    /// step tried already), the cleanup doesn't try a second time, and keeps the folder (it holds the mount).
    @Test(arguments: [
        (false, false, WorkFolderCleanup.Step.remove), (true, false, .remove), (false, true, .eject), (true, true, .keep),
    ])
    func theNextStep(ejectTried: Bool, mounted: Bool, step: WorkFolderCleanup.Step) {
        #expect(WorkFolderCleanup.next(ejectTried: ejectTried, mounted: mounted) == step)
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
