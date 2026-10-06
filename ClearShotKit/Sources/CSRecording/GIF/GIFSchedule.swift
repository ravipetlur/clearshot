/// One GIF frame: the source frame it shows and for how long.
public struct GIFPick: Sendable, Equatable {
    /// The source frame's index, in the order the frames were given.
    public let sourceIndex: Int
    public let delayCentiseconds: Int

    public init(sourceIndex: Int, delayCentiseconds: Int) {
        self.sourceIndex = sourceIndex
        self.delayCentiseconds = delayCentiseconds
    }
}

/// `GIFSchedule`'s rule, one source frame at a time, for an encoder that streams.
///
/// Sample k is at the trim's start + k / fps and shows the latest source frame at or before it (the first frame, for
/// samples before any frame). Its boundary is round(100 k / fps) centiseconds from the trim's start, so the rounding is
/// carried rather than lost frame by frame; the end boundary is round(100 × the trim's length), and the samples are
/// those whose boundary lies before it (always at least one). Consecutive samples of the same source frame merge into
/// one entry, which lasts until the next entry's first boundary (the last one, until the end), at least
/// `GIFSchedule.minimumDelay`. Frames before the trim's start count only as the first sample's; frames after its end
/// are never shown.
public struct GIFScheduler: Sendable {
    /// Allows for floating-point noise when a frame's time equals a sample's (0.5 + 1 / 30 against 16 / 30).
    static let timeTolerance = 0.000_001

    private let framesPerSecond: Int
    private let start: Double
    private let sampleCount: Int
    private let endBoundary: Int
    private var nextSample = 0
    private var frameCount = 0
    /// The latest frame given so far.
    private var latest: Int?
    /// The entry the samples so far end with; its length is known once a sample shows another frame, or at the end.
    private var pending: (source: Int, boundary: Int)?

    public init(framesPerSecond: Int, trim: ClosedRange<Double>) {
        let fps = GIFSchedule.effectiveFramesPerSecond(framesPerSecond)
        self.framesPerSecond = fps
        start = trim.lowerBound
        endBoundary = max(0, Int((100 * (trim.upperBound - trim.lowerBound)).rounded()))
        // round(100 k / fps) < E ⇔ 200 k < (2E − 1) fps.
        let product = (2 * endBoundary - 1) * fps
        sampleCount = max(1, product > 0 ? (product + 199) / 200 : 0)
    }

    /// The source frame the last entry so far shows, not yet given out: the one an encoder must keep.
    var pendingSourceIndex: Int? {
        pending?.source
    }

    /// The next source frame, at `time` seconds (times only grow). Returns the entries its arrival completes.
    public mutating func add(frameAt time: Double) -> [GIFPick] {
        let index = frameCount
        frameCount += 1
        var picks: [GIFPick] = []
        // Every sample before this frame shows the latest one before it.
        while nextSample < sampleCount, sampleTime(nextSample) < time - Self.timeTolerance {
            show(latest ?? index, atSample: nextSample, completing: &picks)
            nextSample += 1
        }
        latest = index
        return picks
    }

    /// No more frames: the remaining samples show the last one, and the last entry lasts until the trim's end.
    public mutating func finish() -> [GIFPick] {
        guard let latest else { return [] }
        var picks: [GIFPick] = []
        while nextSample < sampleCount {
            show(latest, atSample: nextSample, completing: &picks)
            nextSample += 1
        }
        if let pending {
            picks.append(GIFPick(sourceIndex: pending.source,
                                 delayCentiseconds: max(GIFSchedule.minimumDelay, endBoundary - pending.boundary)))
            self.pending = nil
        }
        return picks
    }

    private func sampleTime(_ sample: Int) -> Double {
        start + Double(sample) / Double(framesPerSecond)
    }

    /// round(100 k / fps), halves up, in integers.
    private func boundary(_ sample: Int) -> Int {
        (200 * sample + framesPerSecond) / (2 * framesPerSecond)
    }

    private mutating func show(_ source: Int, atSample sample: Int, completing picks: inout [GIFPick]) {
        let boundary = boundary(sample)
        if let pending {
            guard pending.source != source else { return }
            picks.append(GIFPick(sourceIndex: pending.source,
                                 delayCentiseconds: max(GIFSchedule.minimumDelay, boundary - pending.boundary)))
        }
        pending = (source, boundary)
    }
}

/// Which source frames a GIF shows and for how long: `GIFScheduler`'s rule over a whole list of frame times.
public enum GIFSchedule {
    /// Players slow down frames shorter than 2/100 s, so "60 (plays at 50)" samples at 50.
    public static let maximumFramesPerSecond = 50
    /// Centiseconds; browsers play shorter delays as 10.
    public static let minimumDelay = 2

    /// The rate a GIF is sampled at for the "Frame rate" setting: at most 50, at least 1.
    public static func effectiveFramesPerSecond(_ setting: Int) -> Int {
        min(max(setting, 1), maximumFramesPerSecond)
    }

    /// The GIF's entries for source frames at `frameTimes` (seconds, growing), over `trim`, at `framesPerSecond`.
    public static func make(frameTimes: [Double], trim: ClosedRange<Double>, framesPerSecond: Int) -> [GIFPick] {
        var scheduler = GIFScheduler(framesPerSecond: framesPerSecond, trim: trim)
        var picks: [GIFPick] = []
        for time in frameTimes {
            picks += scheduler.add(frameAt: time)
        }
        return picks + scheduler.finish()
    }
}
