import Foundation
import Testing
import CSUpdate

/// What a manual check says for each way it can stand or end, on each surface that can show it: the popover under the
/// status icon, and the line under Check Now in Settings › About.
struct CheckAnswerTests {
    static let v120 = VersionNumber("1.2.0")!
    static let v121 = VersionNumber("1.2.1")!

    func answer(_ outcome: CheckAnswer.Outcome, _ source: CheckSource) -> CheckAnswer {
        CheckAnswer(outcome, source: source)
    }

    struct Cell: Sendable, CustomTestStringConvertible {
        let outcome: CheckAnswer.Outcome
        let source: CheckSource
        let isShown: Bool
        let mark: CheckAnswer.Mark?
        let title: String
        let detail: String?
        let hasOKButton: Bool
        let autoCloseDelay: TimeInterval?
        let isPending: Bool

        var testDescription: String { "\(source) \(outcome)" }
    }

    /// Every way a check can stand or end, on each surface. Checking shows a spinner on both. Up to date has a checkmark,
    /// and only the popover closes by itself. A failure in the popover has a title, the plain reason and OK; in the
    /// About line it is the plain reason with a warning. An update found closes the popover (the offer window shows it)
    /// and says so in the About line.
    @Test(arguments: [
        Cell(outcome: .checking, source: .statusMenu, isShown: true, mark: .spinner, title: "Checking for updates\u{2026}",
             detail: nil, hasOKButton: false, autoCloseDelay: nil, isPending: true),
        Cell(outcome: .checking, source: .settings, isShown: true, mark: .spinner, title: "Checking\u{2026}",
             detail: nil, hasOKButton: false, autoCloseDelay: nil, isPending: true),
        Cell(outcome: .upToDate(CheckAnswerTests.v120), source: .statusMenu, isShown: true, mark: .checkmark,
             title: "ClearShot is up to date (1.2.0)", detail: nil, hasOKButton: false, autoCloseDelay: 4, isPending: false),
        Cell(outcome: .upToDate(CheckAnswerTests.v120), source: .settings, isShown: true, mark: .checkmark,
             title: "ClearShot is up to date (1.2.0)", detail: nil, hasOKButton: false, autoCloseDelay: nil, isPending: false),
        Cell(outcome: .failed(.network), source: .statusMenu, isShown: true, mark: .warning,
             title: "Couldn't check for updates", detail: UpdateFailure.network.message, hasOKButton: true,
             autoCloseDelay: nil, isPending: false),
        Cell(outcome: .failed(.rateLimited), source: .settings, isShown: true, mark: .warning,
             title: UpdateFailure.rateLimited.message, detail: nil, hasOKButton: false, autoCloseDelay: nil, isPending: false),
        Cell(outcome: .found(CheckAnswerTests.v121), source: .statusMenu, isShown: false, mark: nil, title: "Version 1.2.1 is available",
             detail: nil, hasOKButton: false, autoCloseDelay: nil, isPending: false),
        Cell(outcome: .found(CheckAnswerTests.v121), source: .settings, isShown: true, mark: .available, title: "Version 1.2.1 is available",
             detail: nil, hasOKButton: false, autoCloseDelay: nil, isPending: false),
    ])
    func eachOutcomeOnEachSurface(cell: Cell) {
        let answer = CheckAnswer(cell.outcome, source: cell.source)
        #expect(answer.isShown == cell.isShown)
        #expect(answer.mark == cell.mark)
        #expect(answer.title == cell.title)
        #expect(answer.detail == cell.detail)
        #expect(answer.hasOKButton == cell.hasOKButton)
        #expect(answer.autoCloseDelay == cell.autoCloseDelay)
        #expect(answer.isPending == cell.isPending)
    }

    /// The version is whatever the center says is current: an update installed since launch counts.
    @Test func upToDateNamesTheVersionItIsGiven() {
        #expect(answer(.upToDate(Self.v121), .statusMenu).title == "ClearShot is up to date (1.2.1)")
        #expect(answer(.upToDate(Self.v121), .settings).title == "ClearShot is up to date (1.2.1)")
        #expect(answer(.upToDate(VersionNumber("1.10.12")!), .settings).title == "ClearShot is up to date (1.10.12)")
    }

    /// Every failure's own words, for both surfaces: the answer adds nothing and drops nothing.
    @Test func everyFailureIsSaidInItsOwnWords() {
        for failure in UpdateFailure.allCases {
            #expect(answer(.failed(failure), .statusMenu).detail == failure.message, "\(failure)")
            #expect(answer(.failed(failure), .settings).title == failure.message, "\(failure)")
            #expect(!failure.message.isEmpty, "\(failure)")
        }
    }
}
