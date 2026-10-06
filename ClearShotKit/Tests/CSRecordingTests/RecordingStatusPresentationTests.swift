import Testing
@testable import CSRecording

struct RecordingStatusPresentationTests {
    func make(_ phase: RecordingControlState.Phase, elapsed: Double = 65, showsTime: Bool = true,
              progress: Double? = nil) -> RecordingStatusPresentation {
        RecordingStatusPresentation.make(phase: phase, elapsed: elapsed, showsTime: showsTime, conversionProgress: progress)
    }

    @Test func theMenuIsBackInEveryPhaseWithoutARecording() {
        for phase: RecordingControlState.Phase in [.none, .selecting, .ready, .countdown, .finishing] {
            let shown = make(phase)
            #expect(shown.usesMenu, "\(phase)")
            #expect(shown.symbolName == "camera.viewfinder", "\(phase)")
            #expect(shown.title == nil, "\(phase)")
            #expect(!shown.forcesVisible, "\(phase)")
            #expect(shown.secondary == nil, "\(phase)")
        }
    }

    @Test func recordingShowsStopAndTheTime() {
        let shown = make(.recording)
        #expect(!shown.usesMenu)
        #expect(shown.symbolName == "stop.circle")
        #expect(shown.title == "1:05")
        #expect(shown.forcesVisible)
        #expect(shown.secondary == nil)
        // Without "Display recording time in menu bar", the icon alone.
        let untimed = make(.recording, showsTime: false)
        #expect(untimed.title == nil)
        #expect(untimed.symbolName == "stop.circle")
    }

    @Test func pausedAddsResume() {
        let shown = make(.paused, elapsed: 7)
        #expect(!shown.usesMenu)
        #expect(shown.symbolName == "stop.circle")
        #expect(shown.title == "0:07")
        #expect(shown.forcesVisible)
        #expect(shown.secondary == .resume)
    }

    @Test func convertingKeepsTheMenuAndShowsProgress() {
        let shown = make(.converting, progress: 0.4)
        #expect(shown.usesMenu)
        #expect(shown.symbolName == "camera.viewfinder")
        #expect(shown.title == nil)
        #expect(shown.secondary == .converting(progress: 0.4))
        #expect(make(.converting).secondary == .converting(progress: 0))
    }
}
