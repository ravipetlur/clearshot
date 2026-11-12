import Testing
@testable import CSSensitive

/// What Annotate's Mask Sensitive Info says: its result messages and the line it leaves in the log.
struct MaskCommandTextTests {
    // MARK: The counts

    @Test(arguments: [
        (0, "Nothing sensitive found"),
        // Not a count: a number below none is none.
        (-2, "Nothing sensitive found"),
        (1, "Masked 1 item"),
        (2, "Masked 2 items"),
        (3, "Masked 3 items"),
        (40, "Masked 40 items"),
    ])
    func theResultCountsTheMasksAdded(masksAdded: Int, text: String) {
        #expect(MaskCommandText.result(masksAdded: masksAdded) == text)
    }

    @Test(arguments: [
        (0, "Nothing to unmask"),
        (-1, "Nothing to unmask"),
        (1, "Unmasked 1 item"),
        (2, "Unmasked 2 items"),
        (3, "Unmasked 3 items"),
        (40, "Unmasked 40 items"),
    ])
    func theUnmaskResultCountsTheMasksTakenOut(masksRemoved: Int, text: String) {
        #expect(MaskCommandText.unmaskResult(masksRemoved: masksRemoved) == text)
    }

    // MARK: Mask All from a thumbnail

    @Test(arguments: [
        (1, false, "Masked 1 item"),
        (2, false, "Masked 2 items"),
        (40, false, "Masked 40 items"),
        // Says when the masked picture replaced the copy on the clipboard.
        (1, true, "Masked 1 item · Clipboard updated"),
        (3, true, "Masked 3 items · Clipboard updated"),
    ])
    func maskAllCountsTheMasksItAdded(masksAdded: Int, clipboardUpdated: Bool, text: String) {
        #expect(MaskCommandText.maskAllConfirmation(masksAdded: masksAdded, clipboardUpdated: clipboardUpdated) == text)
    }

    @Test func maskAllWordsTheCountAsAnnotateDoes() {
        for count in [1, 2, 5, 40] {
            #expect(MaskCommandText.maskAllConfirmation(masksAdded: count, clipboardUpdated: false) == MaskCommandText.result(masksAdded: count))
            #expect(MaskCommandText.maskAllConfirmation(masksAdded: count, clipboardUpdated: true).hasPrefix(MaskCommandText.result(masksAdded: count)))
        }
    }

    // MARK: The log

    @Test(arguments: [(3, "3 masks taken out"), (1, "1 mask taken out")])
    func theUnmaskLogLineHasTheCountOnly(masksRemoved: Int, text: String) {
        #expect(MaskCommandText.unmaskLogSummary(masksRemoved: masksRemoved) == text)
    }

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
