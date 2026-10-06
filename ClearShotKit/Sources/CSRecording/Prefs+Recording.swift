import CSCapture
import CSCore

/// What a recording makes: a video, or a GIF converted from an intermediate video when it stops.
public enum RecordingMode: String, CaseIterable, Sendable, Codable, PrefValue {
    case video, gif
}

/// Where the control bar sits while recording.
public enum RecordingControlsPosition: String, CaseIterable, Sendable, PrefValue {
    case belowArea, topOfScreen, bottomOfScreen

    public var title: String {
        switch self {
        case .belowArea: "Below the recording area"
        case .topOfScreen: "Top of the screen"
        case .bottomOfScreen: "Bottom of the screen"
        }
    }
}

/// The largest size a video is recorded or exported at: its longer side, keeping the aspect ratio.
public enum RecordingMaxResolution: String, CaseIterable, Sendable, PrefValue {
    case original, res4K, res1440p, res1080p, res720p, res480p

    public var title: String {
        switch self {
        case .original: "Original"
        case .res4K: "4K"
        case .res1440p: "1440p"
        case .res1080p: "1080p"
        case .res720p: "720p"
        case .res480p: "480p"
        }
    }

    /// The longer side in pixels, or nil for Original.
    public var longSide: Int? {
        switch self {
        case .original: nil
        case .res4K: 3840
        case .res1440p: 2560
        case .res1080p: 1920
        case .res720p: 1280
        case .res480p: 854
        }
    }
}

/// Highlight Clicks' options; `ClickRippleStyle` turns them into a ring.
public enum ClickHighlightSize: String, CaseIterable, Sendable, PrefValue {
    case small, medium, large
}

public enum ClickHighlightColor: String, CaseIterable, Sendable, PrefValue {
    case accent, red, purple, green, orange, yellow
}

public enum ClickHighlightStyle: String, CaseIterable, Sendable, PrefValue {
    case outline, filled
}

/// A GIF's largest size: 800 pixels wide when the recording is wider, or the recorded pixels.
public enum GIFMaxSize: String, CaseIterable, Sendable, PrefValue {
    case width800, original
}

/// With both system audio and the microphone: merged into one track after the recording stops, or kept as two.
public enum RecordingAudioTracks: String, CaseIterable, Sendable, PrefValue {
    case single, separate
}

/// The Screen Recording pane's settings and the recorder's remembered state.
public extension Prefs {
    /// Frame rates offered for video.
    static let recordingFrameRateChoices = [60, 50, 30, 25, 24, 15]
    /// Frame rates offered for GIFs. 60 plays at 50: players slow down GIF frames shorter than 2/100 s.
    static let gifFrameRateChoices = [60, 50, 30, 25, 20, 15, 10]

    // Recording
    static let recordingShowControls = PrefKey("recordingShowControls", default: true)
    static let recordingControlsPosition = PrefKey("recordingControlsPosition", default: RecordingControlsPosition.belowArea)
    static let recordingShowTimeInMenuBar = PrefKey("recordingShowTimeInMenuBar", default: true)
    static let recordingDimScreen = PrefKey("recordingDimScreen", default: true)
    static let recordingCountdown = PrefKey("recordingCountdown", default: true)
    static let recordingDoNotDisturb = PrefKey("recordingDoNotDisturb", default: true)
    static let recordingKeepDisplayAwake = PrefKey("recordingKeepDisplayAwake", default: true)
    static let recordingRememberSelection = PrefKey("recordingRememberSelection", default: true)
    static let recordingShowCursor = PrefKey("recordingShowCursor", default: true)

    // Highlight clicks
    static let recordingHighlightClicks = PrefKey("recordingHighlightClicks", default: true)
    static let clickHighlightSize = PrefKey("clickHighlightSize", default: ClickHighlightSize.medium)
    static let clickHighlightColor = PrefKey("clickHighlightColor", default: ClickHighlightColor.accent)
    static let clickHighlightStyle = PrefKey("clickHighlightStyle", default: ClickHighlightStyle.outline)
    static let clickHighlightAnimates = PrefKey("clickHighlightAnimates", default: true)

    // Video
    static let recordingFrameRate = PrefKey("recordingFrameRate", default: 60)
    static let recordingMaxResolution = PrefKey("recordingMaxResolution", default: RecordingMaxResolution.original)
    static let recordingScaleRetinaTo1x = PrefKey("recordingScaleRetinaTo1x", default: true)
    static let recordingHardwareEncoding = PrefKey("recordingHardwareEncoding", default: true)

    // GIF
    static let gifFrameRate = PrefKey("gifFrameRate", default: 60)
    static let gifOptimize = PrefKey("gifOptimize", default: true)
    static let gifQuality = PrefKey("gifQuality", default: 100)
    static let gifMaxSize = PrefKey("gifMaxSize", default: GIFMaxSize.width800)

    // Audio
    static let recordingSystemAudio = PrefKey("recordingSystemAudio", default: false)
    /// The microphone's device ID; "" is "Do Not Record Microphone".
    static let recordingMicrophoneID = PrefKey("recordingMicrophoneID", default: "")
    static let recordingMono = PrefKey("recordingMono", default: false)
    static let recordingAudioTracks = PrefKey("recordingAudioTracks", default: RecordingAudioTracks.single)
    /// The merge dialog's volumes, remembered between recordings (1 = 100%).
    static let recordingMergeMicVolume = PrefKey("recordingMergeMicVolume", default: 1.0)
    static let recordingMergeSystemVolume = PrefKey("recordingMergeSystemVolume", default: 1.0)

    // State
    static let recordingLastArea = PrefKey("recordingLastArea", default: SavedArea.none)
    static let recordingRatio = PrefKey("recordingRatio", default: SelectionRatio.freeform)
    static let recordingLastMode = PrefKey("recordingLastMode", default: RecordingMode.video)
    /// The one-time "Press to stop recording" hint next to the status item has been shown.
    static let stopRecordingHintShown = PrefKey("stopRecordingHintShown", default: false)

    // Warning dialogs: Restart and Delete ask first, with "Don't ask again".
    static let confirmDeleteRecording = PrefKey("confirmDeleteRecording", default: true)
    static let confirmRestartRecording = PrefKey("confirmRestartRecording", default: true)
    /// The recording confirmations "Reset All Warning Dialogs" resets, with `Prefs.warningDialogs`.
    static let recordingWarningDialogs: [PrefKey<Bool>] = [confirmDeleteRecording, confirmRestartRecording]
    /// Every confirmation with "Don't ask again", CSCore's and the recording's: what Settings › Advanced › Reset All
    /// Warning Dialogs resets.
    static let allWarningDialogs: [PrefKey<Bool>] = warningDialogs + recordingWarningDialogs
}
