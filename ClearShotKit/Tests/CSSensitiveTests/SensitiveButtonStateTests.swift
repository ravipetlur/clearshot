import Testing
@testable import CSSensitive

/// The sensitive-info button in Annotate's tool strip, as a state machine over the pictures the open document has and the
/// masks of the secrets check it holds: what it shows, what a click does, and when a scan for it is wanted, cancelled or
/// started over. A picture here is a number; the app uses the document's `PictureIdentity`, which is equal exactly when the
/// same pixels are.
struct SensitiveButtonStateTests {
    private typealias State = SensitiveButtonState<Int>

    private let three = FindingCounts([.contact: 2, .keyOrToken: 1])
    private let one = FindingCounts([.card: 1])
    private let nothing = FindingCounts([])
    private let delay = Duration.milliseconds(500)

    /// A button whose editor has reported picture 1 (with no marked masks in it).
    private func opened(automatic: Bool = true, kinds: SensitiveKinds = .all, masks: Int = 0) -> State {
        var state = State(automatic: automatic, kinds: kinds)
        state.apply(.masksChanged(masks))
        state.apply(.pictureChanged(1))
        return state
    }

    /// A button whose scan of picture 1 has found `counts`.
    private func scanned(_ counts: FindingCounts, automatic: Bool = true, kinds: SensitiveKinds = .all, masks: Int = 0) -> State {
        var state = opened(automatic: automatic, kinds: kinds, masks: masks)
        state.apply(.scanFinished(1, kinds: kinds, counts: counts))
        return state
    }

    // MARK: Opening

    @Test func aButtonStartsIdleWithTheDefaultSettings() {
        let state = State()
        #expect(state.phase == .idle)
        #expect(state.automatic)
        #expect(state.kinds == .all)
        #expect(state.picture == nil)
        #expect(state.maskCount == 0)
    }

    @Test func theScanDelayIsHalfASecond() {
        #expect(State.rescanDelay == .milliseconds(500))
    }

    @Test func theFirstPictureIsScannedAtOnce() {
        var state = State()
        #expect(state.apply(.pictureChanged(1)) == .scan(after: .zero))
        #expect(state.phase == .scanning)
        #expect(state.picture == 1)
    }

    @Test func nothingIsScannedBeforeTheEditorReportsAPicture() {
        var state = State()
        #expect(state.apply(.settingsChanged(automatic: true, kinds: .contact)) == .none)
        #expect(state.apply(.masksChanged(2)) == .none)
        #expect(state.phase == .masked(2))
    }

    // MARK: Findings and marked masks: every combination

    @Test func noFindingsAndNoMasksIsAPlainButton() {
        let state = scanned(nothing)
        #expect(state.phase == SensitiveButtonPhase.none)
        #expect(!state.showsWarning)
        #expect(state.action == .mask)
    }

    @Test func findingsAndNoMasksIsTheWarning() {
        let state = scanned(three)
        #expect(state.phase == .found(three))
        #expect(state.showsWarning)
        #expect(state.action == .mask)
    }

    @Test func masksAndNoFindingsIsTheMaskedLookAndAClickUnmasks() {
        let state = scanned(nothing, masks: 3)
        #expect(state.phase == .masked(3))
        #expect(!state.showsWarning)
        #expect(state.action == .unmask)
    }

    @Test func masksAndFindingsIsTheWarningAndAClickMasksTheRest() {
        // Unmasked findings take precedence over the masks that are already there.
        let state = scanned(one, masks: 2)
        #expect(state.phase == .found(one))
        #expect(state.showsWarning)
        #expect(state.action == .mask)
    }

    @Test func theMaskedLookCountsTheMasksInTheDocumentNotTheFindings() {
        #expect(scanned(three, masks: 0).phase == .found(three))
        #expect(scanned(nothing, masks: 1).phase == .masked(1))
        #expect(scanned(nothing, masks: 7).phase == .masked(7))
    }

