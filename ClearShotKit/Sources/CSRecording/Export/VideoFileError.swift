import Foundation

/// Why a recording or a video file couldn't be written, read or exported.
public enum VideoFileError: Error, LocalizedError, Equatable {
    case noVideoTrack
    case cannotConfigureWriter
    /// The file can't be opened as a video; the reason AVFoundation gave.
    case unreadable(String)
    /// An export or a finish failed; the reason AVFoundation gave.
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The source file does not contain a video track."
        case .cannotConfigureWriter: "Could not configure the video writer."
        case let .unreadable(reason): "The video file can't be read: \(reason)"
        case let .exportFailed(reason): "The video couldn't be exported: \(reason)"
        }
    }
}
