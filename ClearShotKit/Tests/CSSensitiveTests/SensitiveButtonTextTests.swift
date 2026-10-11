import Testing
@testable import CSSensitive

/// What the sensitive-info button says in each phase: its label ("⚠︎ 3" while findings wait), its tooltip, what VoiceOver
/// reads and what it says a click does. The counts are worded as the thumbnail's badge words them.
struct SensitiveButtonTextTests {
    private let mixed = FindingCounts([.contact: 2, .keyOrToken: 1])
    private let found = SensitiveButtonPhase.found(FindingCounts([.contact: 2, .keyOrToken: 1]))
    private let plain: [SensitiveButtonPhase] = [.idle, .scanning, .none]
    private let masked = SensitiveButtonPhase.masked(3)

    // MARK: The label

    @Test func theLabelCountsTheFindingsAfterAWarningSign() {
        #expect(SensitiveButtonText.label(for: found) == "\u{26A0}\u{FE0E} 3")
        #expect(SensitiveButtonText.label(for: .found(FindingCounts([.card: 1]))) == "\u{26A0}\u{FE0E} 1")
        #expect(SensitiveButtonText.label(for: .found(FindingCounts([.ipAddress: 12]))) == "\u{26A0}\u{FE0E} 12")
    }

    @Test func theLabelStopsAtNinetyNinePlusSoTheButtonKeepsOneWidth() {
        #expect(SensitiveButtonText.label(for: .found(FindingCounts([.contact: 99]))) == "\u{26A0}\u{FE0E} 99")
        #expect(SensitiveButtonText.label(for: .found(FindingCounts([.contact: 60, .card: 40]))) == "\u{26A0}\u{FE0E} 99+")
    }

    @Test func theLabelIsTheBadgesLabel() {
        let counts = FindingCounts([.contact: 7, .ipAddress: 5])
        #expect(SensitiveButtonText.label(for: .found(counts)) == BadgeText.label(for: BadgeState(phase: .found(counts))))
    }

    @Test func aPlainOrMaskedButtonHasNoLabelAndShowsItsSymbolAlone() {
        for phase in plain + [masked, .disabled] {
            #expect(SensitiveButtonText.label(for: phase) == nil, "\(phase)")
        }
    }

    // MARK: The tooltip

    @Test func theTooltipCountsTheFindingsByKind() {
        #expect(SensitiveButtonText.tooltip(for: found) == "3 possible secrets: 2 contact details, 1 key or token")
        #expect(SensitiveButtonText.tooltip(for: .found(FindingCounts([.card: 1]))) == "1 possible secret: 1 card number")
        #expect(SensitiveButtonText.tooltip(for: .found(FindingCounts([.ipAddress: 2, .card: 2, .keyOrToken: 3, .contact: 1])))
                == "8 possible secrets: 1 contact detail, 3 keys or tokens, 2 card numbers, 2 IP addresses")
    }

    @Test func theFoundTooltipIsTheBadgesTooltip() {
        let counts = FindingCounts([.contact: 7, .ipAddress: 5])
        #expect(SensitiveButtonText.tooltip(for: .found(counts)) == BadgeText.tooltip(for: BadgeState(phase: .found(counts))))
    }

    @Test func aMaskedButtonCountsTheMasksAndSaysAClickUnmasks() {
        #expect(SensitiveButtonText.tooltip(for: .masked(3)) == "3 possible secrets masked: click to unmask")
        #expect(SensitiveButtonText.tooltip(for: .masked(12)) == "12 possible secrets masked: click to unmask")
    }

    @Test func oneMaskIsOnePossibleSecret() {
        #expect(SensitiveButtonText.tooltip(for: .masked(1)) == "1 possible secret masked: click to unmask")
    }

    @Test func thePlainPhasesSayWhatTheyAre() {
        #expect(SensitiveButtonText.tooltip(for: .idle) == "Mask Sensitive Info")
        #expect(SensitiveButtonText.tooltip(for: .idle) == MaskCommandText.commandName)
        #expect(SensitiveButtonText.tooltip(for: .scanning) == "Checking for sensitive info…")
        #expect(SensitiveButtonText.tooltip(for: .scanning) == MaskCommandText.checking)
        #expect(SensitiveButtonText.tooltip(for: .none) == "No possible secrets found")
    }

    @Test func aDisabledButtonSaysWhy() {
        #expect(SensitiveButtonText.tooltip(for: .disabled) == "Mask Sensitive Info is off: no kind is switched on in Settings › Quick Access")
    }

    // MARK: VoiceOver

    @Test func voiceOverReadsTheTooltip() {
        for phase in plain + [found, masked, .disabled] {
            #expect(SensitiveButtonText.accessibilityLabel(for: phase) == SensitiveButtonText.tooltip(for: phase), "\(phase)")
        }
    }

    @Test func voiceOverIsToldWhatAClickDoes() {
        #expect(SensitiveButtonText.accessibilityHelp(for: found) == "Masks every possible secret in the picture, as one undo step")
        for phase in plain {
            #expect(SensitiveButtonText.accessibilityHelp(for: phase) == "Looks for sensitive info in the picture and masks it, as one undo step", "\(phase)")
        }
        #expect(SensitiveButtonText.accessibilityHelp(for: masked) == "Takes out the masks the sensitive-info check added, as one undo step")
        #expect(SensitiveButtonText.accessibilityHelp(for: .disabled) == "Switch on a kind of sensitive info in Settings › Quick Access to use it")
    }

    // MARK: The Edit menu's item

    @Test func theMenuItemIsNamedAsTheStateSaysAClickDoes() {
        #expect(SensitiveButtonText.menuTitle(for: masked) == "Unmask Sensitive Info")
        for phase in plain + [found, .disabled] {
            #expect(SensitiveButtonText.menuTitle(for: phase) == "Mask Sensitive Info", "\(phase)")
        }
    }

    @Test func theMenuTitlesAreTheCommandsNames() {
        #expect(SensitiveButtonText.menuTitle(for: .idle) == MaskCommandText.commandName)
        #expect(SensitiveButtonText.menuTitle(for: masked) == MaskCommandText.unmaskCommandName)
    }

    @Test func withNoEditorAnsweringTheItemIsTheMaskCommandAndNeverUnmask() {
        // A History or Settings window in front leaves the item disabled, and it must not say "Unmask".
        #expect(SensitiveButtonText.menuTitleWithNoEditor == "Mask Sensitive Info")
        #expect(SensitiveButtonText.menuTitleWithNoEditor == MaskCommandText.commandName)
        #expect(SensitiveButtonText.menuTitleWithNoEditor == SensitiveButtonText.menuTitle(for: .idle))
        #expect(SensitiveButtonText.menuTitleWithNoEditor != SensitiveButtonText.menuTitle(for: masked))
    }

    @Test func theMenuTitleFollowsTheActionTheClickTakes() {
        // The same decision twice: the title says what `action` does.
        var state = SensitiveButtonState<Int>()
        state.apply(.pictureChanged(1))
        state.apply(.scanFinished(1, kinds: .all, counts: FindingCounts([])))
        #expect(state.action == .mask)
        #expect(SensitiveButtonText.menuTitle(for: state.phase) == MaskCommandText.commandName)
        state.apply(.masksChanged(2))
        #expect(state.action == .unmask)
        #expect(SensitiveButtonText.menuTitle(for: state.phase) == MaskCommandText.unmaskCommandName)
    }
}
