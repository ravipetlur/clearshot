import Testing
@testable import CSSensitive

/// What Annotate's Mask Sensitive Info says: its name, its progress and result messages, and the line it leaves in the log.
struct MaskCommandTextTests {
    @Test func theCommandIsNamedAsTheMenuNamesIt() {
        #expect(MaskCommandText.commandName == "Mask Sensitive Info")
    }

    // MARK: The result

    @Test func severalMasksAreCounted() {
        #expect(MaskCommandText.result(masksAdded: 3) == "Masked 3 items")
        #expect(MaskCommandText.result(masksAdded: 2) == "Masked 2 items")
        #expect(MaskCommandText.result(masksAdded: 40) == "Masked 40 items")
    }

    @Test func oneMaskIsOneItem() {
        #expect(MaskCommandText.result(masksAdded: 1) == "Masked 1 item")
    }

    @Test func noMasksSaysNothingWasFound() {
        #expect(MaskCommandText.result(masksAdded: 0) == "Nothing sensitive found")
        // Not a count: a number below none is none.
        #expect(MaskCommandText.result(masksAdded: -2) == "Nothing sensitive found")
    }

    // MARK: Mask All from a thumbnail

    @Test func maskAllCountsTheMasksItAdded() {
        #expect(MaskCommandText.maskAllConfirmation(masksAdded: 1, clipboardUpdated: false) == "Masked 1 item")
        #expect(MaskCommandText.maskAllConfirmation(masksAdded: 2, clipboardUpdated: false) == "Masked 2 items")
        #expect(MaskCommandText.maskAllConfirmation(masksAdded: 40, clipboardUpdated: false) == "Masked 40 items")
    }

    @Test func maskAllSaysWhenTheMaskedPictureReplacedTheCopyOnTheClipboard() {
        #expect(MaskCommandText.maskAllConfirmation(masksAdded: 1, clipboardUpdated: true) == "Masked 1 item · Clipboard updated")
        #expect(MaskCommandText.maskAllConfirmation(masksAdded: 3, clipboardUpdated: true) == "Masked 3 items · Clipboard updated")
    }

    // MARK: Unmasking

    @Test func theUnmaskCommandIsNamedAsTheMenuNamesIt() {
        #expect(MaskCommandText.unmaskCommandName == "Unmask Sensitive Info")
    }

    @Test func severalMasksTakenOutAreCounted() {
        #expect(MaskCommandText.unmaskResult(masksRemoved: 3) == "Unmasked 3 items")
        #expect(MaskCommandText.unmaskResult(masksRemoved: 2) == "Unmasked 2 items")
        #expect(MaskCommandText.unmaskResult(masksRemoved: 40) == "Unmasked 40 items")
    }

    @Test func oneMaskTakenOutIsOneItem() {
        #expect(MaskCommandText.unmaskResult(masksRemoved: 1) == "Unmasked 1 item")
    }

    @Test func noMasksTakenOutSaysThereWasNothingToUnmask() {
        #expect(MaskCommandText.unmaskResult(masksRemoved: 0) == "Nothing to unmask")
        #expect(MaskCommandText.unmaskResult(masksRemoved: -1) == "Nothing to unmask")
    }

    @Test func aRefusedUnmaskSaysWhatToFinish() {
        #expect(MaskCommandText.unmaskEditInProgress == "Nothing unmasked: finish your edit, then try again.")
    }

    @Test func theUnmaskLogLineHasTheCountOnly() {
        #expect(MaskCommandText.unmaskLogSummary(masksRemoved: 3) == "3 masks taken out")
        #expect(MaskCommandText.unmaskLogSummary(masksRemoved: 1) == "1 mask taken out")
    }

    @Test func theClipboardNoteIsOneConstantAllTheMessagesShare() {
        // Mask All's confirmation and Done's message after masks were added say it in the same words.
        #expect(MaskCommandText.clipboardUpdated == "Clipboard updated")
        #expect(MaskCommandText.maskAllConfirmation(masksAdded: 2, clipboardUpdated: true) == "Masked 2 items · " + MaskCommandText.clipboardUpdated)
    }

    @Test func maskAllWordsTheCountAsAnnotateDoes() {
        for count in [1, 2, 5, 40] {
            #expect(MaskCommandText.maskAllConfirmation(masksAdded: count, clipboardUpdated: false) == MaskCommandText.result(masksAdded: count))
            #expect(MaskCommandText.maskAllConfirmation(masksAdded: count, clipboardUpdated: true).hasPrefix(MaskCommandText.result(masksAdded: count)))
        }
    }

    // MARK: The other messages

    @Test func theProgressAndProblemMessagesSaySoPlainly() {
        #expect(MaskCommandText.checking == "Checking for sensitive info…")
        #expect(MaskCommandText.couldntCheck == "Couldn't check this image for sensitive info")
        #expect(MaskCommandText.editInProgress == "Nothing masked: finish your edit, then try again.")
    }

    // MARK: The log

    @Test func theLogLineHasCountsAndKindsNames() {
        let counts = FindingCounts([.contact: 2, .keyOrToken: 1])
        #expect(MaskCommandText.logSummary(findings: counts, masksAdded: 3) == "3 findings (Contact details 2, Keys and tokens 1), 3 masks added")
    }

    @Test func theLogLineSingularisesAndSaysWhenNothingWasFound() {
        #expect(MaskCommandText.logSummary(findings: FindingCounts([.card: 1]), masksAdded: 1) == "1 finding (Card numbers 1), 1 mask added")
        #expect(MaskCommandText.logSummary(findings: FindingCounts([SensitiveKind: Int]()), masksAdded: 0) == "no findings, 0 masks added")
    }

    @Test func aFindingOutsideTheCaptureCountsButHasNoMask() {
        // Found and not masked: the log keeps both numbers, so the difference shows.
        let counts = FindingCounts([.ipAddress: 2])
        #expect(MaskCommandText.logSummary(findings: counts, masksAdded: 1) == "2 findings (IP addresses 2), 1 mask added")
    }
}
