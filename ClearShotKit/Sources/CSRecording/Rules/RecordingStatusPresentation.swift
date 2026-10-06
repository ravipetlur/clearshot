/// How the menu bar item looks in each phase of a recording. While recording, a click on the item stops it, so the menu
/// is detached; it is back in every other phase.
public struct RecordingStatusPresentation: Sendable, Equatable {
    /// A second status item next to the main one.
    public enum Secondary: Sendable, Equatable {
        /// Resume, while paused.
        case resume
        /// "Creating GIF…" with its progress, 0…1.
        case converting(progress: Double)
    }

    static let normalSymbolName = "camera.viewfinder"
    static let recordingSymbolName = "stop.circle"

    /// Whether the item opens the status menu; false while a click stops the recording.
    public var usesMenu: Bool
    public var symbolName: String
    /// The elapsed time beside the icon, or nil for the icon alone.
    public var title: String?
    /// Shown even when the menu bar icon is hidden.
    public var forcesVisible: Bool
    public var secondary: Secondary?

    /// The presentation for `phase`. `elapsed` is the recording's length in seconds, shown when `showsTime` ("Display
    /// recording time in menu bar"); `conversionProgress` is the GIF conversion's, nil before it reports any.
    public static func make(phase: RecordingControlState.Phase, elapsed: Double, showsTime: Bool,
                            conversionProgress: Double?) -> RecordingStatusPresentation {
        switch phase {
        case .recording, .paused:
            RecordingStatusPresentation(usesMenu: false, symbolName: recordingSymbolName,
                                        title: showsTime ? ElapsedText.string(seconds: elapsed) : nil, forcesVisible: true,
                                        secondary: phase == .paused ? .resume : nil)
        case .converting:
            RecordingStatusPresentation(usesMenu: true, symbolName: normalSymbolName, title: nil, forcesVisible: false,
                                        secondary: .converting(progress: conversionProgress ?? 0))
        case .none, .selecting, .ready, .countdown, .finishing:
            RecordingStatusPresentation(usesMenu: true, symbolName: normalSymbolName, title: nil, forcesVisible: false,
                                        secondary: nil)
        }
    }
}
