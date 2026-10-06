/// The part of a video a trim keeps, in seconds from its start.
public struct TrimRange: Sendable, Equatable {
    public static let minimumLength = 0.1
    /// Allows for floating-point noise when comparing lengths and frame boundaries.
    private static let tolerance = 0.000_000_1

    public let start: Double
    public let end: Double

    /// The range from `start` to `end`, made valid for a video `duration` long: clamped to 0…duration, at least
    /// `minimumLength` (the end moves later, or at the end of the video the start moves earlier), and with
    /// `framesPerSecond` both ends snapped to the nearest frame boundary. The duration counts as a boundary even off the
    /// frame grid. A video shorter than `minimumLength` is kept whole.
    public init(start: Double, end: Double, duration: Double, framesPerSecond: Double?) {
        let duration = max(0, duration)
        let rate = framesPerSecond.flatMap { $0 > 0 ? $0 : nil }
        func clamped(_ time: Double) -> Double { min(max(time, 0), duration) }
        func nearest(_ time: Double) -> Double {
            guard let rate else { return time }
            return min((time * rate).rounded() / rate, duration)
        }
        func atOrAfter(_ time: Double) -> Double {
            guard let rate else { return min(time, duration) }
            return min((time * rate - Self.tolerance).rounded(.up) / rate, duration)
        }
        func atOrBefore(_ time: Double) -> Double {
            guard let rate else { return max(time, 0) }
            return max((time * rate + Self.tolerance).rounded(.down) / rate, 0)
        }
        func isTooShort(_ start: Double, _ end: Double) -> Bool { end - start < Self.minimumLength - Self.tolerance }

        var (lower, upper) = (clamped(start), clamped(end))
        if upper < lower { (lower, upper) = (upper, lower) }
        (lower, upper) = (nearest(lower), nearest(upper))
        if isTooShort(lower, upper) {
            upper = atOrAfter(lower + Self.minimumLength)
            if isTooShort(lower, upper) {
                upper = duration
                lower = atOrBefore(duration - Self.minimumLength)
            }
        }
        self.start = lower
        self.end = upper
    }
}
