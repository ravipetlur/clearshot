import CoreGraphics
import CSCapture
import Foundation

/// What a recording in progress leaves next to its file (`journal.json` in its Recordings folder), written before the
/// writer starts and again as it finishes, so a launch after a crash can recover the file, and turn Focus off again.
public struct RecordingJournal: Codable, Sendable, Equatable {
    public static let fileName = "journal.json"
    public static let currentVersion = 1

    public enum State: String, Codable, Sendable {
        case recording, finishing
    }

    public var version: Int
    public var startedAt: Date
    public var mode: RecordingMode
    public var state: State
    public var framesPerSecond: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixels per point of the recorded video.
    public var scale: Double
    /// The GIF settings the recording was started with, for a GIF recording.
    public var gifFrameRate: Int?
    public var gifQuality: Int?
    public var gifOptimize: Bool?
    public var displayID: UInt32
    /// The recorded rect in AppKit global points.
    public var globalRect: CGRect
    public var captureKind: CaptureKind
    public var systemAudio: Bool
    public var microphone: Bool
    /// Set once the Focus On shortcut has run, so recovery runs Focus Off.
    public var focusTurnedOn: Bool
    public var appName: String?
    public var appBundleID: String?
    public var windowTitle: String?
    /// How many launches have tried to recover the recording; nil before the first. Recovery gives up after
    /// `RecoveryPlanner.maximumAttempts` (older journals have none).
    public var recoveryAttempts: Int?

    public init(version: Int = RecordingJournal.currentVersion, startedAt: Date, mode: RecordingMode, state: State = .recording,
                framesPerSecond: Int, pixelWidth: Int, pixelHeight: Int, scale: Double, gifFrameRate: Int? = nil,
                gifQuality: Int? = nil, gifOptimize: Bool? = nil, displayID: UInt32, globalRect: CGRect,
                captureKind: CaptureKind, systemAudio: Bool, microphone: Bool, focusTurnedOn: Bool = false,
                appName: String? = nil, appBundleID: String? = nil, windowTitle: String? = nil) {
        self.version = version
        self.startedAt = startedAt
        self.mode = mode
        self.state = state
        self.framesPerSecond = framesPerSecond
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.gifFrameRate = gifFrameRate
        self.gifQuality = gifQuality
        self.gifOptimize = gifOptimize
        self.displayID = displayID
        self.globalRect = globalRect
        self.captureKind = captureKind
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.focusTurnedOn = focusTurnedOn
        self.appName = appName
        self.appBundleID = appBundleID
        self.windowTitle = windowTitle
    }

    /// A launch is trying to recover the recording: written before the attempt, so one that crashes counts too.
    public mutating func noteRecoveryAttempt() {
        recoveryAttempts = (recoveryAttempts ?? 0) + 1
    }
}
