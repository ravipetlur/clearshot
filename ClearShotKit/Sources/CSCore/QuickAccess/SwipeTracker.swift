import CoreGraphics

/// Turns a two-finger trackpad scroll over a thumbnail into a gesture. A sideways swipe dismisses that thumbnail; a
/// downward swipe hides them all. Each gesture produces at most one outcome.
public struct SwipeTracker: Sendable {
    public enum Outcome: Sendable, Equatable {
        case none, dismiss, hideAll
    }

    public let threshold: CGFloat
    private var totalX: CGFloat = 0
    private var totalDown: CGFloat = 0
    private var finished = false

    public init(threshold: CGFloat = 60) {
        self.threshold = threshold
    }

    /// Starts a new gesture.
    public mutating func begin() {
        totalX = 0
        totalDown = 0
        finished = false
    }

    /// Adds one scroll event. `fingersDown` is positive when the fingers move toward the bottom of the trackpad,
    /// whatever the natural-scrolling setting.
    public mutating func add(deltaX: CGFloat, fingersDown: CGFloat) -> Outcome {
        guard !finished else { return .none }
        totalX += deltaX
        totalDown += fingersDown
        if abs(totalX) >= threshold, abs(totalX) > abs(totalDown) {
            finished = true
            return .dismiss
        }
        if totalDown >= threshold, totalDown > abs(totalX) {
            finished = true
            return .hideAll
        }
        return .none
    }
}
