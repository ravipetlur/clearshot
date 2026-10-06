/// A video's size from its rates: (video + every audio track) × duration, or a GIF's from its own.
public enum FileSizeEstimate {
    /// In bytes, for rates in bits per second and a duration in seconds.
    public static func bytes(videoBitRate: Double, audioBitRates: [Double], duration: Double) -> Int64 {
        let bitsPerSecond = videoBitRate + audioBitRates.reduce(0, +)
        return Int64((bitsPerSecond * max(0, duration) / 8).rounded())
    }

    /// A file `bytes` long that lasts `duration` seconds, cut to `newDuration`: the same bytes per second (a GIF, whose
    /// size has no rate to plan from). `bytes` itself when `duration` isn't positive.
    public static func bytes(scaling bytes: Int64, from duration: Double, to newDuration: Double) -> Int64 {
        guard duration > 0 else { return bytes }
        return Int64((Double(bytes) * max(0, newDuration) / duration).rounded())
    }
}
