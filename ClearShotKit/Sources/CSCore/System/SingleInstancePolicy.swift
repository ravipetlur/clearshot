/// A running copy of ClearShot, as reported by `NSRunningApplication`.
public struct RunningInstance: Sendable, Equatable {
    public let pid: Int32
    public let isTerminated: Bool

    public init(pid: Int32, isTerminated: Bool) {
        self.pid = pid
        self.isTerminated = isTerminated
    }
}

/// Decides whether a newly launched copy should hand off to an existing one and quit.
public enum SingleInstancePolicy {
    public static func instanceToHandOffTo(running: [RunningInstance], currentPID: Int32) -> RunningInstance? {
        running.first { $0.pid != currentPID && !$0.isTerminated }
    }
}
