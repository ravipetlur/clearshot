/// What the three recording hotkeys mean in each phase of a recording. The hotkeys go straight to the recording flow,
/// which asks this table what to do.
public struct RecordingControlState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case none, selecting, ready, countdown, recording, paused, finishing, converting
    }

    public enum Hotkey: Sendable, CaseIterable {
        /// Record Screen, which stops a recording.
        case recordStop
        case pauseResume
        case restart
    }

    public enum Command: Sendable, Equatable {
        case openRecorder, startRecording, skipCountdown, stop, pause, resume, restart
        /// Nothing happens, and the HUD says why.
        case refuse(String)
        case none
    }

    public var phase: Phase

    public init(phase: Phase = .none) {
        self.phase = phase
    }

    /// The command `hotkey` gives in the current phase. Restart still asks for confirmation; that is the flow's job.
    public func command(for hotkey: Hotkey) -> Command {
        switch (phase, hotkey) {
        case (.none, .recordStop): .openRecorder
        case (.ready, .recordStop): .startRecording
        case (.countdown, .recordStop): .skipCountdown
        case (.recording, .recordStop), (.paused, .recordStop): .stop
        case (.recording, .pauseResume): .pause
        case (.paused, .pauseResume): .resume
        case (.recording, .restart), (.paused, .restart): .restart
        case (.finishing, .recordStop): .refuse("Still saving the recording")
        case (.converting, .recordStop): .refuse("Still creating a GIF")
        default: .none
        }
    }
}
