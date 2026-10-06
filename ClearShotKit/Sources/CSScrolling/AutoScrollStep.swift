/// What one Auto-Scroll step did, as the stitched frames tell it: when the page has settled, and how far it moved,
/// which `AutoScrollPlanner.next(afterMoving:)` takes.
///
/// The page has settled once no frame has come for 100 ms after at least one did, or 300 ms after the step in any case
/// (an unchanged page sends no frames; an animation on it never stops sending them). It moved by the offsets accepted
/// since the step. When the step's latest frame had no verified match the distance is unknown (nil): the page ended up
/// where the stitch can't follow it, and the planner scrolls back.
public struct AutoScrollStep: Sendable {
    /// How long no frame may come, after one did, before the page counts as settled.
    public static let quietTime: Duration = .milliseconds(100)
    /// The longest a step waits for the page to settle.
    public static let longestWait: Duration = .milliseconds(300)

    public let startedAt: ContinuousClock.Instant
    private var lastFrameAt: ContinuousClock.Instant?
    private var acceptedPixels = 0
    private var lastFrameHadNoMatch = false

    /// A step whose scroll was posted at `startedAt`.
    public init(startedAt: ContinuousClock.Instant) {
        self.startedAt = startedAt
    }

    /// A frame of the region was stitched at `time`.
    public mutating func note(_ update: StitchUpdate, at time: ContinuousClock.Instant) {
        lastFrameAt = time
        if update.accepted { acceptedPixels += update.offset }
        lastFrameHadNoMatch = update.noMatch
    }

    public func isSettled(at time: ContinuousClock.Instant) -> Bool {
        if time - startedAt >= Self.longestWait { return true }
        guard let lastFrameAt else { return false }
        return time - lastFrameAt >= Self.quietTime
    }

    /// The page's movement since the step in points (accepted offsets are source pixels); nil when the latest frame had
    /// no verified match.
    public func movedPoints(pixelsPerPoint: Double) -> Int? {
        guard !lastFrameHadNoMatch else { return nil }
        return Int((Double(acceptedPixels) / (pixelsPerPoint > 0 ? pixelsPerPoint : 1)).rounded())
    }
}
