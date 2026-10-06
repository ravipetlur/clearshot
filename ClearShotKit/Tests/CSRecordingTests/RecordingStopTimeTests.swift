import CoreMedia
import Testing
@testable import CSRecording

/// Where a recording ends: at the stream's clock when ClearShot stops it, at the latest sample when ScreenCaptureKit
/// stopped the stream itself, the microphone's included.
struct RecordingStopTimeTests {
    @Test func aStopClearShotMakesEndsAtTheStreamsClock() {
        let end = RecordingStopTime.make(streamEnded: false, clock: t(1010), lastStreamSample: t(1009.5),
                                         lastMicrophoneSample: t(1009.9))
        #expect(end == t(1010))
    }

    @Test func aStreamThatEndedItselfEndsAtItsLastSample() {
        let end = RecordingStopTime.make(streamEnded: true, clock: t(1012), lastStreamSample: t(1009.5),
                                         lastMicrophoneSample: nil)
        #expect(end == t(1009.5))
    }

    /// Narration over a still screen isn't cut back to the last screen sample.
    @Test func theMicrophoneCountsWhenItsSampleIsLater() {
        let later = RecordingStopTime.make(streamEnded: true, clock: t(1012), lastStreamSample: t(1009.5),
                                           lastMicrophoneSample: t(1009.8))
        #expect(later == t(1009.8))
        let earlier = RecordingStopTime.make(streamEnded: true, clock: t(1012), lastStreamSample: t(1009.5),
                                             lastMicrophoneSample: t(1008))
        #expect(earlier == t(1009.5))
    }

    @Test func withoutSamplesTheClockIsUsed() {
        #expect(RecordingStopTime.make(streamEnded: true, clock: t(1012), lastStreamSample: nil,
                                       lastMicrophoneSample: nil) == t(1012))
        #expect(RecordingStopTime.make(streamEnded: true, clock: t(1012), lastStreamSample: .invalid,
                                       lastMicrophoneSample: .invalid) == t(1012))
    }

    @Test func withoutAClockTheLatestSampleIsUsed() {
        #expect(RecordingStopTime.make(streamEnded: false, clock: nil, lastStreamSample: t(1009),
                                       lastMicrophoneSample: t(1009.2)) == t(1009.2))
        #expect(RecordingStopTime.make(streamEnded: false, clock: .invalid, lastStreamSample: nil,
                                       lastMicrophoneSample: nil) == nil)
    }
}
