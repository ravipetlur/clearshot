import CoreGraphics
import CSCapture
import CSCore
import Foundation

/// Writes history items to disk. It holds no state, so it can run off the main actor.
public enum HistoryWriter {
    public static let thumbnailMaxPixel = 640

    /// Everything a new item needs besides its image or media file.
    public struct Details: Sendable {
        public var kind: MediaKind
        public var origin: HistoryOrigin
        public var captureKind: CaptureKind
        public var displayName: String
        public var savedURL: URL?
        public var scale: Double
        public var appName: String?
        public var isTransparent: Bool
        public var globalRect: CGRect
        public var createdAt: Date
        /// Whether the item starts out with an Annotate document (`HistoryItem.hasDocument`): a capture that got a
        /// background, written by `AnnotationStorage.createItem`. Nil for a plain capture.
        public var hasDocument: Bool?
        public var appBundleID: String?
        public var windowTitle: String?
        /// For an imported file: the file's path (`HistoryItem.sourcePath`).
        public var sourcePath: String?

        public init(kind: MediaKind = .screenshot, origin: HistoryOrigin, captureKind: CaptureKind, displayName: String,
                    savedURL: URL?, scale: Double, appName: String?, isTransparent: Bool, globalRect: CGRect, createdAt: Date,
                    hasDocument: Bool? = nil, appBundleID: String? = nil, windowTitle: String? = nil, sourcePath: String? = nil) {
            self.kind = kind
            self.origin = origin
            self.captureKind = captureKind
            self.displayName = displayName
            self.savedURL = savedURL
            self.scale = scale
            self.appName = appName
            self.isTransparent = isTransparent
            self.globalRect = globalRect
            self.createdAt = createdAt
            self.hasDocument = hasDocument
            self.appBundleID = appBundleID
            self.windowTitle = windowTitle
            self.sourcePath = sourcePath
        }

        /// A screenshot ClearShot just took.
        public init(capture: CaptureResult, displayName: String, savedURL: URL?) {
            self.init(origin: .capture, captureKind: capture.kind, displayName: displayName, savedURL: savedURL,
                      scale: Double(capture.scale), appName: capture.appName, isTransparent: capture.isTransparent,
                      globalRect: capture.globalRect, createdAt: capture.createdAt, appBundleID: capture.appBundleID,
                      windowTitle: capture.windowTitle)
        }
    }

    /// Writes a new item folder under `root`: the lossless working copy, the thumbnail, then `meta.json`. The item's
    /// `modifiedAt` is its `createdAt`, so it reads as unchanged since creation until its image is replaced. A folder
    /// without `meta.json` is an interrupted write; `HistoryStore.purge` removes it later. The folder may already exist,
    /// and what is in it stays: `AnnotationStorage.createItem` writes the item's document there first.
    public static func create(_ image: CGImage, details: Details, id: UUID = UUID(), root: URL) throws -> HistoryItem {
        let item = makeItem(details: details, id: id, mediaFileName: mediaFileName(for: details.displayName),
                            pixelWidth: image.width, pixelHeight: image.height, duration: nil, hasAudio: nil)
        try FileManager.default.createDirectory(at: item.folder(in: root), withIntermediateDirectories: true)
        try writeImages(image, for: item, root: root)
        try writeMetadata(item, root: root)
        return item
    }

    /// Replaces an item's image (Rotate, Flip, Resize, an annotate Done…) and returns the updated item, its
    /// `modifiedAt` set to `now` even when the size is unchanged, so whatever shows the image knows to redraw it.
    public static func replaceImage(of item: HistoryItem, with image: CGImage, scale: Double, root: URL,
                                    now: Date = Date()) throws -> HistoryItem {
        var updated = item
        updated.pixelWidth = image.width
        updated.pixelHeight = image.height
        updated.scale = scale
        updated.modifiedAt = now
        try writeImages(image, for: updated, root: root)
        try writeMetadata(updated, root: root)
        return updated
    }

    /// How a media file gets into its item folder: moved from a recording's folder, or copied from a file the person
    /// opened, which stays where it was.
    public enum MediaTransfer: Sendable {
        case move, copy
    }

