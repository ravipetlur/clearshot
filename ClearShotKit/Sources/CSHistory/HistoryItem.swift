import CoreGraphics
import CSCapture
import Foundation

/// What an item holds. Studio projects aren't built: `studioProject` is kept only so an old `meta.json` that names it
/// still decodes. A build can't decode a kind it doesn't know, so it skips that item and keeps its folder.
public enum MediaKind: String, Codable, Sendable {
    case screenshot, video, gif, studioProject
}

/// Where a history item came from. Images opened from Finder or the clipboard are kept too.
public enum HistoryOrigin: String, Codable, Sendable {
    case capture, clipboard, file
}

/// One capture in the history folder, stored as `meta.json` in its own folder.
public struct HistoryItem: Codable, Sendable, Identifiable, Equatable {
    /// Starts with a dot, which `FileNamer.sanitize` never leaves at the start of a name, and `HistoryWriter` sanitizes
    /// the working copy's name, so the two can't clash.
    public static let thumbnailFileName = ".thumb.png"
    public static let metadataFileName = "meta.json"

    public var id: UUID
    public var kind: MediaKind
    public var origin: HistoryOrigin
    public var captureKind: CaptureKind
    public var createdAt: Date
    /// The working copy's file name in the item folder: the sanitized display name at creation plus the media's
    /// extension (`.png` for screenshots). Only its extension ever changes, when an edit writes another format
    /// (`HistoryWriter.replaceMedia`: an opened `.mov` becomes `.mp4`).
    public var mediaFileName: String
    /// The name the capture is saved under, without extension.
    public var displayName: String
    /// The file the person saved, if any.
    public var savedPath: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixels per point.
    public var scale: Double
    public var appName: String?
    /// A window shot with a transparent background; saved as PNG when the chosen format can't hold transparency.
    public var isTransparent: Bool
    /// The captured rect in AppKit global points, for the saved file's metadata. Zero for opened images.
    public var globalRect: CGRect
    /// The saved file's modification date when ClearShot last wrote it.
    public var savedFileDate: Date?
    /// The item has an Annotate document (`document.json`, `.original.png`) and its working copy is a render of it. Nil
    /// (older items) and false mean it was never annotated.
    public var hasDocument: Bool?
    /// When the working copy was last written: `createdAt` at creation, then the time of each
    /// `HistoryWriter.replaceImage` or `.replaceMedia`. Metadata changes (a saved path, a name) leave it alone. Nil for
    /// older items.
    public var modifiedAt: Date?
    /// The bundle ID of the app the capture was taken in, if known.
    public var appBundleID: String?
    /// The title of the window the capture was taken in, if known.
    public var windowTitle: String?
    /// For `origin == .file`: the path of the file the item was imported from.
    public var sourcePath: String?
    /// A video's or GIF's length in seconds. Nil for screenshots (and their older items).
    public var duration: Double?
    /// Whether the media has an audio track (never, for a GIF). Nil for screenshots.
    public var hasAudio: Bool?

    public init(id: UUID, kind: MediaKind, origin: HistoryOrigin, captureKind: CaptureKind, createdAt: Date,
                mediaFileName: String, displayName: String, savedPath: String?, pixelWidth: Int, pixelHeight: Int,
                scale: Double, appName: String?, isTransparent: Bool, globalRect: CGRect, savedFileDate: Date? = nil,
                hasDocument: Bool? = nil, modifiedAt: Date? = nil, appBundleID: String? = nil, windowTitle: String? = nil,
                sourcePath: String? = nil, duration: Double? = nil, hasAudio: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.captureKind = captureKind
        self.createdAt = createdAt
        self.mediaFileName = mediaFileName
        self.displayName = displayName
        self.savedPath = savedPath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.appName = appName
        self.isTransparent = isTransparent
        self.globalRect = globalRect
        self.savedFileDate = savedFileDate
        self.hasDocument = hasDocument
        self.modifiedAt = modifiedAt
        self.appBundleID = appBundleID
        self.windowTitle = windowTitle
        self.sourcePath = sourcePath
        self.duration = duration
        self.hasAudio = hasAudio
    }

    public var savedURL: URL? { savedPath.map { URL(filePath: $0) } }

    /// The file the item was imported from, or nil when none is recorded.
    public var sourceURL: URL? {
        guard let sourcePath, !sourcePath.isEmpty else { return nil }
        return URL(filePath: sourcePath)
    }

    /// Whether the working copy is still the one the item was created with. False for an item with no `modifiedAt`.
    public var isUnchangedSinceCreation: Bool { modifiedAt == createdAt }

    /// Whether the saved file, now last modified at `date`, is still the one ClearShot wrote, so ClearShot may rewrite
    /// it. An item with no recorded date (saved before dates were recorded) counts as unchanged.
    public func savedFileIsUnchanged(modifiedAt date: Date?) -> Bool {
        guard let savedFileDate else { return true }
        guard let date else { return false }
        return abs(date.timeIntervalSince(savedFileDate)) <= 0.01
    }
    public var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    public func folder(in root: URL) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public func mediaURL(in root: URL) -> URL {
        folder(in: root).appending(path: mediaFileName)
    }

    public func thumbnailURL(in root: URL) -> URL {
        folder(in: root).appending(path: Self.thumbnailFileName)
    }

    public func metadataURL(in root: URL) -> URL {
        folder(in: root).appending(path: Self.metadataFileName)
    }
}

public extension HistoryItem {
    /// A GIF's source video, kept beside it so Trim the GIF… can convert again. It starts with a dot, so it can't clash
    /// with the working copy's sanitized name.
    static let sourceVideoFileName = ".source.mp4"

    func sourceVideoURL(in root: URL) -> URL {
        folder(in: root).appending(path: Self.sourceVideoFileName)
    }

    /// Whether the Video Editor opens the item: a video, or a GIF whose source video is there (Trim the GIF… converts
    /// that again). A GIF opened from a file has none, and neither has a screenshot.
    func opensInVideoEditor(root: URL) -> Bool {
        switch kind {
        case .video: true
        case .gif: FileManager.default.fileExists(atPath: sourceVideoURL(in: root).path(percentEncoded: false))
        case .screenshot, .studioProject: false
        }
    }
}

public extension HistoryItem {
    /// What marks the item's files as a screenshot: a screenshot ClearShot captured has its kind and rect; an opened or
    /// pasted image, a video and a GIF have none, so their files carry no screen-capture attributes. The rule lives
    /// here because CSCapture, where the tag is, can't see `HistoryOrigin`.
    var screenCaptureTag: ScreenCaptureTag? {
        guard origin == .capture, kind == .screenshot else { return nil }
        return ScreenCaptureTag(kind: captureKind, globalRect: globalRect)
    }
}
