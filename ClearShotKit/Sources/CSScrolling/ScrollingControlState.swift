/// What the Start/Stop Capturing hotkey means in each phase of a scrolling capture: in Ready it starts a capture by
/// hand, while capturing it is Done, and otherwise (no session, no region yet, already finishing) nothing.
public struct ScrollingControlState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case none, selecting, ready, capturing, finishing
    }

    public enum Command: Sendable, Equatable {
        case start, finish, none
    }

    public var phase: Phase

    public init(phase: Phase = .none) {
        self.phase = phase
    }

    /// The command the hotkey gives now, moving to the phase it leads to.
    public mutating func startStop() -> Command {
        switch phase {
        case .ready:
            phase = .capturing
            return .start
        case .capturing:
            phase = .finishing
            return .finish
        case .none, .selecting, .finishing:
            return .none
        }
    }
}