    @Test func theMaskedLookComesFromTheDocumentSoNoScanIsNeededForIt() {
        // A capture opened with its masks already on (Review after Mask All): masked before any scan has said anything.
        var state = State()
        state.apply(.masksChanged(3))
        #expect(state.apply(.pictureChanged(1)) == .scan(after: .zero))
        #expect(state.phase == .masked(3))
        #expect(state.action == .unmask)
        // The scan that follows finds nothing more: still masked.
        state.apply(.scanFinished(1, kinds: .all, counts: nothing))
        #expect(state.phase == .masked(3))
        // Or something the masks don't cover: the warning.
        var more = State()
        more.apply(.masksChanged(3))
        more.apply(.pictureChanged(1))
        more.apply(.scanFinished(1, kinds: .all, counts: one))
        #expect(more.phase == .found(one))
    }

    @Test func whileAScanIsWantedMasksStillShowAndWithoutThemTheButtonIsPlain() {
        #expect(opened().phase == .scanning)
        #expect(opened(masks: 2).phase == .masked(2))
        #expect(opened(masks: 2).action == .unmask)
    }

    @Test func aFailedScanWithMasksStaysMaskedAndWithoutThemIsPlain() {
        var withMasks = opened(masks: 2)
        withMasks.apply(.scanFailed(1, kinds: .all))
        #expect(withMasks.phase == .masked(2))
        var without = opened()
        without.apply(.scanFailed(1, kinds: .all))
        #expect(without.phase == .idle)
    }

    @Test func theMaskCountFollowsTheDocument() {
        var state = scanned(nothing, masks: 3)
        #expect(state.apply(.masksChanged(2)) == .none)
        #expect(state.phase == .masked(2))
        #expect(state.apply(.masksChanged(0)) == .none)
        #expect(state.phase == SensitiveButtonPhase.none)
        // A count that isn't a count is none.
        state.apply(.masksChanged(-4))
        #expect(state.maskCount == 0)
        #expect(state.phase == SensitiveButtonPhase.none)
    }

    // MARK: A scan finishes

    @Test func aScanThatFailsLeavesAPlainButtonAndDoesNotTryAgain() {
        var state = opened()
        #expect(state.apply(.scanFailed(1, kinds: .all)) == .none)
        #expect(state.phase == .idle)
        #expect(!state.showsWarning)
        // The same picture again (a label drawn on it, say) is no reason to scan it again.
        #expect(state.apply(.pictureChanged(1)) == .none)
        #expect(state.phase == .idle)
        // A change of picture is.
        #expect(state.apply(.pictureChanged(2)) == .scan(after: delay))
    }

    @Test func aClicksScanThatFailsLeavesAPlainButtonNotAScanThatNeverEnds() {
        // A click with nothing ready scans for itself and its owner cancels the automatic scan, so the click's failure is
        // reported as that scan's: the button is plain and waiting for nothing.
        var state = opened()
        #expect(state.phase == .scanning)
        #expect(state.apply(.scanFailed(1, kinds: .all)) == .none)
        #expect(state.phase == .idle)
        #expect(state.isEnabled(maskRunning: false))
    }

    @Test func aFailedScanCanBeRetriedBySwitchingTheSettingOffAndOn() {
        var state = opened()
        state.apply(.scanFailed(1, kinds: .all))
        state.apply(.settingsChanged(automatic: false, kinds: .all))
        #expect(state.apply(.settingsChanged(automatic: true, kinds: .all)) == .scan(after: .zero))
        #expect(state.phase == .scanning)
    }

    @Test func aResultForAnOlderPictureIsDropped() {
        var state = opened()
        state.apply(.pictureChanged(2))
        // The first scan's result arrives late: the picture has moved on, and the scan wanted now is the second.
        #expect(state.apply(.scanFinished(1, kinds: .all, counts: three)) == .none)
        #expect(state.phase == .scanning)
        state.apply(.scanFinished(2, kinds: .all, counts: one))
        #expect(state.phase == .found(one))
    }

    @Test func aFailureForAnOlderPictureIsDropped() {
        var state = opened()
        state.apply(.pictureChanged(2))
        #expect(state.apply(.scanFailed(1, kinds: .all)) == .none)
        #expect(state.phase == .scanning)
    }

    @Test func aResultForOtherKindsIsDropped() {
        var state = opened()
        state.apply(.settingsChanged(automatic: true, kinds: .contact))
        state.apply(.scanFinished(1, kinds: .all, counts: three))
        #expect(state.phase == .scanning)
    }

    // MARK: The picture changes: debounce and cancel

