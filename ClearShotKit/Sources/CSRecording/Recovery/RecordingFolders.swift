import AVFoundation
import Foundation

/// One recording's folder in Recordings: its movie, its GIF (for a GIF recording) and its journal.
public struct RecordingFolder: Sendable, Equatable {
    public static let movieFileName = "recording.mp4"
    public static let gifFileName = "recording.gif"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var movieURL: URL { url.appending(path: Self.movieFileName) }
    public var gifURL: URL { url.appending(path: Self.gifFileName) }
    public var journalURL: URL { url.appending(path: RecordingJournal.fileName) }
}

/// The folder recordings are written in while they record (`<root>/<UUID>/`), and what a launch finds there.
public struct RecordingFolders: Sendable {
    /// Application Support/ClearShot/Recordings. Tests pass their own root.
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "ClearShot/Recordings", directoryHint: .isDirectory)
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Makes a new `<root>/<UUID>/` and writes `journal` there, before any writer exists. Leaves nothing behind when
    /// the journal can't be written.
    public func create(_ journal: RecordingJournal) throws -> RecordingFolder {
        let folder = RecordingFolder(url: root.appending(path: UUID().uuidString, directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        do {
            try write(journal, to: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder.url)
            throw error
        }
        return folder
    }

    /// Replaces the folder's journal, atomically.
    public func write(_ journal: RecordingJournal, to folder: RecordingFolder) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: folder.journalURL, options: .atomic)
    }

    /// Every `<UUID>` folder in the root, oldest first, with its journal (nil when missing or unreadable), its movie's
    /// playable length (nil when missing or unreadable) and its age from the folder's creation date. Other files and
    /// folders are ignored.
    @concurrent
    public func scan(now: Date = Date()) async -> [RecoveryCandidate] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        let folders = entries.compactMap { url -> (url: URL, created: Date)? in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else { return nil }
            return (url, values.creationDate ?? now)
        }
        var candidates: [RecoveryCandidate] = []
        for (url, created) in folders.sorted(by: { $0.created < $1.created }) {
            let folder = RecordingFolder(url: url)
            let journal = (try? Data(contentsOf: folder.journalURL)).flatMap {
                try? JSONDecoder().decode(RecordingJournal.self, from: $0)
            }
            candidates.append(RecoveryCandidate(folder: url, journal: journal,
                                                playableDuration: await Self.playableDuration(of: folder.movieURL),
                                                age: now.timeIntervalSince(created)))
        }
        return candidates
    }

    /// Where folders recovery gave up on go (`setAside`); not a `<UUID>`, so the scan never lists it.
    public static let setAsideFolderName = "Not Recovered"

    /// Moves a recording's folder that recovery gave up on into `<root>/Not Recovered/`, files and all, and returns
    /// where it went. Only folders directly in the root are moved.
    public func setAside(_ folder: URL) throws -> URL {
        guard isInRoot(folder) else { throw CocoaError(.fileNoSuchFile) }
        let aside = root.appending(path: Self.setAsideFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        let destination = aside.appending(path: folder.lastPathComponent, directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: folder, to: destination)
        return destination
    }

    /// Deletes a recording's folder. Only folders directly in the root are deleted.
    public func remove(_ folder: URL) {
        guard isInRoot(folder) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private func isInRoot(_ folder: URL) -> Bool {
        folder.deletingLastPathComponent().standardizedFileURL.pathComponents == root.standardizedFileURL.pathComponents
    }

    /// The movie's length in seconds when it opens with a video track, else nil. An interrupted fragmented file opens
    /// up to its last whole fragment.
    private static func playableDuration(of movie: URL) async -> Double? {
        guard FileManager.default.fileExists(atPath: movie.path(percentEncoded: false)) else { return nil }
        let asset = AVURLAsset(url: movie)
        guard let duration = try? await asset.load(.duration), duration.isNumeric,
              let videoTracks = try? await asset.loadTracks(withMediaType: .video), !videoTracks.isEmpty else { return nil }
        return duration.seconds
    }
}
