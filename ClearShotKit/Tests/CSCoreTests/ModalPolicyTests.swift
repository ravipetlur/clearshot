import Testing
@testable import CSCore

/// No app-modal session overlaps a capture or a recording, in either direction.
struct ModalPolicyTests {
    typealias Flow = ModalPolicy.FlowState

    @Test(arguments: [(Flow.idle, ModalPolicy.Decision.ask), (.capturing, .wait), (.finishing, .wait)])
    func aReportWaitsUntilNothingIsUnderWay(flow: Flow, decision: ModalPolicy.Decision) {
        #expect(ModalPolicy.decide(.report, flow: flow) == decision)
    }

    @Test(arguments: [(Flow.idle, ModalPolicy.Decision.ask), (.capturing, .skip), (.finishing, .ask)])
    func aQuestionWhoseYesCanBeUndoneIsSkippedDuringACapture(flow: Flow, decision: ModalPolicy.Decision) {
        #expect(ModalPolicy.decide(.question(undoable: true), flow: flow) == decision)
    }

    @Test(arguments: [(Flow.idle, ModalPolicy.Decision.ask), (.capturing, .refuse), (.finishing, .ask)])
    func anyOtherQuestionIsRefusedDuringACapture(flow: Flow, decision: ModalPolicy.Decision) {
        #expect(ModalPolicy.decide(.question(undoable: false), flow: flow) == decision)
    }

    @Test(arguments: [Flow.idle, .capturing, .finishing])
    func aDocumentWindowAsksOnItsOwnWindow(flow: Flow) {
        #expect(ModalPolicy.decide(.inDocumentWindow, flow: flow) == .ask)
    }

    /// No question stacks on an app-modal alert or panel (the merge question, recovery's alert, a Save panel), whether
    /// or not its "yes" can be undone. Reports wait as before, and a document window's sheet isn't app-modal, so both
    /// ignore it.
    @Test(arguments: [Flow.idle, .capturing, .finishing])
    func aQuestionIsRefusedWhileAnAppModalWindowIsUp(flow: Flow) {
        #expect(ModalPolicy.decide(.question(undoable: false), flow: flow, appModalIsUp: true) == .refuse)
        #expect(ModalPolicy.decide(.question(undoable: true), flow: flow, appModalIsUp: true) == .refuse)
        #expect(ModalPolicy.decide(.report, flow: flow, appModalIsUp: true) == ModalPolicy.decide(.report, flow: flow))
        #expect(ModalPolicy.decide(.inDocumentWindow, flow: flow, appModalIsUp: true) == .ask)
    }

    /// Restore Last Capture brings a closed recording back, except under retention Never, which deletes it: then the
    /// question is refused during a capture rather than skipped, so nothing is deleted without a word.
    @Test func closingARecordingCanBeUndoneUnlessRetentionIsNever() {
        for retention in HistoryRetention.allCases {
            #expect(ModalPolicy.closingRecording(retention: retention) == .question(undoable: retention != .never))
        }
        #expect(ModalPolicy.decide(ModalPolicy.closingRecording(retention: .never), flow: .capturing) == .refuse)
        #expect(ModalPolicy.decide(ModalPolicy.closingRecording(retention: .oneWeek), flow: .capturing) == .skip)
    }

    /// The other direction: a capture's overlay never opens over an app-modal session it couldn't take events over.
    @Test func aCaptureDoesntStartWhileOneRunsOrAModalSessionIsUp() {
        #expect(!ModalPolicy.refusesCapture(isRunning: false, tailIsModal: false, appModalIsUp: false))
        #expect(ModalPolicy.refusesCapture(isRunning: true, tailIsModal: false, appModalIsUp: false))
        #expect(ModalPolicy.refusesCapture(isRunning: false, tailIsModal: true, appModalIsUp: false))
        #expect(ModalPolicy.refusesCapture(isRunning: false, tailIsModal: false, appModalIsUp: true))
    }

    /// A refusal says what is on screen. The open dialog comes first, since it is what has to close; then a recording
    /// or its countdown; anything else under way (an overlay, Ready, a capture, a scrolling capture) is a capture.
    @Test func theRefusalNamesTheCaptureUnlessARecordingIsOnScreen() {
        #expect(ModalPolicy.refusal(appModalIsUp: true, recordingOnScreen: true) == .appModal)
        #expect(ModalPolicy.refusal(appModalIsUp: true, recordingOnScreen: false) == .appModal)
        #expect(ModalPolicy.refusal(appModalIsUp: false, recordingOnScreen: true) == .recording)
        #expect(ModalPolicy.refusal(appModalIsUp: false, recordingOnScreen: false) == .capture)
    }

    @Test func eachRefusalSaysWhatToFinishOrClose() {
        #expect(ModalPolicy.Refusal.capture.text == "Finish the capture first")
        #expect(ModalPolicy.Refusal.capture.symbol == "camera.viewfinder")
        #expect(ModalPolicy.Refusal.recording.text == "Finish the recording first")
        #expect(ModalPolicy.Refusal.recording.symbol == "record.circle")
        #expect(ModalPolicy.Refusal.appModal.text == "Close the open dialog first")
        #expect(ModalPolicy.Refusal.appModal.symbol == "macwindow")
    }
}