    @Test func aChangedPictureIsScannedAgainAfterTheDelay() {
        var state = scanned(three)
        #expect(state.apply(.pictureChanged(2)) == .scan(after: delay))
        // The old warning is not shown over a picture it was not read from.
        #expect(state.phase == .scanning)
        state.apply(.scanFinished(2, kinds: .all, counts: one))
        #expect(state.phase == .found(one))
    }

    @Test func eachChangeStartsTheDelayOver() {
        var state = scanned(three)
        #expect(state.apply(.pictureChanged(2)) == .scan(after: delay))
        #expect(state.apply(.pictureChanged(3)) == .scan(after: delay))
        #expect(state.apply(.pictureChanged(4)) == .scan(after: delay))
        #expect(state.picture == 4)
    }

    @Test func theSamePictureAgainChangesNothing() {
        var state = scanned(three)
        // A label, a move, a recolour: the document changed, the picture didn't.
        #expect(state.apply(.pictureChanged(1)) == .none)
        #expect(state.phase == .found(three))
        // Nor does it disturb a scan that is on its way.
        var waiting = opened()
        #expect(waiting.apply(.pictureChanged(1)) == .none)
        #expect(waiting.phase == .scanning)
    }

    @Test func goingBackToAScannedPictureCancelsTheScanAndShowsItsResult() {
        var state = scanned(three)
        state.apply(.pictureChanged(2))
        // Undone before the delay ran out: the scan wanted for 2 is cancelled, and 1's result is current again.
        #expect(state.apply(.pictureChanged(1)) == .cancelScan)
        #expect(state.phase == .found(three))
    }

    @Test func theResultsOfSeveralPicturesAreKept() {
        // The picture as it was scanned, and the one with the masks in it: both known, so undo and redo need no scan.
        var state = scanned(three)
        state.apply(.pictureChanged(2))
        state.apply(.scanFinished(2, kinds: .all, counts: nothing))
        #expect(state.apply(.pictureChanged(1)) == .none)
        #expect(state.phase == .found(three))
        #expect(state.apply(.pictureChanged(2)) == .none)
        #expect(state.phase == SensitiveButtonPhase.none)
    }

    // MARK: The master switch

    @Test func theMastersSwitchOffScansNothingOnItsOwn() {
        var state = opened(automatic: false)
        #expect(state.phase == .idle)
        #expect(state.apply(.pictureChanged(2)) == .none)
        #expect(state.phase == .idle)
    }

    @Test func theMastersSwitchGoingOffCancelsTheScanOnItsWay() {
        var state = opened()
        #expect(state.apply(.settingsChanged(automatic: false, kinds: .all)) == .cancelScan)
        #expect(state.phase == .idle)
        // Nothing is cancelled twice.
        #expect(state.apply(.settingsChanged(automatic: false, kinds: .all)) == .none)
    }

    @Test func theMastersSwitchGoingOnScansTheCurrentPictureAtOnce() {
        var state = opened(automatic: false)
        #expect(state.apply(.settingsChanged(automatic: true, kinds: .all)) == .scan(after: .zero))
        #expect(state.phase == .scanning)
    }

    @Test func withTheMastersSwitchOffNoWarningShows() {
        var state = scanned(three)
        state.apply(.settingsChanged(automatic: false, kinds: .all))
        #expect(state.phase == .idle)
        #expect(!state.showsWarning)
        // Nothing rescans, so a warning for a picture that has changed would be shown for good.
        state.apply(.pictureChanged(2))
        #expect(state.phase == .idle)
    }

    @Test func withTheMastersSwitchOffTheMaskedLookStillShowsAndAClickUnmasks() {
        // It comes from the document, not from a scan.
        let state = opened(automatic: false, masks: 2)
        #expect(state.phase == .masked(2))
        #expect(state.action == .unmask)
    }

    @Test func theMastersSwitchGoingOnKeepsAResultThatIsStillCurrent() {
        var state = scanned(three)
        state.apply(.settingsChanged(automatic: false, kinds: .all))
        // Back on for the same picture: its result is known, so it shows with no new scan.
        #expect(state.apply(.settingsChanged(automatic: true, kinds: .all)) == .none)
        #expect(state.phase == .found(three))
    }

    // MARK: The kinds

    @Test func withNoKindOnAndNoMasksTheButtonIsDisabled() {
        var state = opened()
        #expect(state.apply(.settingsChanged(automatic: true, kinds: [])) == .cancelScan)
        #expect(state.phase == .disabled)
        #expect(!state.isEnabled(maskRunning: false))
        // Nothing to look for, so nothing is scanned.
        #expect(state.apply(.pictureChanged(2)) == .none)
        #expect(state.phase == .disabled)
    }

