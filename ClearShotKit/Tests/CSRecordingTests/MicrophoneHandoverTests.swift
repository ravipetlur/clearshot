import Testing
@testable import CSRecording

struct MicrophoneHandoverTests {
    /// The deferred permission prompt (h): once, and only when nothing records, so it never opens under Ready's overlay
    /// or in the video.
    @Test func thePermissionIsAskedOnceAndOnlyWhenNothingRecords() {
        // Ready closes without a recording: asked then, and only then.
        var closed = MicrophonePermissionTiming()
        let whileReady = closed.shouldAsk(needed: true, quitting: false)
        closed.readyClosed()
        let afterReady = [closed.shouldAsk(needed: true, quitting: false), closed.shouldAsk(needed: true, quitting: false)]
        #expect(!whileReady)
        #expect(afterReady == [true, false])

        // Ready closes into a recording: nothing during the countdown or the recording, then once it has ended.
        var recorded = MicrophonePermissionTiming()
        recorded.readyClosed()
        recorded.recordingStarts()
        let during = recorded.shouldAsk(needed: true, quitting: false)
        recorded.recordingEnded()
        let after = [recorded.shouldAsk(needed: true, quitting: false), recorded.shouldAsk(needed: true, quitting: false)]
        #expect(!during)
        #expect(after == [true, false])

        // Not needed (no device chosen, or the permission already answered) when the moment comes: never asked.
        var unneeded = MicrophonePermissionTiming()
        unneeded.readyClosed()
        let notNeeded = [unneeded.shouldAsk(needed: false, quitting: false), unneeded.shouldAsk(needed: true, quitting: false)]
        #expect(notNeeded == [false, false])

        // Quitting asks nothing.
        var quitting = MicrophonePermissionTiming()
        quitting.readyClosed()
        quitting.recordingStarts()
        quitting.recordingEnded()
        let whileQuitting = quitting.shouldAsk(needed: true, quitting: true)
        #expect(!whileQuitting)
    }

    /// The microphone Ready handed over (j): one disconnected before the recording took it is told as a start issue and
    /// records nothing; one disconnected later asks the question once; a disconnection reported both ways is told once.
    @Test func aMicrophoneLostInTheHandoverIsToldOnceAsAStartIssue() {
        var kept = RecordingMicrophoneState()
        let keptIssue = kept.takeOver(alreadyDisconnected: false)
        #expect(keptIssue == nil)
        #expect(!kept.hasEnded)
        // Unplugged mid-recording: its track ends and the question is asked, once.
        let reports = [kept.disconnected(), kept.disconnected()]
        #expect(reports == [true, false])
        #expect(kept.hasEnded)

        var lost = RecordingMicrophoneState()
        let lostIssue = lost.takeOver(alreadyDisconnected: true)
        #expect(lostIssue == .disconnected)
        #expect(lost.hasEnded)
        // The handler's report of the same disconnection, arriving after the takeover, says nothing more.
        let lateReport = lost.disconnected()
        #expect(!lateReport)

        // Reported through the handler first: the takeover adds no start notice.
        var reportedFirst = RecordingMicrophoneState()
        let first = reportedFirst.disconnected()
        let reportedIssue = reportedFirst.takeOver(alreadyDisconnected: true)
        #expect(first)
        #expect(reportedIssue == nil)
    }
}