    /// Writes a new item folder under `root` for a video or GIF file (`details.kind`): the file as the working copy,
    /// named `<sanitized display name>.<the file's extension>`; `sourceVideo` (a GIF's) as `.source.mp4`; the thumbnail
    /// from `thumbnail`; then `meta.json`.
    ///
    /// Nothing is moved until the item is complete: the file and `sourceVideo` are cloned in (a copy where the volume
    /// can't clone), and only after `meta.json` is written are they removed from where they were (`sourceVideo` always,
    /// the file with `.move`). On any failure the partial item folder is removed and the sources stay put, so a
    /// recording's folder still holds them for recovery. The item is new, so its folder is expected not to exist.
    public static func createMedia(_ file: URL, transfer: MediaTransfer, pixelWidth: Int, pixelHeight: Int,
                                   duration: Double, hasAudio: Bool, thumbnail: CGImage, details: Details,
                                   sourceVideo: URL? = nil, id: UUID = UUID(), root: URL) throws -> HistoryItem {
        let item = makeItem(details: details, id: id,
                            mediaFileName: mediaFileName(for: details.displayName, pathExtension: file.pathExtension),
                            pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration, hasAudio: hasAudio)
        let folder = item.folder(in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            // On APFS a copy is a clone: instant, and it takes no space.
            try FileManager.default.copyItem(at: file, to: item.mediaURL(in: root))
            if let sourceVideo { try FileManager.default.copyItem(at: sourceVideo, to: item.sourceVideoURL(in: root)) }
            try writeThumbnail(thumbnail, for: item, root: root)
            try writeMetadata(item, root: root)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        // The item is complete; a source that can't be removed is only a leftover.
        if transfer == .move { try? FileManager.default.removeItem(at: file) }
        if let sourceVideo { try? FileManager.default.removeItem(at: sourceVideo) }
        return item
    }

    /// Replaces a video's or GIF's working copy with `file` and its thumbnail (a trim, Mute Audio…, an editor save),
    /// then returns the updated item: its size, duration and audio, and `modifiedAt` set to `now`. The file is moved in
    /// under the item's name with its own extension (an edit is written as MP4, so an opened `.mov` becomes `.mp4`, and
    /// `mediaFileName` follows); a working copy under the old extension is removed once `meta.json` names the new one.
    /// The file takes the place of the old one in a single step, so a player reading the old file keeps reading it.
    public static func replaceMedia(of item: HistoryItem, movingFile file: URL, pixelWidth: Int, pixelHeight: Int,
                                    duration: Double, hasAudio: Bool, thumbnail: CGImage, root: URL,
                                    now: Date = Date()) throws -> HistoryItem {
        var updated = item
        let stem = (item.mediaFileName as NSString).deletingPathExtension
        updated.mediaFileName = file.pathExtension.isEmpty ? stem : stem + "." + file.pathExtension
        updated.pixelWidth = pixelWidth
        updated.pixelHeight = pixelHeight
        updated.duration = duration
        updated.hasAudio = hasAudio
        updated.modifiedAt = now
        let media = updated.mediaURL(in: root)
        if FileManager.default.fileExists(atPath: media.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(media, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: media)
        }
        try writeThumbnail(thumbnail, for: updated, root: root)
        try writeMetadata(updated, root: root)
        // Only a name that differs in more than case is another file: on APFS `.MP4` and `.mp4` are the same one.
        if updated.mediaFileName.lowercased() != item.mediaFileName.lowercased() {
            try? FileManager.default.removeItem(at: item.mediaURL(in: root))
        }
        return updated
    }

    /// What `rewriteSavedMedia` did with an item's saved file.
    public enum SavedMediaRewrite: Equatable, Sendable {
        /// The item has no saved file, or it is gone: nothing to do.
        case noSavedFile
        /// It changed after ClearShot wrote it, so it was left alone.
        case editedElsewhere
        /// It now holds the edit.
        case replaced
        /// It is in another format than the edit (a `.mov` saved before an edit wrote MP4): it stays as it was, and the
        /// edit is saved beside it as this file, which the item now names as its saved file.
        case savedBeside(URL)
    }

    /// Brings the saved file of a video or GIF up to date after `replaceMedia` (an editor save, Mute Audio…): `item` is
    /// the item before the replace, whose `savedFileDate` is when ClearShot last wrote the saved file, and `updated`
    /// the item after it, whose working copy is the edit. The saved file becomes a clone of the edit unless it changed
    /// since ClearShot wrote it. One in another format (a `.mov` saved before an edit wrote MP4) is never written over:
    /// the edit is saved beside it under its name, made unique, and `updated` names that file as its saved file (its
    /// path, date and, as a save does, its name), so copies, drags and Open With hand out the edit. Throws when the
    /// copy can't be written; `updated` is then as it was.
    public static func rewriteSavedMedia(of item: HistoryItem, updating updated: inout HistoryItem,
                                         root: URL) throws -> SavedMediaRewrite {
        guard let saved = item.savedURL, FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)) else {
            return .noSavedFile
        }
        guard item.savedFileIsUnchanged(modifiedAt: modificationDate(of: saved)) else { return .editedElsewhere }
        let media = updated.mediaURL(in: root)
        guard saved.pathExtension.lowercased() != media.pathExtension.lowercased() else {
            try Exporter.writeCopy(of: media, to: saved)
            updated.savedFileDate = modificationDate(of: saved)
            return .replaced
        }
        let beside = FileNamer.uniqueURL(in: saved.deletingLastPathComponent(),
                                         baseName: saved.deletingPathExtension().lastPathComponent,
                                         pathExtension: media.pathExtension)
        try Exporter.writeCopy(of: media, to: beside)
        updated.savedPath = beside.path(percentEncoded: false)
        updated.savedFileDate = modificationDate(of: beside)
        updated.displayName = beside.deletingPathExtension().lastPathComponent
        return .savedBeside(beside)
    }

    /// The names an edit's temporary files start with: the Video Editor's Save writes `.edit-…`, Mute Audio… `.mute-…`.
    /// They start with a dot, so they can't be the working copy's sanitized name.
    public static let temporaryEditPrefixes = [".edit-", ".mute-"]

    /// A fresh file in the item's folder for an edit to export into before it replaces the working copy (so the file a
    /// player reads is never written over): `<prefix><UUID>.<pathExtension>`.
    public static func temporaryEditURL(for item: HistoryItem, prefix: String = ".edit-", pathExtension: String,
                                        root: URL) -> URL {
        item.folder(in: root).appending(path: "\(prefix)\(UUID().uuidString).\(pathExtension)")
    }

    /// Removes the temporary files that edits a crash or a quit interrupted left in the item folders under `root`
    /// (`temporaryEditPrefixes`), and returns them. A re-encode's can be gigabytes, and nothing else ever removes them
    /// while the item lives. Only files last written before `date` go: at launch, the launch's moment, so an edit started
    /// since keeps its file.
    @discardableResult
    public static func removeTemporaryEditFiles(in root: URL, before date: Date) -> [URL] {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var removed: [URL] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in files where temporaryEditPrefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }) {
                guard let written = modificationDate(of: file), written < date else { continue }
                if (try? fileManager.removeItem(at: file)) != nil { removed.append(file) }
            }
        }
        return removed
    }

    /// A copy of the item's working copy at `directory/<id>/<media file name>`, for the clipboard and drags: it
    /// outlives the history folder (retention "Never" removes that when the thumbnail closes) until the temporary
    /// folder is cleared at the next launch. Replaced on every call, so it always matches the current image (after
    /// Rotate, Resize…). On APFS the copy is a clone, so it is instant and takes no space. A captured screenshot's copy
    /// is marked as a screenshot, as its saved file would be, so a drag or copy of an unsaved capture carries the tag
    /// too; the working copy itself stays unmarked.
    public static func temporaryCopy(of item: HistoryItem, root: URL, in directory: URL) throws -> URL {
        let folder = directory.appending(path: item.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: item.mediaFileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: item.mediaURL(in: root), to: destination)
        if let tag = item.screenCaptureTag { ScreenCaptureMetadata.apply(tag, to: destination) }
        return destination
    }

    /// The file's modification date, read afresh, or nil if it can't be read.
    public static func modificationDate(of url: URL) -> Date? {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    public static func writeMetadata(_ item: HistoryItem, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(item).write(to: item.metadataURL(in: root), options: .atomic)
    }

    /// "<sanitized display name>.<extension>", ".png" for a screenshot. `FileNamer.sanitize` replaces slashes, strips a
    /// leading dot (so the name can't be `HistoryItem.thumbnailFileName` or `.sourceVideoFileName`), falls back to
    /// "Screenshot" for an empty name and keeps the name within APFS's 255-byte limit.
    static func mediaFileName(for displayName: String, pathExtension: String = "png") -> String {
        let name = FileNamer.sanitize(displayName, removeIllegalCharacters: false)
        return pathExtension.isEmpty ? name : name + "." + pathExtension
    }

    /// A new item from `details`: the one mapping `create` and `createMedia` share, so a field added to `Details` reaches
    /// both. `modifiedAt` is `createdAt`, and the saved file's date is read now.
    private static func makeItem(details: Details, id: UUID, mediaFileName: String, pixelWidth: Int, pixelHeight: Int,
                                 duration: Double?, hasAudio: Bool?) -> HistoryItem {
        HistoryItem(id: id, kind: details.kind, origin: details.origin, captureKind: details.captureKind,
                    createdAt: details.createdAt, mediaFileName: mediaFileName, displayName: details.displayName,
                    savedPath: details.savedURL?.path(percentEncoded: false), pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight, scale: details.scale, appName: details.appName,
                    isTransparent: details.isTransparent, globalRect: details.globalRect,
                    savedFileDate: details.savedURL.flatMap(modificationDate(of:)), hasDocument: details.hasDocument,
                    modifiedAt: details.createdAt, appBundleID: details.appBundleID, windowTitle: details.windowTitle,
                    sourcePath: details.sourcePath, duration: duration, hasAudio: hasAudio)
    }

    /// The working copy records the item's scale as its density, so its copies and drags (a temporary copy is a clone
    /// of it) keep their size when they are put into an editor. The thumbnail is only ever shown, and records none.
    private static func writeImages(_ image: CGImage, for item: HistoryItem, root: URL) throws {
        try ImageEncoder.encode(image, as: .png, quality: 1, pixelsPerPoint: item.scale).write(to: item.mediaURL(in: root), options: .atomic)
        try writeThumbnail(image, for: item, root: root)
    }

    private static func writeThumbnail(_ image: CGImage, for item: HistoryItem, root: URL) throws {
        let thumbnail = ImageOps.thumbnail(image, maxPixel: thumbnailMaxPixel)
        try ImageEncoder.encode(thumbnail, as: .png, quality: 1).write(to: item.thumbnailURL(in: root), options: .atomic)
    }
}