    @Test func withNoKindOnTheMasksCanStillBeTakenOut() {
        // Unmasking looks for nothing, so it doesn't need a kind.
        var state = opened(masks: 2)
        state.apply(.settingsChanged(automatic: true, kinds: []))
        #expect(state.phase == .masked(2))
        #expect(state.action == .unmask)
        #expect(state.isEnabled(maskRunning: false))
    }

    @Test func withNoKindOnAResultIsNotShown() {
        var state = scanned(three)
        state.apply(.settingsChanged(automatic: true, kinds: []))
        #expect(state.phase == .disabled)
        #expect(!state.showsWarning)
    }

    @Test func switchingAKindOnScansAgainAtOnce() {
        var state = opened(kinds: [])
        #expect(state.phase == .disabled)
        #expect(state.apply(.settingsChanged(automatic: true, kinds: .cards)) == .scan(after: .zero))
        #expect(state.phase == .scanning)
    }

    @Test func aResultForOtherKindsThanTheOnesNowOnIsStale() {
        var state = scanned(three)
        // Contact details were counted; now only cards are looked for, so the count means nothing.
        #expect(state.apply(.settingsChanged(automatic: true, kinds: .cards)) == .scan(after: .zero))
        #expect(state.phase == .scanning)
        // Back to what was scanned: the result stands again.
        #expect(state.apply(.settingsChanged(automatic: true, kinds: .all)) == .cancelScan)
        #expect(state.phase == .found(three))
    }

    @Test func theSameSettingsAgainChangeNothing() {
        // Every preference write reports, whichever key it was.
        var state = scanned(three)
        #expect(state.apply(.settingsChanged(automatic: true, kinds: .all)) == .none)
        #expect(state.phase == .found(three))
    }

    // MARK: A click's scan

    @Test func aClicksResultShowsWhenTheAutomaticCheckIsOnAndIsKeptWhenItIsOff() {
        var state = opened(automatic: false)
        #expect(state.apply(.checked(1, kinds: .all, counts: three)) == .none)
        #expect(state.phase == .idle)
        // Switched on: the picture's result is known already, so it shows, and nothing is scanned.
        #expect(state.apply(.settingsChanged(automatic: true, kinds: .all)) == .none)
        #expect(state.phase == .found(three))
    }

    @Test func aClicksResultOfNothingShowsAPlainButton() {
        var state = opened()
        state.apply(.checked(1, kinds: .all, counts: nothing))
        #expect(state.phase == SensitiveButtonPhase.none)
    }

    @Test func aClicksResultCancelsTheAutomaticScanItMakesRedundant() {
        var state = opened()
        #expect(state.phase == .scanning)
        #expect(state.apply(.checked(1, kinds: .all, counts: three)) == .cancelScan)
        #expect(state.phase == .found(three))
    }

    @Test func aClicksResultForAnOlderPictureIsDropped() {
        var state = opened()
        state.apply(.pictureChanged(2))
        #expect(state.apply(.checked(1, kinds: .all, counts: three)) == .none)
        #expect(state.phase == .scanning)
    }

    // MARK: Masking and unmasking, as the app reports them

    /// What the app reports after a click masks `counts` found in picture 1, and the document is picture 2 with `masks` marked
    /// masks: the scan's result for 1, the document's change, and that the picture with the masks has nothing unmasked.
    private func masked(_ state: inout State, counts: FindingCounts, masks: Int, picture: Int = 2) {
        state.apply(.checked(1, kinds: .all, counts: counts))
        state.apply(.masksChanged(masks))
        state.apply(.pictureChanged(picture))
        state.apply(.checked(picture, kinds: .all, counts: nothing))
    }

    @Test func maskingClearsTheWarningAtOnceAndNeedsNoScan() {
        var state = scanned(three)
        state.apply(.checked(1, kinds: .all, counts: three))
        state.apply(.masksChanged(3))
        // The editor reports the document's change: a scan is wanted for it...
        #expect(state.apply(.pictureChanged(2)) == .scan(after: delay))
        // ... and the command's word that nothing is left unmasked in it cancels that scan.
        #expect(state.apply(.checked(2, kinds: .all, counts: nothing)) == .cancelScan)
        #expect(state.phase == .masked(3))
        #expect(state.action == .unmask)
        #expect(!state.showsWarning)
    }

