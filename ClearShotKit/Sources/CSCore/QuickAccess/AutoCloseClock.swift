import Foundation

/// A thumbnail's auto-close countdown. It pauses while the pointer is over the thumbnail.
public struct AutoCloseClock: Sendable, Equatable {
    /// Time left when paused; meaningless while running.
    public private(set) var remaining: TimeInterval
    /// When the countdown ends, or nil while paused.
    public private(set) var deadline: Date?

    public init(interval: TimeInterval, now: Date) {
        remaining = interval
        deadline = now.addingTimeInterval(interval)
    }

    public var isPaused: Bool { deadline == nil }

    public mutating func pause(now: Date) {
        guard let deadline else { return }
        remaining = max(0, deadline.timeIntervalSince(now))
        self.deadline = nil
    }

    public mutating func resume(now: Date) {
        guard deadline == nil else { return }
        deadline = now.addingTimeInterval(remaining)
    }

    public func isExpired(now: Date) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }
}
