/// What the alert after a launch's recovery says: a short title, and a line that says only what happened to the
/// recording, so it never claims a save that failed or waits for a name.
public enum RecoveryNotice {
    /// What became of the recovered recording's save to the export location.
    public enum Saved: Sendable, Equatable {
        case toExportLocation
        /// "Ask for name" holds the save for the thumbnail's name field.
        case waitingForName
        /// The save failed, for `reason`; the recording is in Capture History.
        case failed(reason: String)
    }

    public static let title = "Recording recovered"

    /// The alert's text; with `recordedAsGIF`, also that a GIF recording came back as its video.
    public static func message(saved: Saved, recordedAsGIF: Bool) -> String {
        let quit = "ClearShot quit unexpectedly, but your recording was recovered"
        var message = switch saved {
        case .toExportLocation:
            "\(quit) and saved to the export location."
        case .waitingForName:
            "\(quit). Name it in its thumbnail to save it to the export location."
        case .failed(let reason):
            "\(quit) to Capture History. It couldn't be saved to the export location: \(reason.trimmingTrailingPeriod)."
        }
        if recordedAsGIF { message += " It was recorded as a GIF and has been kept as a video." }
        return message
    }
}

private extension String {
    var trimmingTrailingPeriod: String {
        hasSuffix(".") ? String(dropLast()) : self
    }
}
