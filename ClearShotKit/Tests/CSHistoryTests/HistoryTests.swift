import CoreGraphics
import CSCapture
import CSCore
import Foundation
import ImageIO
import Testing
@testable import CSHistory

/// A solid image, for the items the history tests write.
func image(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@MainActor
final class HistoryTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString)", directoryHint: .isDirectory)
    let temporary = FileManager.default.temporaryDirectory.appending(path: "history-tmp-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    deinit {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: temporary)
    }

    func details(name: String = "Screenshot 2026-10-03 at 10.00.00", kind: MediaKind = .screenshot, createdAt: Date? = nil,
                 savedURL: URL? = nil) -> HistoryWriter.Details {
        HistoryWriter.Details(kind: kind, origin: .capture, captureKind: .selection, displayName: name, savedURL: savedURL,
                              scale: 2, appName: "Safari", isTransparent: false,
                              globalRect: CGRect(x: 10, y: 20, width: 500, height: 250), createdAt: createdAt ?? now)
    }

    /// Writes an item `age` seconds older than `now`, and adds it to `store` if given.
    @discardableResult
    func create(_ store: HistoryStore? = nil, name: String = "Shot", kind: MediaKind = .screenshot, age: TimeInterval = 0,
                width: Int = 40, height: Int = 20) throws -> HistoryItem {
        let item = try HistoryWriter.create(image(width: width, height: height),
                                            details: details(name: name, kind: kind, createdAt: now.addingTimeInterval(-age)),
                                            root: root)
        store?.add(item)
        return item
    }

    /// The changes a store reported, in order.
    @MainActor final class ChangeLog {
        var changes: [HistoryChange] = []
    }

    /// Starts recording what `store` reports.
    func record(_ store: HistoryStore) -> ChangeLog {
        let log = ChangeLog()
        store.observe { log.changes.append($0) }
        return log
    }

    /// The top-level keys of the item's `meta.json`.
    func metadataKeys(of item: HistoryItem) throws -> Set<String> {
        let data = try Data(contentsOf: item.metadataURL(in: root))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func createWritesTheWorkingCopyThumbnailAndMetadata() throws {
        let item = try HistoryWriter.create(image(width: 1000, height: 500), details: details(), root: root)
        #expect(item.mediaFileName == "Screenshot 2026-10-03 at 10.00.00.png")
        let media = try #require(ImageOps.load(item.mediaURL(in: root)))
        #expect(media.width == 1000)
        #expect(media.height == 500)
        let thumbnail = try #require(ImageOps.load(item.thumbnailURL(in: root)))
        #expect(thumbnail.width == 640)
        #expect(thumbnail.height == 320)
        #expect(exists(item.metadataURL(in: root)))
        #expect(item.pixelSize == CGSize(width: 1000, height: 500))
        #expect(item.scale == 2)
        #expect(item.appName == "Safari")
        #expect(item.savedPath == nil)
    }

    @Test func aDisplayNameCalledThumbCantClashWithTheThumbnail() throws {
        let item = try create(name: "thumb")
        #expect(item.mediaURL(in: root) != item.thumbnailURL(in: root))
        #expect(ImageOps.load(item.mediaURL(in: root))?.width == 40)
    }

    @Test func theWorkingCopyNameIsSanitizedSoItCantBeTheThumbnail() {
        #expect(HistoryWriter.mediaFileName(for: ".thumb") != HistoryItem.thumbnailFileName)
        #expect(HistoryWriter.mediaFileName(for: ".thumb.png") != HistoryItem.thumbnailFileName)
        #expect(HistoryWriter.mediaFileName(for: "") == "Screenshot.png")
        #expect(HistoryWriter.mediaFileName(for: "a/b") == "a-b.png")
    }

    @Test func detailsFromACaptureCarryItsFacts() throws {
        let capture = CaptureResult(kind: .window, image: image(width: 4, height: 4), scale: 2, displayID: 1,
                                    globalRect: CGRect(x: 1, y: 2, width: 3, height: 4), appName: "Xcode", windowTitle: "Main",
                                    createdAt: now, isTransparent: true, appBundleID: "com.apple.dt.Xcode")
        let details = HistoryWriter.Details(capture: capture, displayName: "Name", savedURL: nil)
        #expect(details.origin == .capture)
        #expect(details.captureKind == .window)
        #expect(details.isTransparent)
        #expect(details.scale == 2)
        #expect(details.appName == "Xcode")
        #expect(details.appBundleID == "com.apple.dt.Xcode")
        #expect(details.windowTitle == "Main")
        #expect(details.sourcePath == nil)
        #expect(details.createdAt == now)
        #expect(details.globalRect == CGRect(x: 1, y: 2, width: 3, height: 4))
        let item = try HistoryWriter.create(capture.image, details: details, root: root)
        #expect(item.appBundleID == "com.apple.dt.Xcode")
        #expect(item.windowTitle == "Main")
    }

    @Test func detailsCarryTheSourcePath() throws {
        var imported = details(name: "a")
        imported.origin = .file
        #expect(imported.sourcePath == nil)
        imported.sourcePath = "/Volumes/Data/Pictures/a.png"
        let item = try HistoryWriter.create(image(width: 4, height: 4), details: imported, root: root)
        #expect(item.sourcePath == "/Volumes/Data/Pictures/a.png")
        #expect(item.sourceURL == URL(filePath: "/Volumes/Data/Pictures/a.png"))
        let initialized = HistoryWriter.Details(origin: .file, captureKind: .selection, displayName: "a", savedURL: nil, scale: 1,
                                                appName: nil, isTransparent: false, globalRect: .zero, createdAt: now,
                                                sourcePath: "/Volumes/Data/Pictures/a.png")
        #expect(initialized.sourcePath == "/Volumes/Data/Pictures/a.png")
        // No path, or an empty one, is no URL.
        var other = item
        other.sourcePath = nil
        #expect(other.sourceURL == nil)
        other.sourcePath = ""
        #expect(other.sourceURL == nil)
    }

    @Test func aNewStoreLoadsItemsNewestFirst() throws {
        let old = try create(name: "Old", age: 3_600)
        let newest = try create(name: "New", age: 0)
        let middle = try create(name: "Middle", age: 60)
        let store = HistoryStore(root: root)
        #expect(store.items.map(\.id) == [newest.id, middle.id, old.id])
        #expect(store.items.first == newest)
    }

    @Test func addKeepsNewestFirstOrder() throws {
        let store = HistoryStore(root: root)
        let older = try create(store, name: "Older", age: 100)
        let newer = try create(store, name: "Newer", age: 0)
        let between = try create(store, name: "Between", age: 50)
        #expect(store.items.map(\.id) == [newer.id, between.id, older.id])
    }

    @Test func updatePersistsTheSavedPath() throws {
        let store = HistoryStore(root: root)
        var item = try create(store)
        item.savedPath = "/Volumes/Data/Downloads/screenshot/Shot.jpg"
        try store.update(item)
        #expect(HistoryStore(root: root).item(id: item.id)?.savedPath == "/Volumes/Data/Downloads/screenshot/Shot.jpg")
        // A metadata change isn't a change to the image.
        #expect(store.item(id: item.id)?.modifiedAt == item.createdAt)
        #expect(store.items.count == 1)
        #expect(store.item(id: item.id)?.savedURL?.lastPathComponent == "Shot.jpg")
    }

    @Test func removeLeavesTheSavedFileAlone() throws {
        let saved = root.deletingLastPathComponent().appending(path: "saved-\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: saved)
        defer { try? FileManager.default.removeItem(at: saved) }
        let store = HistoryStore(root: root)
        let item = try HistoryWriter.create(image(width: 4, height: 4), details: details(savedURL: saved), root: root)
        store.add(item)
        store.remove(item.id)
        #expect(store.items.isEmpty)
        #expect(!exists(item.folder(in: root)))
        #expect(exists(saved))
    }

    @Test func purgeRemovesExpiredItemsAndKeepsRecentOnes() throws {
        let store = HistoryStore(root: root)
        let expired = try create(store, name: "Expired", age: 2 * 86_400)
        let recent = try create(store, name: "Recent", age: 3_600)
        #expect(store.purge(retention: .oneDay, now: now) == 1)
        #expect(store.items.map(\.id) == [recent.id])
        #expect(!exists(expired.folder(in: root)))
    }

    @Test func purgeKeepsHeldItems() throws {
        let store = HistoryStore(root: root)
        let held = try create(store, name: "Held", age: 40 * 86_400)
        let closed = try create(store, name: "Closed", age: 40 * 86_400)
        store.holds.hold(held.id)
        #expect(store.purge(retention: .oneMonth, now: now) == 1)
        #expect(store.items.map(\.id) == [held.id])
        #expect(exists(held.folder(in: root)))
        #expect(!exists(closed.folder(in: root)))
    }

    @Test func neverRetentionRemovesEverythingNotHeld() throws {
        let store = HistoryStore(root: root)
        let held = try create(store, name: "Held", age: 1)
        try create(store, name: "Closed", age: 1)
        store.holds.hold(held.id)
        store.purge(retention: .never, now: now)
        #expect(store.items.map(\.id) == [held.id])
    }

    @Test func anOldFolderWithoutMetadataIsPurged() throws {
        let orphan = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3_600)],
                                              ofItemAtPath: orphan.path(percentEncoded: false))
        let store = HistoryStore(root: root)
        #expect(store.items.isEmpty)
        store.purge(retention: .oneMonth)
        #expect(!exists(orphan))
    }

    @Test func anOldFolderWithACorruptMetadataFileIsKept() throws {
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appending(path: HistoryItem.metadataFileName))
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3_600)],
                                              ofItemAtPath: folder.path(percentEncoded: false))
        let store = HistoryStore(root: root)
        #expect(store.items.isEmpty)
        store.purge(retention: .never)
        #expect(exists(folder))
    }

    @Test func aLoadedItemInALowercaseFolderIsntPurgedAsAnOrphan() throws {
        let item = try create()
        let lowercased = root.appending(path: item.id.uuidString.lowercased(), directoryHint: .isDirectory)
        if lowercased.lastPathComponent != item.folder(in: root).lastPathComponent {
            try FileManager.default.moveItem(at: item.folder(in: root), to: lowercased)
        }
        // Old relative to the purge's `now`, so only the ID comparison keeps it.
        try FileManager.default.setAttributes([.creationDate: item.createdAt.addingTimeInterval(-3_600)],
                                              ofItemAtPath: lowercased.path(percentEncoded: false))
        let store = HistoryStore(root: root)
        #expect(store.items.map(\.id) == [item.id])
        store.purge(retention: .oneMonth, now: item.createdAt)
        #expect(store.items.map(\.id) == [item.id])
        #expect(exists(lowercased))
    }

    @Test func aFreshFolderWithoutMetadataSurvivesPurge() throws {
        let inProgress = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inProgress, withIntermediateDirectories: true)
        HistoryStore(root: root).purge(retention: .never)
        #expect(exists(inProgress))
    }

    @Test func foldersThatArentItemsAreLeftAlone() throws {
        let other = root.appending(path: "Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3_600)],
                                              ofItemAtPath: other.path(percentEncoded: false))
        HistoryStore(root: root).purge(retention: .never)
        #expect(exists(other))
    }

    @Test func clearKeepsHeldItems() throws {
        let store = HistoryStore(root: root)
        let held = try create(store, name: "Held")
        try create(store, name: "Gone")
        store.holds.hold(held.id)
        store.clear()
        #expect(store.items.map(\.id) == [held.id])
        #expect(HistoryStore(root: root).items.map(\.id) == [held.id])
    }

    @Test func replaceImageUpdatesTheSizeScaleAndFiles() throws {
        let item = try create(width: 1000, height: 500)
        let original = try #require(ImageOps.load(item.mediaURL(in: root)))
        let rotated = try #require(ImageOps.rotatedLeft(original))
        let updated = try HistoryWriter.replaceImage(of: item, with: rotated, scale: 1, root: root)
        #expect(updated.pixelSize == CGSize(width: 500, height: 1000))
        #expect(updated.scale == 1)
        #expect(ImageOps.load(updated.mediaURL(in: root))?.height == 1000)
        #expect(ImageOps.load(updated.thumbnailURL(in: root))?.height == 640)
        #expect(HistoryStore(root: root).item(id: item.id)?.pixelWidth == 500)
    }

    /// The density ImageIO reads from the file at `url`.
    private func dpi(of url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
    }

    @Test func theWorkingCopyRecordsTheItemsScaleAsItsDensity() throws {
        let item = try create() // 2×
        #expect(dpi(of: item.mediaURL(in: root)) == 144)
        // Its drags and copies carry it too.
        #expect(dpi(of: try HistoryWriter.temporaryCopy(of: item, root: root, in: temporary)) == 144)
        let halved = try HistoryWriter.replaceImage(of: item, with: image(width: 20, height: 10), scale: 1, root: root)
        #expect(dpi(of: halved.mediaURL(in: root)) == 72)
    }

    @Test func temporaryCopyHasTheWorkingCopysNameAndBytes() throws {
        let item = try create(name: "Shot")
        let copy = try HistoryWriter.temporaryCopy(of: item, root: root, in: temporary)
        #expect(copy.lastPathComponent == item.mediaFileName)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: item.mediaURL(in: root)))
    }

    @Test func temporaryCopySurvivesRemovingTheItem() throws {
        let store = HistoryStore(root: root)
        let item = try create(store)
        let copy = try HistoryWriter.temporaryCopy(of: item, root: root, in: temporary)
        store.remove(item.id)
        #expect(!exists(item.mediaURL(in: root)))
        #expect(exists(copy))
    }

    @Test func temporaryCopyFollowsAReplacedImage() throws {
        let item = try create(width: 40, height: 20)
        let first = try HistoryWriter.temporaryCopy(of: item, root: root, in: temporary)
        #expect(ImageOps.load(first)?.width == 40)
        let updated = try HistoryWriter.replaceImage(of: item, with: image(width: 80, height: 30), scale: 2, root: root)
        let second = try HistoryWriter.temporaryCopy(of: updated, root: root, in: temporary)
        #expect(second == first)
        #expect(ImageOps.load(second)?.width == 80)
    }

    /// A file standing in for a saved screenshot, last modified at `modified`.
    func savedFile(modified: Date) throws -> URL {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let url = temporary.appending(path: "Saved-\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    @Test func aWrittenFileHasItsModificationDate() throws {
        let url = try savedFile(modified: now)
        let first = try #require(HistoryWriter.modificationDate(of: url))
        #expect(abs(first.timeIntervalSince(now)) < 0.01)
        // Read afresh each time, so a change made in another app shows.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)],
                                              ofItemAtPath: url.path(percentEncoded: false))
        let second = try #require(HistoryWriter.modificationDate(of: url))
        #expect(abs(second.timeIntervalSince(now.addingTimeInterval(60))) < 0.01)
        #expect(HistoryWriter.modificationDate(of: temporary.appending(path: "missing-\(UUID().uuidString).png")) == nil)
    }

    @Test func aSavedFileWithinTheToleranceIsUnchanged() throws {
        var item = try create()
        item.savedFileDate = now
        #expect(item.savedFileIsUnchanged(modifiedAt: now))
        #expect(item.savedFileIsUnchanged(modifiedAt: now.addingTimeInterval(0.005)))
        #expect(item.savedFileIsUnchanged(modifiedAt: now.addingTimeInterval(-0.005)))
    }

    @Test func aSavedFileChangedBeyondTheToleranceIsChanged() throws {
        var item = try create()
        item.savedFileDate = now
        #expect(!item.savedFileIsUnchanged(modifiedAt: now.addingTimeInterval(0.02)))
        #expect(!item.savedFileIsUnchanged(modifiedAt: now.addingTimeInterval(-60)))
        #expect(!item.savedFileIsUnchanged(modifiedAt: nil))
    }

    @Test func anItemWithNoRecordedDateCountsAsUnchanged() throws {
        let item = try create()
        #expect(item.savedFileDate == nil)
        #expect(item.savedFileIsUnchanged(modifiedAt: now))
        #expect(item.savedFileIsUnchanged(modifiedAt: nil))
    }

    @Test func createRecordsTheSavedFilesDateAndReloadingKeepsIt() throws {
        let saved = try savedFile(modified: now)
        let item = try HistoryWriter.create(image(width: 4, height: 4), details: details(savedURL: saved), root: root)
        let recorded = try #require(item.savedFileDate)
        #expect(abs(recorded.timeIntervalSince(now)) < 0.01)
        #expect(item.savedFileIsUnchanged(modifiedAt: HistoryWriter.modificationDate(of: saved)))
        #expect(HistoryStore(root: root).item(id: item.id)?.savedFileDate == recorded)
    }

    @Test func hasDocumentIsNilForNewAndOlderItemsAndSurvivesReloading() throws {
        var item = try create()
        #expect(item.hasDocument == nil)
        // An older meta.json has no such key, and decodes with it nil.
        let older = try JSONEncoder().encode(item)
        #expect(!String(decoding: older, as: UTF8.self).contains("hasDocument"))
        #expect(try JSONDecoder().decode(HistoryItem.self, from: older).hasDocument == nil)
        item.hasDocument = true
        try HistoryWriter.writeMetadata(item, root: root)
        #expect(HistoryStore(root: root).item(id: item.id)?.hasDocument == true)
    }

    @Test func detailsCarryHasDocument() throws {
        // Details made without it, from a capture too, leave it nil, so the item reads as never annotated.
        let capture = CaptureResult(kind: .selection, image: image(width: 4, height: 4), scale: 2, displayID: 1,
                                    globalRect: .zero, appName: nil, windowTitle: nil, createdAt: now, isTransparent: false)
        #expect(HistoryWriter.Details(capture: capture, displayName: "Name", savedURL: nil).hasDocument == nil)
        #expect(details().hasDocument == nil)
        #expect(try create().hasDocument == nil)
        var flagged = details(name: "Annotated")
        flagged.hasDocument = true
        let item = try HistoryWriter.create(image(width: 4, height: 4), details: flagged, root: root)
        #expect(item.hasDocument == true)
        #expect(HistoryStore(root: root).item(id: item.id)?.hasDocument == true)
        let initialized = HistoryWriter.Details(origin: .capture, captureKind: .selection, displayName: "Shot", savedURL: nil,
                                                scale: 1, appName: nil, isTransparent: false, globalRect: .zero,
                                                createdAt: now, hasDocument: true)
        #expect(initialized.hasDocument == true)
    }

    @Test func reloadPicksUpMetadataWrittenBehindTheStoresBack() throws {
        let store = HistoryStore(root: root)
        var item = try create(store, name: "Before")
        #expect(store.item(id: item.id)?.hasDocument == nil)
        // Something other than the store changes meta.json, as a save that failed partway can.
        item.hasDocument = true
        item.displayName = "After"
        try HistoryWriter.writeMetadata(item, root: root)
        #expect(store.item(id: item.id)?.hasDocument == nil)
        let reloaded = try #require(store.reload(item.id))
        #expect(reloaded == item)
        #expect(store.item(id: item.id) == item)
        #expect(store.items.count == 1)
    }

    @Test func reloadingAMissingItemChangesNothing() throws {
        let store = HistoryStore(root: root)
        let kept = try create(store, name: "Kept")
        #expect(store.reload(UUID()) == nil)
        #expect(store.items == [kept])
        // An item whose meta.json can't be read keeps its in-memory copy too.
        try Data("not json".utf8).write(to: kept.metadataURL(in: root))
        #expect(store.reload(kept.id) == nil)
        #expect(store.items == [kept])
    }

    // MARK: The four fields added later

    @Test func olderMetadataDecodesWithTheNewFieldsNil() throws {
        let created = try create()
        // An older meta.json: the item as an earlier build wrote it, without the four keys.
        let data = try Data(contentsOf: created.metadataURL(in: root))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["modifiedAt", "appBundleID", "windowTitle", "sourcePath"] { object[key] = nil }
        try JSONSerialization.data(withJSONObject: object).write(to: created.metadataURL(in: root))
        let store = HistoryStore(root: root)
        let older = try #require(store.item(id: created.id))
        #expect(older.modifiedAt == nil)
        #expect(older.appBundleID == nil)
        #expect(older.windowTitle == nil)
        #expect(older.sourcePath == nil)
        #expect(!older.isUnchangedSinceCreation)
        // Written again, it still has none of them.
        try store.update(older)
        let keys = try metadataKeys(of: older)
        #expect(keys.isDisjoint(with: ["modifiedAt", "appBundleID", "windowTitle", "sourcePath"]))
        #expect(keys.contains("createdAt"))
    }

    @Test func theNewFieldsRoundTrip() throws {
        var details = details(name: "Imported")
        details.appBundleID = "com.apple.Safari"
        details.windowTitle = "Start Page"
        details.sourcePath = "/Volumes/Data/Pictures/b.png"
        let item = try HistoryWriter.create(image(width: 4, height: 4), details: details, root: root)
        #expect(item.modifiedAt != nil)
        #expect(item.appBundleID == "com.apple.Safari")
        #expect(item.windowTitle == "Start Page")
        #expect(item.sourcePath == "/Volumes/Data/Pictures/b.png")
        #expect(HistoryStore(root: root).item(id: item.id) == item)
    }

    @Test func createStampsModifiedAtWithTheCreationDate() throws {
        let item = try create(age: 3_600)
        #expect(item.modifiedAt == item.createdAt)
        #expect(item.isUnchangedSinceCreation)
        #expect(HistoryStore(root: root).item(id: item.id)?.isUnchangedSinceCreation == true)
    }

    @Test func replaceImageStampsModifiedAtEvenWhenTheSizeIsUnchanged() throws {
        let item = try create(width: 40, height: 20)
        let updated = try HistoryWriter.replaceImage(of: item, with: image(width: 40, height: 20), scale: 2, root: root,
                                                     now: item.createdAt.addingTimeInterval(100))
        #expect(updated.modifiedAt == item.createdAt.addingTimeInterval(100))
        #expect(updated.pixelSize == item.pixelSize)
        #expect(!updated.isUnchangedSinceCreation)
        #expect(HistoryStore(root: root).item(id: item.id)?.modifiedAt == item.createdAt.addingTimeInterval(100))
    }

    @Test func aStudioProjectRoundTrips() throws {
        let item = try create(name: "Project", kind: .studioProject)
        #expect(HistoryStore(root: root).item(id: item.id)?.kind == .studioProject)
        let json = String(decoding: try Data(contentsOf: item.metadataURL(in: root)), as: UTF8.self)
        #expect(json.contains(#""kind" : "studioProject""#))
    }

    @Test func newestScreenshotSkipsVideosAndGIFs() throws {
        let store = HistoryStore(root: root)
        try create(store, name: "GIF", kind: .gif, age: 0)
        try create(store, name: "Video", kind: .video, age: 10)
        #expect(store.newestScreenshot == nil)
        let screenshot = try create(store, name: "Screenshot", age: 20)
        try create(store, name: "Older", age: 30)
        #expect(store.newestScreenshot == screenshot)
    }

    // MARK: Change events

    @Test func addingANewItemTellsObserversItWasAdded() throws {
        let store = HistoryStore(root: root)
        let log = record(store)
        let item = try create(store)
        #expect(log.changes == [.added(item.id)])
    }

    @Test func addingAKnownItemTellsObserversItWasUpdated() throws {
        let store = HistoryStore(root: root)
        var item = try create(store)
        let log = record(store)
        item.displayName = "Renamed"
        store.add(item)
        #expect(log.changes == [.updated(item.id)])
        #expect(store.items == [item])
    }

    @Test func updateAndReloadTellObserversItWasUpdated() throws {
        let store = HistoryStore(root: root)
        var item = try create(store)
        let log = record(store)
        item.displayName = "Renamed"
        try store.update(item)
        #expect(log.changes == [.updated(item.id)])
        store.reload(item.id)
        #expect(log.changes == [.updated(item.id), .updated(item.id)])
        // Nothing to reload, nothing to tell.
        store.reload(UUID())
        #expect(log.changes.count == 2)
    }

    @Test func removeTellsObserversOnceAndOnlyForListedItems() throws {
        let store = HistoryStore(root: root)
        let item = try create(store)
        let log = record(store)
        store.remove(item.id)
        #expect(log.changes == [.removed(item.id)])
        store.remove(item.id)
        store.remove(UUID())
        #expect(log.changes == [.removed(item.id)])
    }

    @Test func observersHearAboutARemovalAfterItIsDone() throws {
        let store = HistoryStore(root: root)
        let item = try create(store)
        var seen: (listed: Bool, folder: Bool)?
        store.observe { _ in seen = (store.item(id: item.id) != nil, self.exists(item.folder(in: self.root))) }
        store.remove(item.id)
        #expect(seen?.listed == false)
        #expect(seen?.folder == false)
    }

    @Test func purgeAndClearTellObserversEachRemovedItem() throws {
        let store = HistoryStore(root: root)
        let held = try create(store, name: "Held", age: 40 * 86_400)
        let expired = try (1...3).map { try create(store, name: "Expired \($0)", age: 40 * 86_400 + Double($0)) }
        store.holds.hold(held.id)
        let log = record(store)
        #expect(store.purge(retention: .oneMonth, now: now) == 3)
        #expect(log.changes == expired.map { .removed($0.id) })
        let recent = try (1...3).map { try create(store, name: "Recent \($0)", age: Double($0)) }
        log.changes = []
        store.clear()
        #expect(log.changes == recent.map { .removed($0.id) })
        #expect(store.items.map(\.id) == [held.id])
    }

    @Test func aRemovedObserverHearsNothing() throws {
        let store = HistoryStore(root: root)
        var heard: [HistoryChange] = []
        let token = store.observe { heard.append($0) }
        let first = try create(store)
        store.removeObserver(token)
        try create(store, name: "Second")
        store.remove(first.id)
        #expect(heard == [.added(first.id)])
    }

    @Test func anObserverRemovedDuringAnEventHearsNoMoreOfIt() throws {
        let store = HistoryStore(root: root)
        var heard: [String] = []
        var second: HistoryObserverToken?
        store.observe { _ in
            heard.append("first")
            if let second { store.removeObserver(second) }
        }
        second = store.observe { _ in heard.append("second") }
        try create(store)
        #expect(heard == ["first"])
    }

    @Test func observersAreCalledInRegistrationOrder() throws {
        let store = HistoryStore(root: root)
        var heard: [String] = []
        store.observe { _ in heard.append("first") }
        store.observe { _ in heard.append("second") }
        store.observe { _ in heard.append("third") }
        try create(store)
        #expect(heard == ["first", "second", "third"])
    }

    @Test func anObserverCanChangeTheStore() throws {
        let store = HistoryStore(root: root)
        let other = try create(store, name: "Other", age: 10)
        let item = try create(store, name: "Item")
        var heard: [HistoryChange] = []
        // Closing a pin on a removal can release a hold, and a release can purge.
        store.observe { change in
            heard.append(change)
            if change == .removed(item.id) { store.remove(other.id) }
        }
        store.remove(item.id)
        #expect(heard == [.removed(item.id), .removed(other.id)])
        #expect(store.items.isEmpty)
        #expect(!exists(other.folder(in: root)))
    }

    @Test func aMissingRootGivesAnEmptyStore() {
        #expect(HistoryStore(root: root.appending(path: "nowhere", directoryHint: .isDirectory)).items.isEmpty)
    }
}
