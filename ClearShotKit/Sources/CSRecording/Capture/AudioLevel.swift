import Accelerate
import Foundation

/// How loud a buffer is, for the microphone meter.
public enum AudioLevel {
    /// Silence, in dBFS.
    public static let floor: Float = -160

    /// The RMS of `samples` in dBFS: a full-scale sine is −3 dB; `floor` for silence or no samples.
    public static func rmsDecibels(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return floor }
        let rms = vDSP.rootMeanSquare(samples)
        guard rms.isFinite, rms > 0 else { return floor }
        return max(floor, 20 * log10(rms))
    }

    /// The quietest level the meter shows, in dBFS; it is full at 0.
    public static let meterFloor: Float = -60

    /// How full the microphone meter is for `decibels`: 0 at −60 dBFS or below, 1 at 0 or above.
    public static func meterLevel(decibels: Float) -> Double {
        guard !decibels.isNaN else { return 0 }
        return Double(min(max((decibels - meterFloor) / -meterFloor, 0), 1))
    }
}
