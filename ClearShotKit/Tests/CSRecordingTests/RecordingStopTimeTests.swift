import CoreMedia
import Testing
@testable import CSRecording

/// Where a recording ends: at the stream's clock when ClearShot stops it, at the latest sample when ScreenCaptureKit
/// stopped the stream itself, the microphone's included.
struct RecordingStopTimeTests {
    @Test func theEndIsTheClockOrTheLatestSample() {
        let rows: [(case: String, streamEnded: Bool, clock: CMTime?, stream: CMTime?, microphone: CMTime?,
                    end: CMTime?)] = [
            ("a stop ClearShot makes ends at the stream's clock", false, t(1010), t(1009.5), t(1009.9), t(1010)),
            ("a stream that ended itself ends at its last sample", true, t(1012), t(1009.5), nil, t(1009.5)),
            // Narration over a still screen isn't cut back to the last screen sample.
            ("the microphone counts when its sample is later", true, t(1012), t(1009.5), t(1009.8), t(1009.8)),
            ("an earlier microphone sample does not", true, t(1012), t(1009.5), t(1008), t(1009.5)),
            ("without samples the clock is used", true, t(1012), nil, nil, t(1012)),
            ("invalid samples are no samples", true, t(1012), .invalid, .invalid, t(1012)),
            ("without a clock the latest sample is used", false, nil, t(1009), t(1009.2), t(1009.2)),
            ("with neither there is no end", false, .invalid, nil, nil, nil),
        ]
        for row in rows {
            #expect(RecordingStopTime.make(streamEnded: row.streamEnded, clock: row.clock, lastStreamSample: row.stream,
                                           lastMicrophoneSample: row.microphone) == row.end, "\(row.case)")
        }
    }
}
