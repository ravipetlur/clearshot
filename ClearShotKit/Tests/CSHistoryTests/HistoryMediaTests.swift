import CoreGraphics
import CSCapture
import CSCore
import Foundation
import Testing
@testable import CSHistory

/// Videos and GIFs in history: items written from a file rather than an image.
@MainActor
final class HistoryMediaTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "history-media-\(UUID().uuidString)",
                                                                directoryHint: .isDirectory)
    /// Stands in for the Recordings folder a recording is finished in.
    let recordings = FileManager.default.temporaryDirectory.appending(path: "recordings-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
    let now = Date(timeIntervalSinceReferenceDate: 812_000_000)

    init() throws {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: recordings)
    }

    func details(kind: MediaKind = .video, name: String = "ClearShot 2026-10-05 at 10.00.00") -> HistoryWriter.Details {
        HistoryWriter.Details(kind: kind, origin: .capture, captureKind: .selection, displayName: name, savedURL: nil,
                              scale: 1, appName: "Safari", isTransparent: false,
                              globalRect: CGRect(x: 0, y: 0, width: 1280, height: 720), createdAt: now)
    }

    /// A file in the Recordings folder with some bytes of its own.
    func file(_ name: String, bytes: String = UUID().uuidString) throws -> URL {
        let url = recordings.appending(path: name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func createVideo(_ source: URL, transfer: HistoryWriter.MediaTransfer = .move, kind: MediaKind = .video,
                     sourceVideo: URL? = nil, id: UUID = UUID()) throws -> HistoryItem {
        try HistoryWriter.createMedia(source, transfer: transfer, pixelWidth: 1280, pixelHeight: 720, duration: 12.5,
                                      hasAudio: true, thumbnail: image(width: 1280, height: 720),
                                      details: details(kind: kind), sourceVideo: sourceVideo, id: id, root: root)
    }

    @Test func anOldMetaJSONDecodesWithoutDurationOrAudio() throws {
        let screenshot = try HistoryWriter.create(image(width: 40, height: 20), details: details(kind: .screenshot), root: root)
        #expect(screenshot.duration == nil)
        #expect(screenshot.hasAudio == nil)
        // A screenshot's meta.json doesn't name them, so older builds read it as before.
        let json = String(decoding: try Data(contentsOf: screenshot.metadataURL(in: root)), as: UTF8.self)
        #expect(!json.contains("duration"))
        #expect(!json.contains("hasAudio"))
        let loaded = try #require(HistoryStore(root: root).item(id: screenshot.id))
        #expect(loaded.duration == nil)
        #expect(loaded.hasAudio == nil)
    }

    @Test func aVideoItemRoundTrips() throws {
        let item = try createVideo(file("recording.mp4"))
        #expect(item.kind == .video)
        #expect(item.duration == 12.5)
        #expect(item.hasAudio == true)
        #expect(item.pixelWidth == 1280)
        #expect(item.pixelHeight == 720)
        #expect(item.modifiedAt == item.createdAt)
        #expect(item.appName == "Safari")
        #expect(HistoryStore(root: root).item(id: item.id) == item)
    }

    @Test func createMediaMovesTheFileAndKeepsItsExtension() throws {
        let source = try file("recording.mp4", bytes: "the video")
        let item = try createVideo(source)
        #expect(!exists(source))
        #expect(item.mediaFileName == "ClearShot 2026-10-05 at 10.00.00.mp4")
        let names = try FileManager.default.contentsOfDirectory(atPath: item.folder(in: root).path(percentEncoded: false))
        #expect(Set(names) == ["ClearShot 2026-10-05 at 10.00.00.mp4", HistoryItem.thumbnailFileName,
                               HistoryItem.metadataFileName])
        #expect(try Data(contentsOf: item.mediaURL(in: root)) == Data("the video".utf8))
        let thumbnail = try #require(ImageOps.load(item.thumbnailURL(in: root)))
        #expect(thumbnail.width == 640)
        #expect(thumbnail.height == 360)
    }

    /// A GIF keeps the video it was made from, for Trim the GIF…
    @Test func aGIFKeepsItsSourceVideo() throws {
        let gif = try file("recording.gif", bytes: "GIF89a")
        let intermediate = try file("intermediate.mp4", bytes: "the intermediate")
        let item = try createVideo(gif, kind: .gif, sourceVideo: intermediate)
        #expect(item.kind == .gif)
        #expect(item.mediaFileName.hasSuffix(".gif"))
        #expect(!exists(gif))
        #expect(!exists(intermediate))
        #expect(HistoryItem.sourceVideoFileName == ".source.mp4")
        #expect(item.sourceVideoURL(in: root) == item.folder(in: root).appending(path: ".source.mp4"))
        #expect(try Data(contentsOf: item.sourceVideoURL(in: root)) == Data("the intermediate".utf8))
        // A video has none.
        let video = try createVideo(file("recording.mp4"))
        #expect(!exists(video.sourceVideoURL(in: root)))
    }

    /// The Video Editor trims a GIF's source video, so a GIF opened from a file (no `.source.mp4`) doesn't open there.
    @Test func aGIFWithoutItsSourceVideoDoesntOpenInTheEditor() throws {
        #expect(try createVideo(file("recording.mp4")).opensInVideoEditor(root: root))
        let recorded = try createVideo(file("recording.gif", bytes: "GIF89a"), kind: .gif,
                                       sourceVideo: file("intermediate.mp4"))
        #expect(recorded.opensInVideoEditor(root: root))
        let opened = try createVideo(file("Opened.gif", bytes: "GIF89a"), transfer: .copy, kind: .gif)
        #expect(!opened.opensInVideoEditor(root: root))
        let screenshot = try HistoryWriter.create(image(width: 40, height: 20), details: details(kind: .screenshot), root: root)
        #expect(!screenshot.opensInVideoEditor(root: root))
    }

    /// An opened video file is copied in and stays where it was.
    @Test func copyTransferLeavesTheOriginal() throws {
        let source = try file("Opened.mov", bytes: "a movie")
        let item = try createVideo(source, transfer: .copy)
        #expect(exists(source))
        #expect(item.mediaFileName.hasSuffix(".mov"))
        #expect(try Data(contentsOf: item.mediaURL(in: root)) == Data("a movie".utf8))
    }

    /// The source is removed only once the item is complete; until then a failure leaves it for recovery.
    @Test func aFailedMetadataWriteLeavesTheSourceAndNoFolder() throws {
        let gif = try file("recording.gif", bytes: "GIF89a")
        let intermediate = try file("intermediate.mp4")
        let id = UUID()
        // A folder where meta.json goes makes its write fail after the file, the source video and the thumbnail.
        let folder = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: HistoryItem.metadataFileName),
                                                withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try self.createVideo(gif, kind: .gif, sourceVideo: intermediate, id: id)
        }
        #expect(exists(gif))
        #expect(exists(intermediate))
        #expect(!exists(folder))
    }

    @Test func replaceMediaUpdatesSizeDurationAndModifiedAt() throws {
        let item = try createVideo(file("recording.mp4", bytes: "before"))
        let trimmed = try file("trimmed.mp4", bytes: "after")
        let later = now.addingTimeInterval(60)
        let updated = try HistoryWriter.replaceMedia(of: item, movingFile: trimmed, pixelWidth: 854, pixelHeight: 480,
                                                     duration: 4, hasAudio: false, thumbnail: image(width: 854, height: 480),
                                                     root: root, now: later)
        #expect(!exists(trimmed))
        #expect(try Data(contentsOf: updated.mediaURL(in: root)) == Data("after".utf8))
        #expect(updated.mediaFileName == item.mediaFileName)
        #expect(updated.pixelWidth == 854)
        #expect(updated.pixelHeight == 480)
        #expect(updated.duration == 4)
        #expect(updated.hasAudio == false)
        #expect(updated.modifiedAt == later)
        #expect(updated.createdAt == item.createdAt)
        let thumbnail = try #require(ImageOps.load(updated.thumbnailURL(in: root)))
        #expect(thumbnail.width == 640)
        #expect(thumbnail.height == 360)
        #expect(HistoryStore(root: root).item(id: item.id) == updated)
    }

    /// An edit is always written as MP4, so an opened `.mov` becomes `.mp4`: the working copy takes the new file's
    /// extension and the old file goes.
    @Test func replaceMediaTakesTheNewFilesExtension() throws {
        let item = try createVideo(file("Opened.mov", bytes: "a movie"), transfer: .copy)
        #expect(item.mediaFileName == "ClearShot 2026-10-05 at 10.00.00.mov")
        let edited = try file("edited.mp4", bytes: "an mp4")
        let updated = try HistoryWriter.replaceMedia(of: item, movingFile: edited, pixelWidth: 1280, pixelHeight: 720,
                                                     duration: 3, hasAudio: true, thumbnail: image(width: 1280, height: 720),
                                                     root: root, now: now.addingTimeInterval(5))
        #expect(updated.mediaFileName == "ClearShot 2026-10-05 at 10.00.00.mp4")
        #expect(try Data(contentsOf: updated.mediaURL(in: root)) == Data("an mp4".utf8))
        #expect(!exists(item.mediaURL(in: root)))
        #expect(!exists(edited))
        let names = try FileManager.default.contentsOfDirectory(atPath: item.folder(in: root).path(percentEncoded: false))
        #expect(Set(names) == ["ClearShot 2026-10-05 at 10.00.00.mp4", HistoryItem.thumbnailFileName,
                               HistoryItem.metadataFileName])
        #expect(HistoryStore(root: root).item(id: item.id) == updated)
    }

    // MARK: The saved file after an edit

    /// Stands in for the export folder.
    var exports: URL { recordings.appending(path: "exports", directoryHint: .isDirectory) }

    /// A video item made from `name` in Recordings, saved into `exports` as `savedName` the way a save records it
    /// (`savedPath`, `savedFileDate`), then replaced by an MP4 edit. Returns the item before and after the replace.
    func savedThenEdited(_ name: String, savedName: String) throws -> (before: HistoryItem, after: HistoryItem) {
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let saved = exports.appending(path: savedName)
        try Data("the saved original".utf8).write(to: saved)
        var item = try createVideo(file(name, bytes: "the original"), transfer: .copy)
        item.savedPath = saved.path(percentEncoded: false)
        item.savedFileDate = HistoryWriter.modificationDate(of: saved)
        let edited = try file("edited.mp4", bytes: "the edit")
        let after = try HistoryWriter.replaceMedia(of: item, movingFile: edited, pixelWidth: 1280, pixelHeight: 720,
                                                   duration: 3, hasAudio: false, thumbnail: image(width: 1280, height: 720),
                                                   root: root)
        return (item, after)
    }

    @Test func aSavedFileInTheSameFormatTakesTheEdit() throws {
        var (before, after) = try savedThenEdited("recording.mp4", savedName: "Clip.mp4")
        #expect(try HistoryWriter.rewriteSavedMedia(of: before, updating: &after, root: root) == .replaced)
        let saved = try #require(after.savedURL)
        #expect(saved == before.savedURL)
        #expect(try Data(contentsOf: saved) == Data("the edit".utf8))
        #expect(after.savedFileDate == HistoryWriter.modificationDate(of: saved))
        #expect(after.displayName == before.displayName)
    }

    /// A `.mov` saved before an edit wrote MP4: it stays as it was, and the edit is saved beside it under the same name,
    /// made unique, which the item then names as its saved file (so copies and Open With hand out the edit).
    @Test func aSavedFileInAnotherFormatGetsTheEditBesideIt() throws {
        var (before, after) = try savedThenEdited("Opened.mov", savedName: "Clip.mov")
        // A file of the person's own already has the name.
        try Data("someone else's".utf8).write(to: exports.appending(path: "Clip.mp4"))
        let outcome = try HistoryWriter.rewriteSavedMedia(of: before, updating: &after, root: root)
        let beside = exports.appending(path: "Clip (2).mp4")
        guard case .savedBeside(let written) = outcome else {
            Issue.record("Expected the edit saved beside, got \(outcome)")
            return
        }
        #expect(written.path(percentEncoded: false) == beside.path(percentEncoded: false))
        #expect(after.savedPath == beside.path(percentEncoded: false))
        #expect(try Data(contentsOf: beside) == Data("the edit".utf8))
        #expect(after.savedFileDate == HistoryWriter.modificationDate(of: beside))
        #expect(after.displayName == "Clip (2)")
        #expect(try Data(contentsOf: exports.appending(path: "Clip.mov")) == Data("the saved original".utf8))
        #expect(try Data(contentsOf: exports.appending(path: "Clip.mp4")) == Data("someone else's".utf8))
    }

    @Test func aSavedFileEditedElsewhereOrGoneIsLeftAlone() throws {
        var (before, after) = try savedThenEdited("recording.mp4", savedName: "Clip.mp4")
        let saved = try #require(before.savedURL)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3_600)],
                                              ofItemAtPath: saved.path(percentEncoded: false))
        let unchanged = after
        #expect(try HistoryWriter.rewriteSavedMedia(of: before, updating: &after, root: root) == .editedElsewhere)
        #expect(after == unchanged)
        #expect(try Data(contentsOf: saved) == Data("the saved original".utf8))
        try FileManager.default.removeItem(at: saved)
        #expect(try HistoryWriter.rewriteSavedMedia(of: before, updating: &after, root: root) == .noSavedFile)
        #expect(after == unchanged)
    }

    /// An export a crash interrupted leaves its temporary file in the item's folder; the next launch sweeps those, and
    /// only those.
    @Test func leftoverEditFilesAreSwept() throws {
        let gif = try createVideo(file("recording.gif", bytes: "GIF89a"), kind: .gif, sourceVideo: try file("source.mp4"))
        let video = try createVideo(file("recording.mp4"))
        let edit = HistoryWriter.temporaryEditURL(for: video, pathExtension: "mp4", root: root)
        let mute = HistoryWriter.temporaryEditURL(for: video, prefix: ".mute-", pathExtension: "mp4", root: root)
        let gifEdit = HistoryWriter.temporaryEditURL(for: gif, pathExtension: "gif", root: root)
        #expect(edit.deletingLastPathComponent() == video.folder(in: root))
        #expect(edit.lastPathComponent.hasPrefix(".edit-"))
        #expect(edit.pathExtension == "mp4")
        #expect(edit != HistoryWriter.temporaryEditURL(for: video, pathExtension: "mp4", root: root))
        for url in [edit, mute, gifEdit] { try Data("partial".utf8).write(to: url) }
        // One an edit started after launch is writing: newer than the sweep's moment, so it stays.
        let running = HistoryWriter.temporaryEditURL(for: video, pathExtension: "mp4", root: root)
        try Data("being written".utf8).write(to: running)
        let launch = now.addingTimeInterval(3_600)
        for url in [edit, mute, gifEdit] {
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path(percentEncoded: false))
        }
        try FileManager.default.setAttributes([.modificationDate: launch.addingTimeInterval(1)],
                                              ofItemAtPath: running.path(percentEncoded: false))
        let kept = try [video, gif].map { item in
            Set(try FileManager.default.contentsOfDirectory(atPath: item.folder(in: root).path(percentEncoded: false)))
        }

        let removed = HistoryWriter.removeTemporaryEditFiles(in: root, before: launch)
        #expect(Set(removed.map(\.lastPathComponent)) == Set([edit, mute, gifEdit].map(\.lastPathComponent)))
        for (item, before) in zip([video, gif], kept) {
            let after = Set(try FileManager.default.contentsOfDirectory(atPath: item.folder(in: root).path(percentEncoded: false)))
            #expect(after == before.subtracting([edit, mute, gifEdit].map(\.lastPathComponent)))
        }
        #expect(exists(running))
        #expect(exists(gif.sourceVideoURL(in: root)))
        // A root that doesn't exist yet has nothing to sweep.
        #expect(HistoryWriter.removeTemporaryEditFiles(in: root.appending(path: "missing"), before: launch).isEmpty)
    }

    /// The same name in another case is the same file on APFS: replacing `.MP4` with `.mp4` keeps the new file.
    @Test func replaceMediaWithTheSameExtensionInAnotherCaseKeepsTheFile() throws {
        let item = try createVideo(file("Opened.MP4", bytes: "before"), transfer: .copy)
        let edited = try file("edited.mp4", bytes: "after")
        let updated = try HistoryWriter.replaceMedia(of: item, movingFile: edited, pixelWidth: 1280, pixelHeight: 720,
                                                     duration: 3, hasAudio: true, thumbnail: image(width: 1280, height: 720),
                                                     root: root)
        #expect(try Data(contentsOf: updated.mediaURL(in: root)) == Data("after".utf8))
        #expect(HistoryStore(root: root).item(id: item.id) == updated)
    }
}
