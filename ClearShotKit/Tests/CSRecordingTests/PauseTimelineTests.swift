import CoreMedia
import Testing
@testable import CSRecording

/// Times are host-clock seconds, as the stream delivers them, in nanoseconds.
func t(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
}

struct PauseTimelineTests {
    let chunk = t(0.02)

    @Test func samplesBeforeTheStartAreDropped() {
        var timeline = PauseTimeline()
        #expect(timeline.place(.video, at: t(1000), duration: .zero) == nil)
        timeline.begin(at: t(1000))
        #expect(timeline.start == t(1000))
        #expect(timeline.place(.video, at: t(999.9), duration: .zero) == nil)
        #expect(timeline.place(.systemAudio, at: t(999.5), duration: chunk) == nil)
        #expect(timeline.place(.video, at: t(1000), duration: .zero) == t(1000))
        #expect(timeline.place(.systemAudio, at: t(1000), duration: chunk) == t(1000))
    }

    @Test func samplesInsideAPauseAreDroppedAndLaterOnesShifted() {
        var timeline = PauseTimeline()
        timeline.begin(at: t(1000))
        #expect(timeline.place(.video, at: t(1001), duration: .zero) == t(1001))
        timeline.pause(at: t(1002))
        #expect(timeline.isPaused)
        #expect(timeline.place(.video, at: t(1003), duration: .zero) == nil)
        timeline.resume(at: t(1003.5))
        #expect(!timeline.isPaused)
        // A late frame from inside the pause is still dropped.
        #expect(timeline.place(.video, at: t(1003), duration: .zero) == nil)
        #expect(timeline.place(.video, at: t(1004), duration: .zero) == t(1002.5))
    }

    @Test func severalPausesAddUp() {
        var timeline = PauseTimeline()
        timeline.begin(at: t(1000))
        timeline.pause(at: t(1001))
        timeline.resume(at: t(1002))
        #expect(timeline.place(.microphone, at: t(1002.5), duration: chunk) == t(1001.5))
        timeline.pause(at: t(1003))
        timeline.resume(at: t(1005))
        #expect(timeline.place(.microphone, at: t(1006), duration: chunk) == t(1003))
        #expect(timeline.outputTime(at: t(1006)) == t(1003))
    }

    @Test func aSecondPauseOrAnEarlyResumeChangesNothing() {
        var timeline = PauseTimeline()
        timeline.begin(at: t(1000))
        timeline.resume(at: t(1001))
        #expect(timeline.outputTime(at: t(1002)) == t(1002))
        timeline.pause(at: t(1002))
        timeline.pause(at: t(1003))
        timeline.resume(at: t(1004))
        // The pause ran from the first pause, 1002, to 1004.
        #expect(timeline.place(.video, at: t(1005), duration: .zero) == t(1003))
    }

    /// The first chunk after a pause would start inside the last one before it; it starts where that one ends.
    @Test func overlappingAudioIsClampedToTheTracksEnd() {
        var timeline = PauseTimeline()
        timeline.begin(at: t(1000))
        #expect(timeline.place(.systemAudio, at: t(1001.99), duration: chunk) == t(1001.99))
        #expect(timeline.place(.microphone, at: t(1001.95), duration: chunk) == t(1001.95))
        timeline.pause(at: t(1002))
        timeline.resume(at: t(1003))
        #expect(timeline.place(.systemAudio, at: t(1003), duration: chunk) == t(1001.99) + chunk)
        // Each track keeps its own end: the microphone's ended at 1001.97.
        #expect(timeline.place(.microphone, at: t(1003), duration: chunk) == t(1002))
    }

    /// A chunk that begins before a pause and runs into it keeps only its part before the pause start, so the first
    /// chunk after the resume isn't pushed past the video by the rest.
    @Test func aChunkRunningIntoAPauseIsCutAtThePauseStart() {
        var timeline = PauseTimeline()
        timeline.begin(at: t(1000))
        #expect(timeline.keptDuration(at: t(1001.99), duration: chunk) == chunk)
        timeline.pause(at: t(1002))
        #expect(timeline.keptDuration(at: t(1001.97), duration: chunk) == chunk)
        #expect(timeline.keptDuration(at: t(1001.98), duration: chunk) == chunk)
        #expect(timeline.keptDuration(at: t(1001.99), duration: chunk) == t(1002) - t(1001.99))
        timeline.resume(at: t(1003))
        // Late, after the resume: still cut at the pause start, and the next chunk follows without a clamp.
        #expect(timeline.keptDuration(at: t(1001.995), duration: chunk) == t(1002) - t(1001.995))
        #expect(timeline.place(.systemAudio, at: t(1001.99), duration: t(1002) - t(1001.99)) == t(1001.99))
        #expect(timeline.place(.systemAudio, at: t(1003), duration: chunk) == t(1002))
        // After the resume nothing is cut, and video has no duration to cut.
        #expect(timeline.keptDuration(at: t(1003), duration: chunk) == chunk)
        #expect(timeline.keptDuration(at: t(1001.99), duration: .zero) == .zero)
    }

    /// A frame at the pause instant, then the first frame after the resume, which maps to the same output time.
    @Test func aVideoFrameAtThePauseInstantMovesPastThePreviousFrame() {
        var timeline = PauseTimeline()
        timeline.begin(at: t(1000))
        #expect(timeline.place(.video, at: t(1002), duration: .zero) == t(1002))
        timeline.pause(at: t(1002))
        timeline.resume(at: t(1003))
        let placed = timeline.place(.video, at: t(1003), duration: .zero)
        #expect(placed == t(1002) + CMTime(value: 1, timescale: 600))
        // Audio may start exactly where the track ended.
        #expect(timeline.place(.systemAudio, at: t(1001.98), duration: chunk) == t(1001.98))
        #expect(timeline.place(.systemAudio, at: t(1003), duration: chunk) == t(1002))
    }

    @Test func elapsedExcludesPauses() {
        var timeline = PauseTimeline()
        #expect(timeline.elapsed(at: t(1000)) == .zero)
        timeline.begin(at: t(1000))
        #expect(timeline.elapsed(at: t(1001.5)) == t(1.5))
        timeline.pause(at: t(1002))
        // While paused the clock stands still, and a pause instant maps to where the pause began.
        #expect(timeline.elapsed(at: t(1002.7)) == t(2))
        #expect(timeline.outputTime(at: t(1002.7)) == t(1002))
        timeline.resume(at: t(1003.5))
        #expect(timeline.elapsed(at: t(1005)) == t(3.5))
        #expect(timeline.outputTime(at: t(1003)) == t(1002))
    }

    /// The microphone's queue can deliver a chunk recorded before the pause after the pause began or ended.
    @Test func aLateSampleFromBeforeThePauseKeepsItsTime() {
        var timeline = PauseTimeline()
        timeline.begin(at: t(1000))
        timeline.pause(at: t(1002))
        #expect(timeline.place(.microphone, at: t(1001.5), duration: chunk) == t(1001.5))
        timeline.resume(at: t(1003))
        #expect(timeline.place(.microphone, at: t(1001.9), duration: chunk) == t(1001.9))
        #expect(timeline.place(.video, at: t(1001.8), duration: .zero) == t(1001.8))
    }
}
