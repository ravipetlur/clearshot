import AVFoundation
import Foundation

/// Turns a recording that was never finished (a crash, a kill, a failed writer) into a plain MP4: a fragmented file
/// opens up to its last whole fragment, and a passthrough export of it is an ordinary, defragmented file.
public enum RecoveryExporter {
    /// Exports `source` to `destination` (replacing any file there) and returns the result's duration in seconds.
    /// Throws `VideoFileError.unreadable` when the source doesn't open with a video track, `.exportFailed` when the
    /// export fails; the partial destination is removed.
    @concurrent
    public static func finalize(_ source: URL, to destination: URL) async throws -> Double {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw VideoFileError.exportFailed("The destination is the source file.")
        }
        let asset = AVURLAsset(url: source)
        let hasVideo: Bool
        do {
            hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        } catch {
            throw VideoFileError.unreadable(error.localizedDescription)
        }
        guard hasVideo else { throw VideoFileError.unreadable("The file has no video track.") }
        try? FileManager.default.removeItem(at: destination)
        do {
            try await RecordingExporter.exportPassthrough(asset, to: destination, progress: nil)
            return try await AVURLAsset(url: destination).load(.duration).seconds
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw RecordingExporter.mapped(error)
        }
    }
}
