import Foundation
import Testing
@testable import CSWebP

/// How long the encoder takes. The test build is unoptimised, so this only catches a pathological slowdown; the real
/// figure is measured in a release build.
///
/// The time that counts is the CPU time of the thread that runs the encoder, not the wall time. These tests run beside
/// the rest of the suite, and wall time counts every moment the thread spends waiting for a core, which on a busy or
/// small machine can be a large part of it: one encode took some 8 seconds alone and 21 to 30 in the full run, against
/// the ceiling below. The encoder is single-threaded and the call never suspends, so the thread's CPU time is what the
/// encoding itself costs. It is not immune to load (a thread on a busy machine can land on a slower core, and the same
/// encode used 31 seconds of CPU time in one full run), so the ceiling stays generous.
struct EncoderSpeedTests {
    /// A generous ceiling for an unoptimised build, in seconds of CPU time.
    private static let ceiling = 60.0

    /// The CPU time the calling thread has used so far, in seconds.
    private static func threadCPUSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    }

    /// Encodes `image` and returns the file, the CPU time of the calling thread that took, and the wall time, which is
    /// only recorded.
    private static func encodeTimed(_ image: RGBAImage) throws -> (file: Data, cpuSeconds: Double, wallSeconds: Double) {
        let clock = ContinuousClock()
        let cpuBefore = threadCPUSeconds()
        var file = Data()
        let wall = try clock.measure {
            file = try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height)
        }
        let cpuSeconds = threadCPUSeconds() - cpuBefore
        let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
        return (file, cpuSeconds, wallSeconds)
    }

    @Test func aScreenshotOf2560x1440EncodesInReasonableTimeEvenUnoptimised() throws {
        let timed = try Self.encodeTimed(Fixtures.uiScreenshot(2560, 1440))
        Attachment.record("ui screenshot 2560x1440: \(timed.cpuSeconds) s of CPU time (wall \(timed.wallSeconds) s), "
                          + "\(timed.file.count) bytes", named: "encode-time")
        #expect(timed.cpuSeconds < Self.ceiling, "encoding took \(timed.cpuSeconds) s of CPU time")
        #expect(!timed.file.isEmpty)
    }

    @Test func aPhotoLikeImageOf2560x1440TakesThePredictorPathInReasonableTimeEvenUnoptimised() throws {
        // The screenshot above takes no transform, so this one is what keeps the predictor path under the guard.
        let timed = try Self.encodeTimed(Fixtures.noise(2560, 1440, seed: 1))
        Attachment.record("photo-like noise 2560x1440: \(timed.cpuSeconds) s of CPU time (wall \(timed.wallSeconds) s), "
                          + "\(timed.file.count) bytes", named: "encode-time-photo")
        #expect(StreamPeek.firstTransforms(of: timed.file) == [2, 0], "it takes the predictor path")
        #expect(timed.cpuSeconds < Self.ceiling, "encoding took \(timed.cpuSeconds) s of CPU time")
    }
}
