import CoreMedia

/// The tracks a recording writes.
public enum RecordingTrack: Sendable, Hashable {
    case video, systemAudio, microphone
}

/// Re-bases a recording's samples around its pauses. Everything is in the stream's clock (host time), never `Date`: a
/// pause from p to r removes [p, r) from every time after it, so the file plays straight through. Output times stay in
/// that clock; the writer's session starts at `start`.
public struct PauseTimeline: Sendable, Equatable {
    private struct Pause: Sendable, Equatable {
        var start: CMTime
        var end: CMTime
    }

    /// Video frames that would land on or before the previous one move this far past it.
    static let frameStep = CMTime(value: 1, timescale: 600)

    /// The session start, in the stream's clock.
    public private(set) var start: CMTime?
    public private(set) var isPaused = false
    /// Ended pauses, in order.
    private var pauses: [Pause] = []
    private var pauseStart: CMTime?
    /// Where each track's last placed sample ends (video: the last frame's time).
    private var trackEnds: [RecordingTrack: CMTime] = [:]

    public init() {}

    /// Starts the session at `time`, forgetting any earlier one.
    public mutating func begin(at time: CMTime) {
        self = PauseTimeline()
        start = time
    }

    /// Pauses at `time`. Does nothing before the start or while paused.
    public mutating func pause(at time: CMTime) {
        guard let start, !isPaused else { return }
        pauseStart = max(time, pauses.last?.end ?? start)
        isPaused = true
    }

    /// Resumes at `time`. Does nothing unless paused.
    public mutating func resume(at time: CMTime) {
        guard isPaused, let pauseStart else { return }
        pauses.append(Pause(start: pauseStart, end: max(time, pauseStart)))
        self.pauseStart = nil
        isPaused = false
    }

    /// Where a sample at `time` goes in the file, or nil to drop it.
    ///
    /// Nil before the start or inside a pause; else `time` minus the pauses that ended before it, clamped to the track's
    /// previous end (video: strictly after its previous frame). `duration` is zero for video; for audio it is the part
    /// that will be written, `keptDuration(at:duration:)`.
    public mutating func place(_ track: RecordingTrack, at time: CMTime, duration: CMTime) -> CMTime? {
        guard let start, time.isNumeric, time >= start, !isInsidePause(time) else { return nil }
        var placed = outputTime(at: time)
        if let end = trackEnds[track] {
            switch track {
            case .video:
                if placed <= end { placed = end + Self.frameStep }
            case .systemAudio, .microphone:
                if placed < end { placed = end }
            }
        }
        trackEnds[track] = track == .video ? placed : placed + duration
        return placed
    }

    /// How much of a sample at `time` lasting `duration` to keep: all of it, unless a pause starts inside it (the current
    /// pause, or an ended one for a late sample), when only the part before that start is kept, since the rest was
    /// captured while paused. Kept whole, the chunk would overhang the pause, and every contiguous chunk after the
    /// resume would be clamped behind it: the audio would fall up to a chunk further behind the video at every pause.
    public func keptDuration(at time: CMTime, duration: CMTime) -> CMTime {
        guard time.isNumeric, duration.isNumeric, duration > .zero else { return duration }
        let end = time + duration
        let starts = pauses.map(\.start) + (pauseStart.map { [$0] } ?? [])
        guard let cut = starts.first(where: { $0 > time && $0 < end }) else { return duration }
        return cut - time
    }

    /// `time` without the pauses that ended before it. A time inside a pause maps to where that pause began.
    public func outputTime(at time: CMTime) -> CMTime {
        var removed = CMTime.zero
        for pause in pauses {
            if time >= pause.end {
                removed = removed + (pause.end - pause.start)
            } else if time >= pause.start {
                return pause.start - removed
            } else {
                break
            }
        }
        if let pauseStart, time >= pauseStart { return pauseStart - removed }
        return time - removed
    }

    /// The recording's length at `time`: since the start, pauses excluded. Zero before the start.
    public func elapsed(at time: CMTime) -> CMTime {
        guard let start else { return .zero }
        return max(.zero, outputTime(at: time) - start)
    }

    private func isInsidePause(_ time: CMTime) -> Bool {
        if let pauseStart, time >= pauseStart { return true }
        return pauses.contains { time >= $0.start && time < $0.end }
    }
}
