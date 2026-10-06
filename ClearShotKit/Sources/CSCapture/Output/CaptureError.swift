import Foundation

/// Capture failures, worded for the person using ClearShot.
public enum CaptureError: Error, LocalizedError, Equatable {
    case permissionDenied
    case displayNotFound
    case windowNotFound
    case captureFailed(String)
    case cannotCreateFolder(String)
    /// The format's encoder failed. The payload is the format's title, e.g. "WebP".
    case cannotEncode(String)
    case cannotSave(String)
    /// The working copy in the history folder is gone.
    case imageMissing
    /// Rotate, Flip, Scale or Resize failed.
    case cannotTransform

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "ClearShot needs Screen Recording permission"
        case .displayNotFound: "That display is no longer connected"
        case .windowNotFound: "That window closed before it could be captured"
        case .captureFailed: "The screenshot couldn't be taken"
        case .cannotCreateFolder(let path): "Couldn't create the folder \((path as NSString).abbreviatingWithTildeInPath)"
        case .cannotEncode(let format): "Couldn't create the \(format) image"
        case .cannotSave(let path): "Couldn't save to \((path as NSString).abbreviatingWithTildeInPath)"
        case .imageMissing: "The screenshot's image is missing"
        case .cannotTransform: "Couldn't change the image"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            "Turn on ClearShot in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        case .displayNotFound, .windowNotFound:
            "Try the capture again."
        case .captureFailed(let reason):
            "\(reason) Try again; if it keeps failing, check the log in Settings › About."
        case .cannotEncode:
            "Choose another file format in Settings › Screenshots, then try again."
        // Where the capture is instead (the clipboard, Quick Access) is the router's note to give.
        case .cannotCreateFolder, .cannotSave:
            "Choose another export location in Settings › General."
        case .imageMissing:
            "It may have been removed from ClearShot's history folder."
        case .cannotTransform:
            "Try again; if it keeps failing, check the log in Settings › About."
        }
    }
}
