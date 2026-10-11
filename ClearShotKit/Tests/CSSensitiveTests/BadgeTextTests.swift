import Testing
@testable import CSSensitive

/// What the badge says: its pill, its tooltip, what VoiceOver reads, and the one line a scan leaves in the log.
struct BadgeTextTests {
    private let mixed = FindingCounts([.contact: 2, .keyOrToken: 1])
    private func found(_ counts: FindingCounts) -> BadgeState { BadgeState(phase: .found(counts)) }
    private func masked(_ counts: FindingCounts) -> BadgeState { BadgeState(phase: .masked(counts)) }

    // MARK: The pill

    @Test func theFoundPillCountsTheFindings() {
        #expect(BadgeText.label(for: found(mixed)) == "\u{26A0}\u{FE0E} 3")
        #expect(BadgeText.label(for: found(FindingCounts([.card: 1]))) == "\u{26A0}\u{FE0E} 1")
        #expect(BadgeText.label(for: found(FindingCounts([.ipAddress: 12]))) == "\u{26A0}\u{FE0E} 12")
    }

    @Test func theCountStopsAtNinetyNinePlus() {
        #expect(BadgeText.label(for: found(FindingCounts([.contact: 99]))) == "\u{26A0}\u{FE0E} 99")
        #expect(BadgeText.label(for: found(FindingCounts([.contact: 60, .card: 40]))) == "\u{26A0}\u{FE0E} 99+")
        #expect(BadgeText.label(for: found(FindingCounts([.contact: 1000]))) == "\u{26A0}\u{FE0E} 99+")
    }

    @Test func theMaskedPillSaysSo() {
        #expect(BadgeText.label(for: masked(mixed)) == "Masked")
    }

    @Test func thereIsNoPillWhenThereIsNoBadge() {
        for phase in [BadgeState.Phase.scanning, .none, .dismissed] {
            let state = BadgeState(phase: phase)
            #expect(BadgeText.label(for: state) == nil, "\(phase)")
            #expect(BadgeText.tooltip(for: state) == nil, "\(phase)")
            #expect(BadgeText.accessibilityLabel(for: state) == nil, "\(phase)")
            #expect(BadgeText.accessibilityHelp(for: state) == nil, "\(phase)")
        }
    }

    // MARK: The tooltip

    @Test func theTooltipCountsTheFindingsByKind() {
        #expect(BadgeText.tooltip(for: found(mixed)) == "3 possible secrets: 2 contact details, 1 key or token")
        #expect(BadgeText.tooltip(for: found(FindingCounts([.card: 1]))) == "1 possible secret: 1 card number")
        #expect(BadgeText.tooltip(for: found(FindingCounts([.ipAddress: 2, .card: 2, .keyOrToken: 3, .contact: 1])))
                == "8 possible secrets: 1 contact detail, 3 keys or tokens, 2 card numbers, 2 IP addresses")
    }

    @Test func theTooltipOfAMaskedBadgeSaysWhatWasMasked() {
        #expect(BadgeText.tooltip(for: masked(mixed)) == "Masked 3 possible secrets: 2 contact details, 1 key or token")
        #expect(BadgeText.tooltip(for: masked(FindingCounts([.contact: 1]))) == "Masked 1 possible secret: 1 contact detail")
    }

    @Test func theMaskedTooltipCountsTheMasksAddedNotTheFindings() {
        // A finding in a background's frame has no mask, so there can be fewer masks than findings.
        #expect(BadgeText.tooltip(for: masked(mixed), masksAdded: 3) == "Masked 3 possible secrets: 2 contact details, 1 key or token")
        #expect(BadgeText.tooltip(for: masked(mixed), masksAdded: nil) == "Masked 3 possible secrets: 2 contact details, 1 key or token")
        #expect(BadgeText.tooltip(for: masked(mixed), masksAdded: 2) == "Masked 2 of 3 possible secrets")
        #expect(BadgeText.tooltip(for: masked(mixed), masksAdded: 1) == "Masked 1 of 3 possible secrets")
        #expect(BadgeText.tooltip(for: masked(FindingCounts([.card: 2])), masksAdded: 1) == "Masked 1 of 2 possible secrets")
        #expect(BadgeText.accessibilityLabel(for: masked(mixed), masksAdded: 2) == "Masked 2 of 3 possible secrets")
    }

    @Test func masksAddedDontChangeAFoundBadge() {
        #expect(BadgeText.tooltip(for: found(mixed), masksAdded: 1) == BadgeText.tooltip(for: found(mixed)))
        #expect(BadgeText.accessibilityLabel(for: found(mixed), masksAdded: 1) == BadgeText.accessibilityLabel(for: found(mixed)))
    }

    // MARK: VoiceOver

    @Test func voiceOverReadsTheSameCountsAndSaysWhatTheBadgeOpens() {
        #expect(BadgeText.accessibilityLabel(for: found(mixed)) == "3 possible secrets: 2 contact details, 1 key or token")
        #expect(BadgeText.accessibilityHelp(for: found(mixed)) == "Opens a menu with Mask All, Review in Annotate and Dismiss")
        #expect(BadgeText.accessibilityLabel(for: masked(mixed)) == "Masked 3 possible secrets: 2 contact details, 1 key or token")
        #expect(BadgeText.accessibilityHelp(for: masked(mixed)) == "Opens a menu with Undo Mask, Review in Annotate and Dismiss")
    }

    // MARK: The log line

    @Test func theLogLineHasCountsByKindAndNothingElse() {
        #expect(BadgeText.logSummary(for: mixed) == "3 findings (Contact details 2, Keys and tokens 1)")
        #expect(BadgeText.logSummary(for: FindingCounts([.card: 1])) == "1 finding (Card numbers 1)")
        #expect(BadgeText.logSummary(for: FindingCounts([])) == "no findings")
    }

    @Test func aDurationIsLoggedInSecondsWithTwoDecimals() {
        #expect(BadgeText.seconds(.milliseconds(1234)) == "1.23")
        #expect(BadgeText.seconds(.milliseconds(1500)) == "1.50")
        #expect(BadgeText.seconds(.milliseconds(126)) == "0.13")
        #expect(BadgeText.seconds(.seconds(90)) == "90.00")
        #expect(BadgeText.seconds(.zero) == "0.00")
        #expect(BadgeText.seconds(.seconds(2) + .milliseconds(1)) == "2.00")
    }
}
