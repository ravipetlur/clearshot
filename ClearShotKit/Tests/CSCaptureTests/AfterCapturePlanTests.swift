import CSCore
import Testing
@testable import CSCapture

/// A capture is never lost. It ends up saved, shown (a thumbnail, the editor or a pin), or copied.
struct AfterCapturePlanTests {
    @Test func aShownThumbnailKeepsTheCaptureSoNothingIsCopied() {
        let plan = AfterCapturePlan(actions: [.showQuickAccess])
        #expect(plan.showsQuickAccess)
        #expect(plan.showsThumbnail)
        #expect(!plan.saves)
        #expect(plan.copy(saved: false, shown: true) == .none)
    }

    @Test func theEditorKeepsTheCaptureLikeAThumbnail() {
        let plan = AfterCapturePlan(actions: [.openEditor])
        #expect(plan.opensEditor)
        #expect(!plan.showsThumbnail)
        #expect(plan.showsCapture)
        #expect(plan.copy(saved: false, shown: true) == .none)
        // An editor that couldn't open (no history item) keeps nothing, so the capture is copied.
        #expect(plan.copy(saved: false, shown: false) == .fallback)
    }

    @Test func aPinKeepsTheCaptureSoNothingIsCopied() {
        let plan = AfterCapturePlan(actions: [.pin])
        #expect(plan.pins)
        #expect(plan.showsCapture)
        #expect(!plan.showsThumbnail)
        #expect(!plan.saves)
        #expect(plan.copy(saved: false, shown: true) == .none)
        // No history item means no pin, so the capture is copied.
        #expect(plan.copy(saved: false, shown: false) == .fallback)
    }

    @Test func showsCaptureCountsThumbnailEditorAndPin() {
        #expect(AfterCapturePlan(actions: [.showQuickAccess]).showsCapture)
        #expect(AfterCapturePlan(actions: [.save], askForName: true).showsCapture)
        #expect(AfterCapturePlan(actions: [.openEditor]).showsCapture)
        #expect(AfterCapturePlan(actions: [.pin]).showsCapture)
        #expect(!AfterCapturePlan(actions: [.save]).showsCapture)
        #expect(!AfterCapturePlan(actions: [.copy, .save]).showsCapture)
        #expect(!AfterCapturePlan(actions: [.pin]).showsQuickAccess)
        #expect(!AfterCapturePlan(actions: [.showQuickAccess, .openEditor]).pins)
    }

    @Test func aThumbnailThatCouldntBeShownCopiesAsAFallback() {
        let plan = AfterCapturePlan(actions: [.showQuickAccess])
        #expect(plan.copy(saved: false, shown: false) == .fallback)
    }

    @Test func aSuccessfulSaveNeedsNoCopy() {
        let plan = AfterCapturePlan(actions: [.save])
        #expect(plan.saves)
        #expect(!plan.showsThumbnail)
        #expect(plan.copy(saved: true, shown: false) == .none)
    }

    @Test func aFailedSaveWithNoThumbnailCopiesAsAFallback() {
        let plan = AfterCapturePlan(actions: [.save])
        #expect(plan.copy(saved: false, shown: false) == .fallback)
    }

    @Test func copyIsRequestedNotAFallback() {
        let plan = AfterCapturePlan(actions: [.copy])
        #expect(!plan.saves)
        #expect(plan.copy(saved: false, shown: false) == .requested)
        #expect(plan.copy(saved: false, shown: true) == .requested)
    }

    @Test func copyAndSaveCopiesAsRequestedWhetherOrNotTheSaveWorked() {
        let plan = AfterCapturePlan(actions: [.copy, .save])
        #expect(plan.saves)
        #expect(plan.copy(saved: true, shown: false) == .requested)
        #expect(plan.copy(saved: false, shown: false) == .requested)
    }

    /// With nothing that saves, shows or copies the capture, it is copied so it isn't lost. The editor and a pin both
    /// keep the capture (`showsCaptureCountsThumbnailEditorAndPin`), so only the empty set is left here.
    @Test func actionsThatKeepNothingVisibleCopyAsAFallback() {
        let plan = AfterCapturePlan(actions: [])
        #expect(!plan.saves)
        #expect(!plan.showsThumbnail)
        #expect(!plan.showsCapture)
        #expect(plan.copy(saved: false, shown: false) == .fallback)
    }

    @Test func askForNameMovesTheSaveIntoTheThumbnail() {
        let plan = AfterCapturePlan(actions: [.save, .copy], askForName: true)
        #expect(!plan.saves)
        #expect(plan.defersSave)
        #expect(plan.showsThumbnail)
        #expect(!plan.showsQuickAccess)
    }

    @Test func askForNameWithoutSaveChangesNothing() {
        let plan = AfterCapturePlan(actions: [.showQuickAccess, .copy], askForName: true)
        #expect(!plan.defersSave)
        #expect(!plan.saves)
        #expect(plan.showsThumbnail)
    }
}
