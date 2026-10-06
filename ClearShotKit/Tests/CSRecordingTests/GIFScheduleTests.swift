import Testing
@testable import CSRecording

/// Frame timing: samples at the GIF's rate (at most 50) hold the latest source frame, boundaries round(100 k / fps)
/// carry the rounding, identical picks merge, and the last frame lasts to the trim end.
struct GIFScheduleTests {
    /// `count` frames at `fps`, from `start`.
    func frames(_ count: Int, fps: Double, from start: Double = 0) -> [Double] {
        (0..<count).map { start + Double($0) / fps }
    }

    @Test func aVariableRateSourceIsSampledAtTheGIFRate() {
        let picks = GIFSchedule.make(frameTimes: [0, 0.1, 0.5, 2.0], trim: 0...3, framesPerSecond: 10)
        #expect(picks.map(\.sourceIndex) == [0, 1, 2, 3])
        #expect(picks.map(\.delayCentiseconds) == [10, 40, 150, 100])
    }

    @Test func sixtyIsCappedAtFifty() {
        #expect(GIFSchedule.maximumFramesPerSecond == 50)
        #expect(GIFSchedule.minimumDelay == 2)
        #expect(GIFSchedule.effectiveFramesPerSecond(60) == 50)
        #expect(GIFSchedule.effectiveFramesPerSecond(30) == 30)
        let picks = GIFSchedule.make(frameTimes: frames(120, fps: 60), trim: 0...2, framesPerSecond: 60)
        #expect(picks.count == 100)
        #expect(picks.allSatisfy { $0.delayCentiseconds == 2 })
    }

    /// The boundaries 0, 3, 7, 10 give 3, 4, 3, not ImageIO's 3, 3, 3 that plays 11% fast.
    @Test func roundingIsCarried() {
        let picks = GIFSchedule.make(frameTimes: frames(90, fps: 30), trim: 0...3, framesPerSecond: 30)
        #expect(picks.count == 90)
        let delays = picks.map(\.delayCentiseconds)
        #expect(Array(delays.prefix(6)) == [3, 4, 3, 3, 4, 3])
        for second in 0..<3 {
            #expect(delays[(second * 30)..<((second + 1) * 30)].reduce(0, +) == 100)
        }
    }

    @Test func roundingIsCarriedOverALongRecording() {
        let picks = GIFSchedule.make(frameTimes: frames(18_000, fps: 30), trim: 0...600, framesPerSecond: 30)
        #expect(picks.count == 18_000)
        #expect(picks.map(\.delayCentiseconds).reduce(0, +) == 60_000)
    }

    /// A still screen sends one frame; the GIF is one frame lasting the whole trim.
    @Test func identicalPicksMerge() {
        let picks = GIFSchedule.make(frameTimes: [0], trim: 0...5, framesPerSecond: 30)
        #expect(picks == [GIFPick(sourceIndex: 0, delayCentiseconds: 500)])
    }

    /// Frames before the start count only as the first pick; frames after the end are ignored.
    @Test func theTrimIsHonoured() {
        let times = frames(120, fps: 30)
        let picks = GIFSchedule.make(frameTimes: times, trim: 1.01...2.5, framesPerSecond: 10)
        // At 1.01 s the latest frame is the one at 1.0 (index 30).
        #expect(picks.first?.sourceIndex == 30)
        #expect(picks.map(\.delayCentiseconds).reduce(0, +) == 149)
        #expect(picks.allSatisfy { $0.sourceIndex >= 30 && times[$0.sourceIndex] < 2.5 })
        // 15 samples, 1.01 … 2.41 s, each a different frame.
        #expect(picks.count == 15)
        #expect(picks.last?.sourceIndex == 72)
    }

    @Test func theLastFrameLastsUntilTheTrimEnd() {
        let picks = GIFSchedule.make(frameTimes: [0, 1], trim: 0...4, framesPerSecond: 30)
        #expect(picks == [GIFPick(sourceIndex: 0, delayCentiseconds: 100), GIFPick(sourceIndex: 1, delayCentiseconds: 300)])
        // Even a last frame shorter than the floor keeps the floor.
        let short = GIFSchedule.make(frameTimes: [0, 0.1], trim: 0...0.11, framesPerSecond: 10)
        #expect(short.map(\.delayCentiseconds) == [10, 2])
    }

    /// The streaming scheduler, fed frame by frame, and `make` both match the rule computed directly.
    @Test func theStreamingSchedulerMatchesMake() {
        var generator = SeededGenerator(seed: 7)
        for round in 0..<40 {
            var times: [Double] = []
            var time = Double.random(in: -0.3...0.2, using: &generator)
            for _ in 0..<Int.random(in: 1...300, using: &generator) {
                times.append(time)
                time += Double.random(in: 0.001...0.4, using: &generator)
            }
            let start = Double.random(in: 0...1, using: &generator)
            let trim = start...(start + Double.random(in: 0.1...8, using: &generator))
            let fps = [60, 50, 30, 25, 20, 15, 10][round % 7]

            var scheduler = GIFScheduler(framesPerSecond: fps, trim: trim)
            var streamed: [GIFPick] = []
            for time in times {
                streamed += scheduler.add(frameAt: time)
            }
            streamed += scheduler.finish()
            let expected = reference(times, trim: trim, fps: GIFSchedule.effectiveFramesPerSecond(fps))
            #expect(streamed == expected, "round \(round)")
            #expect(GIFSchedule.make(frameTimes: times, trim: trim, framesPerSecond: fps) == expected, "round \(round)")
        }
    }

    /// The rule, one sample at a time.
    func reference(_ times: [Double], trim: ClosedRange<Double>, fps: Int) -> [GIFPick] {
        let end = Int((100 * (trim.upperBound - trim.lowerBound)).rounded())
        func boundary(_ k: Int) -> Int { Int((100 * Double(k) / Double(fps)).rounded()) }
        var entries: [(source: Int, boundary: Int)] = []
        var k = 0
        while k == 0 || boundary(k) < end {
            let sample = trim.lowerBound + Double(k) / Double(fps)
            let source = times.lastIndex { $0 <= sample + GIFScheduler.timeTolerance } ?? 0
            if entries.last?.source != source { entries.append((source, boundary(k))) }
            k += 1
        }
        return entries.indices.map { index in
            let next = index + 1 < entries.count ? entries[index + 1].boundary : end
            return GIFPick(sourceIndex: entries[index].source, delayCentiseconds: max(2, next - entries[index].boundary))
        }
    }
}

/// A small deterministic generator (SplitMix64), so random tests repeat.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
