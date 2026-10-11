import Testing
import CSUpdate

/// What a manual check says for each way it can stand or end, on each surface that can show it: the popover under the
/// status icon, and the line under Check Now in Settings › About.
struct CheckAnswerTests {
    let v120 = VersionNumber("1.2.0")!
    let v121 = VersionNumber("1.2.1")!

    func answer(_ outcome: CheckAnswer.Outcome, _ source: CheckSource) -> CheckAnswer {
        CheckAnswer(outcome, source: source)
    }

    // MARK: Checking

    @Test func theStatusMenuPopoverOpensWithChecking() {
        let answer = answer(.checking, .statusMenu)
        #expect(answer.isShown)
        #expect(answer.mark == .spinner)
        #expect(answer.title == "Checking for updates\u{2026}")
        #expect(answer.detail == nil)
        #expect(!answer.hasOKButton)
        #expect(answer.autoCloseDelay == nil)
        #expect(answer.isPending)
    }

    @Test func theAboutLineSaysChecking() {
        let answer = answer(.checking, .settings)
        #expect(answer.isShown)
        #expect(answer.mark == .spinner)
        #expect(answer.title == "Checking\u{2026}")
        #expect(answer.detail == nil)
        #expect(!answer.hasOKButton)
        #expect(answer.autoCloseDelay == nil)
        #expect(answer.isPending)
    }

    // MARK: Up to date

    @Test func upToDateInThePopoverHasACheckmarkAndClosesByItself() {
        let answer = answer(.upToDate(v120), .statusMenu)
        #expect(answer.isShown)
        #expect(answer.mark == .checkmark)
        #expect(answer.title == "ClearShot is up to date (1.2.0)")
        #expect(answer.detail == nil)
        #expect(!answer.hasOKButton)
        #expect(answer.autoCloseDelay == 4)
        #expect(!answer.isPending)
    }

    @Test func upToDateInTheAboutLineHasACheckmarkAndStays() {
        let answer = answer(.upToDate(v120), .settings)
        #expect(answer.isShown)
        #expect(answer.mark == .checkmark)
        #expect(answer.title == "ClearShot is up to date (1.2.0)")
        #expect(answer.detail == nil)
        #expect(!answer.hasOKButton)
        #expect(answer.autoCloseDelay == nil)
        #expect(!answer.isPending)
    }

    /// The version is whatever the center says is current: an update installed since launch counts.
    @Test func upToDateNamesTheVersionItIsGiven() {
        #expect(answer(.upToDate(v121), .statusMenu).title == "ClearShot is up to date (1.2.1)")
        #expect(answer(.upToDate(v121), .settings).title == "ClearShot is up to date (1.2.1)")
        #expect(answer(.upToDate(VersionNumber("1.10.12")!), .settings).title == "ClearShot is up to date (1.10.12)")
    }

    // MARK: Failed

    @Test func aFailureInThePopoverHasATitleThePlainReasonAndOK() {
        let answer = answer(.failed(.network), .statusMenu)
        #expect(answer.isShown)
        #expect(answer.mark == .warning)
        #expect(answer.title == "Couldn't check for updates")
        #expect(answer.detail == UpdateFailure.network.message)
        #expect(answer.hasOKButton)
        #expect(answer.autoCloseDelay == nil)
        #expect(!answer.isPending)
    }

    @Test func aFailureInTheAboutLineIsItsPlainReasonWithAWarning() {
        let answer = answer(.failed(.rateLimited), .settings)
        #expect(answer.isShown)
        #expect(answer.mark == .warning)
        #expect(answer.title == UpdateFailure.rateLimited.message)
        #expect(answer.detail == nil)
        #expect(!answer.hasOKButton)
        #expect(answer.autoCloseDelay == nil)
        #expect(!answer.isPending)
    }

    /// Every failure's own words, for both surfaces: the answer adds nothing and drops nothing.
    @Test func everyFailureIsSaidInItsOwnWords() {
        for failure in UpdateFailure.allCases {
            #expect(answer(.failed(failure), .statusMenu).detail == failure.message, "\(failure)")
            #expect(answer(.failed(failure), .settings).title == failure.message, "\(failure)")
            #expect(!failure.message.isEmpty, "\(failure)")
        }
    }

    // MARK: Found

    @Test func anUpdateFoundClosesTheStatusMenuPopover() {
        let answer = answer(.found(v121), .statusMenu)
        #expect(!answer.isShown)
        #expect(answer.mark == nil)
        #expect(answer.title == "Version 1.2.1 is available")
        #expect(!answer.hasOKButton)
        #expect(answer.autoCloseDelay == nil)
        #expect(!answer.isPending)
    }

    @Test func anUpdateFoundSaysSoInTheAboutLine() {
        let answer = answer(.found(v121), .settings)
        #expect(answer.isShown)
        #expect(answer.mark == .available)
        #expect(answer.title == "Version 1.2.1 is available")
        #expect(answer.detail == nil)
        #expect(!answer.hasOKButton)
        #expect(answer.autoCloseDelay == nil)
        #expect(!answer.isPending)
    }

    // MARK: Both surfaces

    /// Only the popover closes by itself, and only when it is up to date: a failure stays until OK, and the line under the
    /// button stays until the pane closes or a new check starts.
    @Test func onlyAnUpToDatePopoverClosesByItself() {
        let outcomes: [CheckAnswer.Outcome] = [.checking, .upToDate(v120), .failed(.network), .failed(.serverError), .found(v121)]
        for source in CheckSource.allCases {
            for outcome in outcomes {
                let delay = answer(outcome, source).autoCloseDelay
                if source == .statusMenu, case .upToDate = outcome {
                    #expect(delay == 4, "\(source) \(outcome)")
                } else {
                    #expect(delay == nil, "\(source) \(outcome)")
                }
            }
        }
    }

    /// Only a failure in the popover has a button.
    @Test func onlyAFailureInThePopoverHasAnOKButton() {
        let outcomes: [CheckAnswer.Outcome] = [.checking, .upToDate(v120), .failed(.network), .found(v121)]
        for source in CheckSource.allCases {
            for outcome in outcomes {
                let expected: Bool
                if source == .statusMenu, case .failed = outcome { expected = true } else { expected = false }
                #expect(answer(outcome, source).hasOKButton == expected, "\(source) \(outcome)")
            }
        }
    }

    /// Everything but an update found in the popover has something to show, and a mark to show with it.
    @Test func everythingShownHasAMarkAndATitle() {
        let outcomes: [CheckAnswer.Outcome] = [.checking, .upToDate(v120), .failed(.network), .found(v121)]
        for source in CheckSource.allCases {
            for outcome in outcomes {
                let answer = answer(outcome, source)
                guard answer.isShown else { continue }
                #expect(answer.mark != nil, "\(source) \(outcome)")
                #expect(!answer.title.isEmpty, "\(source) \(outcome)")
            }
        }
    }

    @Test func theAnswerKeepsItsSourceAndOutcome() {
        let answer = answer(.upToDate(v120), .settings)
        #expect(answer.source == .settings)
        #expect(answer.outcome == .upToDate(v120))
    }
}
