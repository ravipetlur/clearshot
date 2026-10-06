/// When the microphone permission Ready couldn't ask for is asked: once, and only when nothing records. Not while Ready
/// is up, where the system's prompt could open under the overlay, and not during the countdown or the recording, whose
/// stream would capture it (the prompt belongs to another process). So the moments are Ready closing without a
/// recording, and the recording's end.
public struct MicrophonePermissionTiming: Sendable, Equatable {
    private enum Step: Sendable, Equatable {
        case ready, idle, recording
    }

    private var step = Step.ready
    private var hasDecided = false

    public init() {}

    /// Ready has closed, however.
    public mutating func readyClosed() {
        if step == .ready { step = .idle }
    }

    /// The countdown is about to start: nothing asks until `recordingEnded`.
    public mutating func recordingStarts() {
        step = .recording
    }

    /// The recording's windows have closed and its stream has stopped.
    public mutating func recordingEnded() {
        if step == .recording { step = .idle }
    }

    /// Whether to ask now. `needed`: a usable device is chosen and the permission is unanswered. The first moment
    /// nothing records decides, once; quitting asks nothing.
    public mutating func shouldAsk(needed: Bool, quitting: Bool) -> Bool {
        guard step == .idle, !hasDecided, !quitting else { return false }
        hasDecided = true
        return needed
    }
}

/// The microphone Ready handed over, through one recording. The recording sets its disconnection handler and then takes
/// it over (`MicrophoneCapture.isDisconnected`): one already gone records nothing (no track) and the start notice says
/// it was disconnected, as for one unplugged in Ready; one that goes later ends its track with the question. Either way
/// it is told once, however the two reports interleave.
public struct RecordingMicrophoneState: Sendable, Equatable {
    /// Disconnected, or failed: its samples and its track have stopped.
    public private(set) var hasEnded = false

    public init() {}

    /// The recording takes the microphone over; `alreadyDisconnected` is read after its handler was set. The start
    /// notice's issue when it went away in the handover, else nil.
    public mutating func takeOver(alreadyDisconnected: Bool) -> MicrophoneStartIssue? {
        guard alreadyDisconnected, !hasEnded else { return nil }
        hasEnded = true
        return .disconnected
    }

    /// The handler reported a disconnection (or the microphone wouldn't start): true when it ends now, so its track
    /// ends and the question is asked; false when it had already ended.
    public mutating func disconnected() -> Bool {
        guard !hasEnded else { return false }
        hasEnded = true
        return true
    }
}
