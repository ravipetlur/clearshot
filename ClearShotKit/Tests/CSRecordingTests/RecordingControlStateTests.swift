import Testing
@testable import CSRecording

struct RecordingControlStateTests {
    typealias Command = RecordingControlState.Command

    /// The table of what the three recording hotkeys mean: Record Screen / Stop, Pause/Resume, Restart in each phase.
    @Test func everyCellOfTheTable() {
        let table: [(RecordingControlState.Phase, [Command])] = [
            (.none, [.openRecorder, .none, .none]),
            (.selecting, [.none, .none, .none]),
            (.ready, [.startRecording, .none, .none]),
            (.countdown, [.skipCountdown, .none, .none]),
            (.recording, [.stop, .pause, .restart]),
            (.paused, [.stop, .resume, .restart]),
            (.finishing, [.refuse("Still saving the recording"), .none, .none]),
            (.converting, [.refuse("Still creating a GIF"), .none, .none]),
        ]
        #expect(RecordingControlState.Hotkey.allCases == [.recordStop, .pauseResume, .restart])
        for (phase, commands) in table {
            let state = RecordingControlState(phase: phase)
            #expect(RecordingControlState.Hotkey.allCases.map(state.command(for:)) == commands, "\(phase)")
        }
        #expect(RecordingControlState().phase == .none)
    }
}
