import Testing
@testable import CSRecording

struct SilenceDetectorTests {
    /// What the detector reports for each chunk, in order.
    func reports(_ detector: inout SilenceDetector, _ chunks: [(level: Float, seconds: Double)]) -> [Bool] {
        chunks.map { detector.add(levelDecibels: $0.level, seconds: $0.seconds) }
    }

    @Test func fiveSecondsOfSilenceReportOnce() {
        var detector = SilenceDetector()
        let silence = reports(&detector, Array(repeating: (-70, 1), count: 8))
        #expect(silence == [false, false, false, false, true, false, false, false])
        // −60 dBFS itself isn't below the threshold.
        var atThreshold = SilenceDetector()
        let quiet = reports(&atThreshold, Array(repeating: (-60, 1), count: 6))
        #expect(!quiet.contains(true))
    }

    @Test func aLoudChunkResets() {
        var detector = SilenceDetector(thresholdDecibels: -60, duration: 5)
        let chunks: [(level: Float, seconds: Double)] = Array(repeating: (-80, 1), count: 4) + [(-20, 0.1)]
            + Array(repeating: (-80, 1), count: 5)
            // A new silent stretch after a loud chunk reports again.
            + [(-10, 0.1), (-90, 5)]
        #expect(reports(&detector, chunks) == [false, false, false, false, false, false, false, false, false, true, false, true])
    }
}
