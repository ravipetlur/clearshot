import CoreMedia

/// Where a recording ends, in the stream's clock.
public enum RecordingStopTime {
    /// A stop ClearShot makes (Stop, a hotkey, sleep, quit) ends at `clock`, the stream's clock read just before the
    /// stream stops. A stream ScreenCaptureKit ended by itself (`streamEnded`) has no live clock worth reading by the
    /// time the stop is handled, so it ends at the later of the last sample the stream handed over and the newest
    /// microphone sample forwarded to the writer (which the stream never sees), so narration over a still screen isn't
    /// cut. Either falls back to the other when it has nothing; times that aren't numeric don't count. Nil when nothing
    /// is known.
    public static func make(streamEnded: Bool, clock: CMTime?, lastStreamSample: CMTime?,
                            lastMicrophoneSample: CMTime?) -> CMTime? {
        let clock = clock.flatMap(numeric)
        let latestSample = [lastStreamSample, lastMicrophoneSample].compactMap { $0.flatMap(numeric) }.max()
        return streamEnded ? latestSample ?? clock : clock ?? latestSample
    }

    private static func numeric(_ time: CMTime) -> CMTime? {
        time.isNumeric ? time : nil
    }
}
