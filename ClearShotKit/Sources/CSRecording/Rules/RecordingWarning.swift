/// What can go wrong around a recording: each warning's title, message and buttons.
public enum RecordingWarning: Sendable, Equatable {
    case microphoneMuted, microphoneDisconnected, systemAudioFailed, lowDiskBefore, diskFull, startFailed, streamStopped

    public var title: String {
        switch self {
        case .microphoneMuted: "Microphone is muted"
        case .microphoneDisconnected: "Microphone Disconnected"
        case .systemAudioFailed: "Audio Recording Failed"
        case .lowDiskBefore: "Your free disk space is low."
        case .diskFull: "The disk is almost full, so the recording stopped."
        case .startFailed: "Screen recording couldn't start."
        case .streamStopped: "Screen Recording stopped unexpectedly."
        }
    }

    public var message: String {
        switch self {
        case .microphoneMuted:
            "The microphone seems to be muted. Keep recording?"
        case .microphoneDisconnected:
            "The microphone was disconnected. Keep recording without it, or stop?"
        case .systemAudioFailed:
            // Information only: ScreenCaptureKit stops the whole stream when system audio fails, so a failure at the
            // start restarts it without audio; one mid-recording ends the recording ("Recording stopped").
            "Unable to capture system audio. The recording continues without it."
        case .lowDiskBefore:
            "The recording could stop partway through, and the file could be lost."
        case .diskFull:
            "ClearShot stopped it so the file wouldn't be lost. Free up disk space before the next recording."
        case .startFailed:
            "Protected (DRM) video playing in another app can cause this. If it keeps happening, restart your Mac."
        case .streamStopped:
            "Screen recording ran into an error."
        }
    }

    /// The buttons, the default first.
    public var buttons: [String] {
        switch self {
        case .microphoneMuted: ["Continue", "Stop"]
        case .microphoneDisconnected: ["Continue Without Audio", "Stop"]
        case .lowDiskBefore: ["Record Anyway", "Cancel"]
        case .systemAudioFailed, .diskFull, .startFailed, .streamStopped: ["OK"]
        }
    }
}

/// When free disk space stops or warns about a recording. Sizes are in bytes.
public enum DiskSpaceRule {
    /// A recording stops gracefully, keeping what's written, below this.
    public static let stopBelow: Int64 = 1_000_000_000
    /// Starting a recording warns below this…
    public static let warnBelow: Int64 = 2_000_000_000
    /// …or below this many minutes at the planned rate.
    public static let warnMinutes = 10.0

    public static func warnsBeforeRecording(available: Int64, plannedBitsPerSecond: Int) -> Bool {
        let tenMinutes = warnMinutes * 60 * Double(plannedBitsPerSecond) / 8
        return available < warnBelow || Double(available) < tenMinutes
    }

    public static func stopsRecording(available: Int64) -> Bool {
        available < stopBelow
    }

    /// Merging the audio tracks after a recording needs this to spare beyond the recording's size.
    public static let mergeHeadroom: Int64 = 100_000_000

    /// Whether there is room to merge a recording of `fileBytes` into a second file: its size plus `mergeHeadroom`.
    /// Unknown free space (nil) doesn't stop it; the export then fails on its own if the disk fills.
    public static func allowsMerge(available: Int64?, fileBytes: Int64) -> Bool {
        guard let available else { return true }
        return available >= fileBytes + mergeHeadroom
    }
}

/// Notices a microphone that records only silence (a muted mic): chunk levels below the threshold add up, a louder
/// chunk starts over, and each silent stretch is reported once.
public struct SilenceDetector: Sendable {
    private let thresholdDecibels: Float
    private let duration: Double
    private var silentSeconds = 0.0
    private var hasReported = false

    public init(thresholdDecibels: Float = -60, duration: Double = 5) {
        self.thresholdDecibels = thresholdDecibels
        self.duration = duration
    }

    /// Adds a chunk `seconds` long at `levelDecibels` (dBFS). True once, when the silence has lasted `duration`.
    public mutating func add(levelDecibels: Float, seconds: Double) -> Bool {
        guard levelDecibels < thresholdDecibels else {
            silentSeconds = 0
            hasReported = false
            return false
        }
        silentSeconds += seconds
        guard !hasReported, silentSeconds >= duration else { return false }
        hasReported = true
        return true
    }
}