    @Test func undoingTheMasksBringsTheWarningBackWithNoScan() {
        var state = scanned(three)
        masked(&state, counts: three, masks: 3)
        // ⌘Z: no marked masks, and the picture that was scanned again, whose result is known.
        state.apply(.masksChanged(0))
        #expect(state.apply(.pictureChanged(1)) == .none)
        #expect(state.phase == .found(three))
        #expect(state.action == .mask)
        // ⇧⌘Z: the masks are back, and the masked picture's result is known too.
        state.apply(.masksChanged(3))
        #expect(state.apply(.pictureChanged(2)) == .none)
        #expect(state.phase == .masked(3))
    }

    @Test func unmaskingBringsTheWarningBackWithNoScanWhenItsPictureIsKnown() {
        var state = scanned(three)
        masked(&state, counts: three, masks: 3)
        // The click on the masked look takes every marked mask out: the picture that was scanned again.
        state.apply(.masksChanged(0))
        #expect(state.apply(.pictureChanged(1)) == .none)
        #expect(state.phase == .found(three))
    }

    @Test func unmaskingACaptureOpenedMaskedScansItsUnmaskedPicture() {
        // Review on a masked capture: opened with the masks, never scanned without them.
        var state = State()
        state.apply(.masksChanged(2))
        state.apply(.pictureChanged(1))
        state.apply(.scanFinished(1, kinds: .all, counts: nothing))
        #expect(state.phase == .masked(2))
        // Unmask: a picture nobody has read, so the normal scan runs after the delay, and brings the warning back.
        state.apply(.masksChanged(0))
        #expect(state.apply(.pictureChanged(2)) == .scan(after: delay))
        #expect(state.phase == .scanning)
        state.apply(.scanFinished(2, kinds: .all, counts: three))
        #expect(state.phase == .found(three))
    }

    @Test func deletingOneMaskScansAgainAndTheMaskedLookStaysMeanwhile() {
        var state = scanned(three)
        masked(&state, counts: three, masks: 3)
        // One mask deleted by hand: a picture nobody has read, with two marked masks left.
        state.apply(.masksChanged(2))
        #expect(state.apply(.pictureChanged(3)) == .scan(after: delay))
        #expect(state.phase == .masked(2))
        state.apply(.scanFinished(3, kinds: .all, counts: one))
        #expect(state.phase == .found(one))
        #expect(state.action == .mask)
    }

    @Test func aClickWhileTheAutomaticScanRunsLeavesItsResultForTheUndo() {
        // The click's own scan finished first: it reports what it found, then the document's change.
        var state = opened()
        #expect(state.phase == .scanning)
        #expect(state.apply(.checked(1, kinds: .all, counts: three)) == .cancelScan)
        state.apply(.masksChanged(3))
        state.apply(.pictureChanged(2))
        state.apply(.checked(2, kinds: .all, counts: nothing))
        #expect(state.phase == .masked(3))
        // ⌘Z: the picture that was scanned, whose result is known: no scan.
        state.apply(.masksChanged(0))
        #expect(state.apply(.pictureChanged(1)) == .none)
        #expect(state.phase == .found(three))
    }

    @Test func maskingWorksWithTheMastersSwitchOff() {
        var state = opened(automatic: false)
        masked(&state, counts: three, masks: 3)
        #expect(state.phase == .masked(3))
        // Nothing scans afterwards, and with no masks the button is plain again.
        #expect(state.apply(.pictureChanged(3)) == .none)
        state.apply(.masksChanged(0))
        #expect(state.phase == .idle)
    }

    @Test func undoingMasksWithTheMastersSwitchOffShowsNoWarning() {
        var state = opened(automatic: false)
        masked(&state, counts: three, masks: 3)
        state.apply(.masksChanged(0))
        #expect(state.apply(.pictureChanged(1)) == .none)
        #expect(state.phase == .idle)
        #expect(!state.showsWarning)
    }

