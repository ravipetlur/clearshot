import Foundation
import Testing
@testable import CSRecording

/// The microphone meter's level, in dBFS, of synthetic samples.
struct AudioLevelTests {
    @Test func aFullScaleSineIsAboutMinus3dB() {
        // One second of 1 kHz at 48 kHz: a whole number of cycles. RMS 1/√2, so 20 · log10(0.7071) = −3.01 dB.
        let sine = (0..<48_000).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        let level = sine.withUnsafeBufferPointer(AudioLevel.rmsDecibels)
        #expect(abs(level - -3.01) <= 0.01)
        // A quarter of full scale is 12 dB quieter.
        let quarter = sine.map { $0 / 4 }.withUnsafeBufferPointer(AudioLevel.rmsDecibels)
        #expect(abs(quarter - -15.05) <= 0.01)
    }

    @Test func silenceIsTheFloor() {
        let silence = [Float](repeating: 0, count: 1024)
        #expect(silence.withUnsafeBufferPointer(AudioLevel.rmsDecibels) == -160)
        #expect([Float]().withUnsafeBufferPointer(AudioLevel.rmsDecibels) == -160)
        #expect(AudioLevel.floor == -160)
    }

    /// The meter shows −60…0 dBFS; anything quieter is empty, anything louder full.
    @Test func theMeterSpansMinusSixtyToZero() {
        #expect(AudioLevel.meterLevel(decibels: -60) == 0)
        #expect(AudioLevel.meterLevel(decibels: -30) == 0.5)
        #expect(AudioLevel.meterLevel(decibels: 0) == 1)
        #expect(AudioLevel.meterLevel(decibels: AudioLevel.floor) == 0)
        #expect(AudioLevel.meterLevel(decibels: 6) == 1)
        #expect(AudioLevel.meterLevel(decibels: .nan) == 0)
    }
}