    @Test func aMaskedResultForOtherKindsThanNowIsStale() {
        // The kinds were changed while the masks were being made: the picture with the masks has no result for them.
        var state = scanned(three)
        state.apply(.settingsChanged(automatic: true, kinds: .contact))
        state.apply(.masksChanged(3))
        state.apply(.pictureChanged(2))
        #expect(state.apply(.checked(2, kinds: .all, counts: nothing)) == .none)
        #expect(state.phase == .masked(3))
        // The scan for the kinds now on is still wanted.
        #expect(state.apply(.scanFinished(2, kinds: .contact, counts: one)) == .none)
        #expect(state.phase == .found(one))
    }

    // MARK: Closing

    @Test func closingCancelsTheScanOnItsWay() {
        var state = opened()
        #expect(state.apply(.closed) == .cancelScan)
    }

    @Test func closingWithNothingOnItsWayCancelsNothing() {
        var state = scanned(three)
        #expect(state.apply(.closed) == .none)
    }

    @Test func aLateResultAfterClosingDoesNothing() {
        var state = opened()
        state.apply(.closed)
        let before = state
        #expect(state.apply(.scanFinished(1, kinds: .all, counts: three)) == .none)
        #expect(state.apply(.checked(1, kinds: .all, counts: three)) == .none)
        #expect(state.apply(.masksChanged(3)) == .none)
        #expect(state.apply(.pictureChanged(5)) == .none)
        #expect(state.apply(.settingsChanged(automatic: true, kinds: .cards)) == .none)
        #expect(state == before)
        #expect(!state.showsWarning)
    }

    // MARK: What can be clicked

    @Test func theButtonIsOnInEveryPhaseButDisabledAndWhileARunIsUnderWay() {
        let states: [State] = [State(), opened(), scanned(three), scanned(nothing), scanned(nothing, masks: 2), opened(masks: 2)]
        for state in states {
            #expect(state.isEnabled(maskRunning: false), "\(state.phase)")
            // One run at a time: the command refuses a second while one is under way.
            #expect(!state.isEnabled(maskRunning: true), "\(state.phase)")
        }
        #expect(!State(kinds: []).isEnabled(maskRunning: false))
    }

    @Test func onlyTheFoundPhaseShowsTheWarning() {
        #expect(!State().showsWarning)
        #expect(!opened().showsWarning)
        #expect(!scanned(nothing).showsWarning)
        #expect(!scanned(nothing, masks: 2).showsWarning)
        #expect(scanned(one).showsWarning)
        #expect(scanned(one, masks: 2).showsWarning)
        #expect(!State(kinds: []).showsWarning)
    }

    @Test func aClickUnmasksOnlyFromTheMaskedLook() {
        #expect(State().action == .mask)
        #expect(opened().action == .mask)
        #expect(scanned(three).action == .mask)
        #expect(scanned(nothing).action == .mask)
        #expect(scanned(one, masks: 2).action == .mask)
        #expect(scanned(nothing, masks: 2).action == .unmask)
        #expect(State(kinds: []).action == .mask)
    }

    // MARK: A whole session

    @Test func aSessionOfOpeningMaskingUndoingUnmaskingAndEditing() {
        var state = State()
        // The editor opens with no masks: scanned at once.
        #expect(state.apply(.pictureChanged(1)) == .scan(after: .zero))
        state.apply(.scanFinished(1, kinds: .all, counts: three))
        #expect(state.phase == .found(three))
        // Turned: scanned again after the delay, and the count is updated.
        #expect(state.apply(.pictureChanged(2)) == .scan(after: delay))
        state.apply(.scanFinished(2, kinds: .all, counts: FindingCounts([.contact: 2])))
        #expect(state.phase == .found(FindingCounts([.contact: 2])))
        // Clicked: masked (the turned picture's findings are covered by the picture with the masks, 3).
        state.apply(.checked(2, kinds: .all, counts: FindingCounts([.contact: 2])))
        state.apply(.masksChanged(2))
        state.apply(.pictureChanged(3))
        state.apply(.checked(3, kinds: .all, counts: nothing))
        #expect(state.phase == .masked(2))
        #expect(state.action == .unmask)
        // Clicked again: unmasked, back to the turned picture, whose result is known.
        state.apply(.masksChanged(0))
        #expect(state.apply(.pictureChanged(2)) == .none)
        #expect(state.phase == .found(FindingCounts([.contact: 2])))
        #expect(state.action == .mask)
        // The window closes.
        state.apply(.closed)
        #expect(state.apply(.pictureChanged(9)) == .none)
    }
}
