import CoreGraphics
import CSCapture
import CSCore
import CSHistory
import Foundation
import Testing
@testable import CSAnnotation

/// An image object that draws `ref` in a small rect.
private func pictureObject(_ ref: ImageRef) -> AnnotationObject {
    AnnotationObject(kind: .image(ImageObject(rect: CGRect(x: 0, y: 0, width: 4, height: 4), image: ref)),
                     style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 1, shadow: false))
}

/// Objects whose rendering is easiest to get subtly wrong on a reopen: a pixelate redaction (its noise is seeded by its id),
/// text, and an arrow.
private func renderSensitiveObjects() -> [AnnotationObject] {
    let style = ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 3, shadow: true)
    return [
        AnnotationObject(kind: .redact(RedactObject(rect: CGRect(x: 2, y: 2, width: 20, height: 14), style: .pixelate, intensity: 2)),
                         style: style),
        AnnotationObject(kind: .text(TextObject(origin: CGPoint(x: 4, y: 4), string: "Hi", style: .box, fontSize: 9)), style: style),
        AnnotationObject(kind: .arrow(ArrowShape(start: CGPoint(x: 30, y: 2), end: CGPoint(x: 10, y: 18), style: .standard)),
                         style: style),
    ]
}

final class DocumentPackageTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "packages-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func sample() -> (AnnotationDocument, ImageStore) {
        var (document, images) = TestBitmaps.document(base: TestBitmaps.solid(40, 30, TestBitmaps.blue))
        let picture = ImageRef(name: "images/\(UUID().uuidString).png")
        images.set(TestBitmaps.solid(4, 4, TestBitmaps.red), for: picture)
        let style = ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 3, shadow: true)
        document.objects = [
            AnnotationObject(kind: .arrow(ArrowShape(start: .zero, end: CGPoint(x: 30, y: 20), style: .fancy)), style: style),
            AnnotationObject(kind: .image(ImageObject(rect: CGRect(x: 1, y: 1, width: 8, height: 8), image: picture)), style: style),
        ]
        return (document, images)
    }

    @Test func roundTrip() throws {
        let (document, images) = sample()
        let rendered = try #require(Renderer.render(document, images: images))
        let url = folder.appending(path: "Shot.clearshot", directoryHint: .isDirectory)
        try DocumentPackage.write(document, images: images, rendered: rendered, to: url)
        let (read, readImages) = try DocumentPackage.read(from: url)
        #expect(read == document)
        #expect(readImages[read.base]?.width == 40)
        guard case .image(let object) = read.objects[1].kind else { Issue.record("not an image object"); return }
        #expect(readImages[object.image]?.width == 4)
        let preview = try #require(ImageOps.load(url.appending(path: DocumentPackage.previewPath)))
        #expect(preview.width == rendered.width)
        #expect(FileManager.default.fileExists(atPath: url.appending(path: DocumentPackage.thumbnailPath).path(percentEncoded: false)))
    }

    @Test func reopeningRendersIdentically() throws {
        var (document, images) = TestBitmaps.document(base: TestBitmaps.noise(40, 30))
        document.objects = renderSensitiveObjects()
        let before = try #require(Renderer.render(document, images: images))
        let url = folder.appending(path: "Same.clearshot", directoryHint: .isDirectory)
        try DocumentPackage.write(document, images: images, rendered: before, to: url)
        let (read, readImages) = try DocumentPackage.read(from: url)
        let after = try #require(Renderer.render(read, images: readImages))
        #expect(after.width == before.width && after.height == before.height)
        let identical = TestBitmaps.bytes(after) == TestBitmaps.bytes(before)
        #expect(identical)
    }

    @Test func aProjectSavedFromAHistoryDocumentStoresOriginalPNG() throws {
        // A capture's document keeps its base as the hidden ".original.png"; a project made from it must not.
        var (document, images) = sample()
        let capture = try #require(images[document.base])
        document.base = AnnotationStorage.historyBase
        images = ImageStore(images.images.filter { $0.key != ImageRef.original.name })
        images.set(capture, for: AnnotationStorage.historyBase)
        let rendered = try #require(Renderer.render(document, images: images))
        let url = folder.appending(path: "FromCapture.clearshot", directoryHint: .isDirectory)
        try DocumentPackage.write(document, images: images, rendered: rendered, to: url)
        #expect(FileManager.default.fileExists(atPath: url.appending(path: ImageRef.original.name).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: AnnotationStorage.historyBase.name).path(percentEncoded: false)))
        let stored = try JSONDecoder().decode(AnnotationDocument.self,
                                              from: Data(contentsOf: url.appending(path: DocumentPackage.documentFileName)))
        #expect(stored.base == .original)
        let (read, readImages) = try DocumentPackage.read(from: url)
        #expect(read.objects == document.objects)
        #expect(read.base == .original)
        #expect(TestBitmaps.bytes(try #require(readImages[read.base])) == TestBitmaps.bytes(capture))
        // The caller's document still names its own base.
        #expect(document.base == AnnotationStorage.historyBase)
    }

    @Test func savingAgainReplacesThePackageCleanly() throws {
        var (document, images) = sample()
        let rendered = try #require(Renderer.render(document, images: images))
        let url = folder.appending(path: "Again.clearshot", directoryHint: .isDirectory)
        try DocumentPackage.write(document, images: images, rendered: rendered, to: url)
        document.objects.removeAll()
        try DocumentPackage.write(document, images: images, rendered: rendered, to: url)
        #expect(try DocumentPackage.read(from: url).document.objects.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == ["Again.clearshot"])
    }

    @Test func aNewerVersionIsRejectedWithAClearError() throws {
        let url = folder.appending(path: "Future.clearshot", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"version": 99}"#.utf8).write(to: url.appending(path: DocumentPackage.documentFileName))
        #expect(throws: DocumentError.newerVersion) { try DocumentPackage.readDocument(from: url) }
    }

    @Test func aCorruptDocumentIsUnreadable() throws {
        let url = folder.appending(path: "Broken.clearshot", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url.appending(path: DocumentPackage.documentFileName))
        #expect(throws: DocumentError.self) { try DocumentPackage.readDocument(from: url) }
    }

    @Test func aMissingBaseImageIsReported() throws {
        let (document, _) = sample()
        let url = folder.appending(path: "NoBase.clearshot", directoryHint: .isDirectory)
        try DocumentPackage.writeContents(document, images: ImageStore(), to: url)
        #expect(throws: DocumentError.missingBase) { try DocumentPackage.read(from: url) }
    }

    @Test func aSaveThatFailsLeavesTheOldPackageReadable() throws {
        let (document, images) = sample()
        let rendered = try #require(Renderer.render(document, images: images))
        let url = folder.appending(path: "Keep.clearshot", directoryHint: .isDirectory)
        try DocumentPackage.write(document, images: images, rendered: rendered, to: url)
        // No base image to write: the new package couldn't be opened, so it must not replace the good one.
        #expect(throws: DocumentError.missingBase) {
            try DocumentPackage.write(document, images: ImageStore(), rendered: rendered, to: url)
        }
        let (read, readImages) = try DocumentPackage.read(from: url)
        #expect(read == document)
        #expect(readImages[read.base]?.width == 40)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == ["Keep.clearshot"])
    }

    @Test func aFirstSaveWithoutABaseCreatesNothing() throws {
        let (document, images) = sample()
        let rendered = try #require(Renderer.render(document, images: images))
        let url = folder.appending(path: "Never.clearshot", directoryHint: .isDirectory)
        #expect(throws: DocumentError.missingBase) {
            try DocumentPackage.write(document, images: ImageStore(), rendered: rendered, to: url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == [])
    }

    // MARK: Numbers a document.json we didn't write might hold

    /// A package written from `sample()` whose `document.json` is then edited by hand, as JSON.
    func packageWithEditedDocument(_ edit: (inout [String: Any]) -> Void) throws -> URL {
        let (document, images) = sample()
        let rendered = try #require(Renderer.render(document, images: images))
        let url = folder.appending(path: "Edited.clearshot", directoryHint: .isDirectory)
        try DocumentPackage.write(document, images: images, rendered: rendered, to: url)
        let file = url.appending(path: DocumentPackage.documentFileName)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        edit(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        return url
    }

    @Test(arguments: [0.0, -2.0, 16.5, 1e300])
    func aPackageWithZeroScaleIsRejected(scale: Double) throws {
        let url = try packageWithEditedDocument { $0["pixelScale"] = scale }
        let error = DocumentError.unreadable(url.path(percentEncoded: false))
        #expect(throws: error) { try DocumentPackage.readDocument(from: url) }
        #expect(throws: error) { try DocumentPackage.read(from: url) }
    }

    @Test(arguments: [[0.0, 30], [40, -30], [40_000, 30], [40, 1e300]])
    func aPackageWithAnImpossibleBaseSizeIsRejected(size: [Double]) throws {
        let url = try packageWithEditedDocument { $0["baseSize"] = size }
        #expect(throws: DocumentError.unreadable(url.path(percentEncoded: false))) { try DocumentPackage.readDocument(from: url) }
    }

    /// A canvas, or a resize, that would make the editor's canvas enormous.
    @Test(arguments: [#"{"canvasRect": [[0, 0], [1e9, 30]]}"#, #"{"imageOps": [{"resize": {"width": 1000000, "height": 30}}]}"#,
                      #"{"pixelScale": 0.000001}"#])
    func aPackageWithAnEnormousCanvasIsRejected(fields: String) throws {
        let changes = try #require(JSONSerialization.jsonObject(with: Data(fields.utf8)) as? [String: Any])
        let url = try packageWithEditedDocument { $0.merge(changes) { _, new in new } }
        #expect(throws: DocumentError.unreadable(url.path(percentEncoded: false))) { try DocumentPackage.readDocument(from: url) }
    }

    @Test func aPackageWhoseBaseSizeDisagreesWithItsImageIsRejected() throws {
        // The base is 40 by 30; the document says 20 by 30, which would stretch it under redactions clipped to its pixels.
        let url = try packageWithEditedDocument { $0["baseSize"] = [20, 30] }
        #expect(throws: DocumentError.unreadable(url.path(percentEncoded: false))) { try DocumentPackage.read(from: url) }
    }

    @Test func aPackageWithinTheLimitsStillOpens() throws {
        let url = try packageWithEditedDocument { $0["pixelScale"] = 16 }
        #expect(try DocumentPackage.read(from: url).document.pixelScale == 16)
    }

    @Test func longNamesCanBeSaved() throws {
        let (document, images) = sample()
        let rendered = try #require(Renderer.render(document, images: images))
        let name = String(repeating: "n", count: 220) + ".clearshot"
        let url = folder.appending(path: name, directoryHint: .isDirectory)
        try DocumentPackage.write(document, images: images, rendered: rendered, to: url)
        #expect(try DocumentPackage.read(from: url).document == document)
        // Saving over it works too: the staging folder's name doesn't grow with the package's.
        try DocumentPackage.write(document, images: images, rendered: rendered, to: url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == [name])
    }

    // MARK: Image names that lead outside the package

    /// Names that a `document.json` we didn't write might use to reach other files.
    static let unsafeNames = ["../evil.png", "images/../../evil.png", "/etc/hosts", "~/evil.png", "images//evil.png", ""]

    /// A package whose `document.json` is `document`, written by hand. Beside it sits `evil.png`, a file a traversing name
    /// could reach; the real base is inside.
    func hostilePackage(_ document: AnnotationDocument) throws -> URL {
        let url = folder.appending(path: "Hostile.clearshot", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let png = try ImageEncoder.encode(TestBitmaps.solid(4, 4, TestBitmaps.red), as: .png, quality: 1)
        try png.write(to: folder.appending(path: "evil.png"))
        try png.write(to: url.appending(path: ImageRef.original.name))
        try JSONEncoder().encode(document).write(to: url.appending(path: DocumentPackage.documentFileName))
        return url
    }

    @Test(arguments: unsafeNames) func anImageObjectNamingAPathOutsideThePackageIsUnreadable(name: String) throws {
        var (document, _) = sample()
        document.objects = [pictureObject(ImageRef(name: name))]
        let url = try hostilePackage(document)
        let error = DocumentError.unreadable(url.path(percentEncoded: false))
        #expect(throws: error) { try DocumentPackage.readDocument(from: url) }
        #expect(throws: error) { try DocumentPackage.read(from: url) }
    }

    @Test(arguments: unsafeNames) func aBaseNamingAPathOutsideThePackageIsUnreadable(name: String) throws {
        var (document, _) = sample()
        document.base = ImageRef(name: name)
        let url = try hostilePackage(document)
        let error = DocumentError.unreadable(url.path(percentEncoded: false))
        #expect(throws: error) { try DocumentPackage.readDocument(from: url) }
        #expect(throws: error) { try DocumentPackage.read(from: url) }
    }

    @Test func aLinkInsideThePackageIsUnreadable() throws {
        var (document, _) = sample()
        document.objects = [pictureObject(ImageRef(name: "images/linked.png"))]
        let url = try hostilePackage(document)
        try FileManager.default.createSymbolicLink(at: url.appending(path: "images"), withDestinationURL: folder)
        #expect(throws: DocumentError.unreadable(url.path(percentEncoded: false))) { try DocumentPackage.read(from: url) }
    }

    @Test func writingAnImageNamedOutsideThePackageThrowsAndCreatesNothing() throws {
        var (document, images) = sample()
        let evil = ImageRef(name: "../evil.png")
        images.set(TestBitmaps.solid(4, 4, TestBitmaps.red), for: evil)
        document.objects = [pictureObject(evil)]
        let url = folder.appending(path: "Evil.clearshot", directoryHint: .isDirectory)
        #expect(throws: DocumentError.unsafeImageName("../evil.png")) {
            try DocumentPackage.writeContents(document, images: images, to: url)
        }
        // Not even the package folder or the valid base is written, and nothing lands beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == [])
    }

    @Test func writingAWholePackageWithAnUnsafeNameLeavesNothingBehind() throws {
        var (document, images) = sample()
        let evil = ImageRef(name: "../../evil.png")
        images.set(TestBitmaps.solid(4, 4, TestBitmaps.red), for: evil)
        document.objects = [pictureObject(evil)]
        let rendered = try #require(Renderer.render(document, images: images))
        let url = folder.appending(path: "Evil.clearshot", directoryHint: .isDirectory)
        #expect(throws: DocumentError.unsafeImageName("../../evil.png")) {
            try DocumentPackage.write(document, images: images, rendered: rendered, to: url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == [])
    }
}

final class AnnotationStorageTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "annotated-history-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func capture(named name: String = "Shot") throws -> HistoryItem {
        let details = HistoryWriter.Details(origin: .capture, captureKind: .selection, displayName: name, savedURL: nil, scale: 2,
                                            appName: nil, isTransparent: false, globalRect: .zero, createdAt: Date())
        return try HistoryWriter.create(TestBitmaps.solid(40, 20, TestBitmaps.blue), details: details, root: root)
    }

    @Test func anExpandedTransparentWindowShotStaysTransparentAndSavesAsPNG() throws {
        let details = HistoryWriter.Details(origin: .capture, captureKind: .window, displayName: "Window", savedURL: nil, scale: 1,
                                            appName: nil, isTransparent: true, globalRect: .zero, createdAt: Date())
        let window = TestBitmaps.transparent(40, 20, blocks: [CGRect(x: 5, y: 5, width: 30, height: 10)])
        let item = try HistoryWriter.create(window, details: details, root: root)
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.canvasRect = CGRect(x: -10, y: -10, width: 60, height: 40) // canvasFill stays Auto
        let rendered = try #require(Renderer.render(document, images: images))
        // The new area takes the transparent edge.
        #expect(TestBitmaps.pixel(rendered, 2, 2).a == 0)
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        #expect(saved.isTransparent)
        #expect(ExportFormatPolicy.format(preferred: .jpeg, isTransparent: saved.isTransparent) == .png)
    }

    @Test @MainActor func aTransparentFillOnAnOpaqueCaptureMarksItTransparent() throws {
        let item = try capture()
        #expect(!item.isTransparent)
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.canvasRect = CGRect(x: -10, y: 0, width: 50, height: 20)
        document.canvasFill = .transparent
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        #expect(saved.isTransparent)
        let reloaded = try #require(HistoryStore(root: root).item(id: item.id))
        #expect(reloaded.isTransparent)
    }

    @Test func anOpaqueAnnotatedCaptureIsNotTransparent() throws {
        let item = try capture()
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.objects = [AnnotationObject(kind: .filledRectangle(CGRect(x: 2, y: 2, width: 10, height: 10)),
                                             style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 2, shadow: false))]
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        #expect(!saved.isTransparent)
    }

    @Test func openingANewItemKeepsTheCaptureAsTheOriginal() throws {
        let item = try capture()
        let (document, images, recovered) = try AnnotationStorage.open(item, root: root)
        #expect(!recovered) // never annotated: nothing to recover
        #expect(document.baseSize == CGSize(width: 40, height: 20))
        #expect(document.pixelScale == 2)
        #expect(document.objects.isEmpty)
        #expect(document.base == AnnotationStorage.historyBase)
        #expect(images[AnnotationStorage.historyBase]?.width == 40)
        #expect(FileManager.default.fileExists(atPath: item.folder(in: root).appending(path: ".original.png").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: item.mediaURL(in: root).path(percentEncoded: false)))
    }

    @Test @MainActor func saveThenReopen() throws {
        let item = try capture()
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.objects = [AnnotationObject(kind: .filledRectangle(CGRect(x: 2, y: 2, width: 10, height: 10)),
                                             style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 2, shadow: false))]
        document.canvasRect = CGRect(x: -5, y: -5, width: 50, height: 30)
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        #expect(saved.hasDocument == true)
        #expect(saved.pixelSize == CGSize(width: 50, height: 30))
        #expect(ImageOps.load(saved.mediaURL(in: root))?.width == 50)
        let reloaded = try #require(HistoryStore(root: root).item(id: item.id))
        #expect(reloaded.hasDocument == true)
        let (reopened, reopenedImages, recovered) = try AnnotationStorage.open(reloaded, root: root)
        #expect(reopened == document)
        #expect(!recovered)
        #expect(reopenedImages[AnnotationStorage.historyBase]?.width == 40)
    }

    @Test func reopeningAnAnnotatedCaptureRendersIdentically() throws {
        let details = HistoryWriter.Details(origin: .capture, captureKind: .selection, displayName: "Noise", savedURL: nil, scale: 2,
                                            appName: nil, isTransparent: false, globalRect: .zero, createdAt: Date())
        let item = try HistoryWriter.create(TestBitmaps.noise(40, 30), details: details, root: root)
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.objects = renderSensitiveObjects()
        let before = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: before, to: item, root: root)
        let (reopened, reopenedImages, _) = try AnnotationStorage.open(saved, root: root)
        let after = try #require(Renderer.render(reopened, images: reopenedImages))
        let identical = TestBitmaps.bytes(after) == TestBitmaps.bytes(before)
        #expect(identical)
    }

    @Test func anUnreadableDocumentFallsBackToTheOriginal() throws {
        let item = try capture()
        let (document, images, _) = try AnnotationStorage.open(item, root: root)
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        try Data("garbage".utf8).write(to: saved.folder(in: root).appending(path: DocumentPackage.documentFileName))
        let (fallback, fallbackImages, recovered) = try AnnotationStorage.open(saved, root: root)
        #expect(fallback.objects.isEmpty)
        #expect(recovered) // the editor says the annotations couldn't be read
        #expect(fallbackImages[AnnotationStorage.historyBase]?.width == 40)
    }

    @Test @MainActor func aRecoveredCaptureChangedInQuickAccessBecomesTheCaptureOfRecord() throws {
        let item = try capture()
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.objects = [AnnotationObject(kind: .filledRectangle(CGRect(x: 2, y: 2, width: 10, height: 10)),
                                             style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 2, shadow: false))]
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        let documentFile = saved.folder(in: root).appending(path: DocumentPackage.documentFileName)
        try Data("garbage".utf8).write(to: documentFile)
        #expect(try AnnotationStorage.open(saved, root: root).recovered)
        // Quick Access rotates the working copy, annotations and all (its document couldn't be read): that is the capture now.
        let rotated = TestBitmaps.solid(20, 40, TestBitmaps.red)
        let updated = try AnnotationStorage.makeCaptureOfRecord(rotated, scale: 2, for: saved, root: root)
        #expect(updated.hasDocument != true)
        #expect(updated.pixelSize == CGSize(width: 20, height: 40))
        #expect(HistoryStore(root: root).item(id: item.id)?.hasDocument != true)
        #expect(!FileManager.default.fileExists(atPath: documentFile.path(percentEncoded: false)))
        // The next open starts afresh from the rotated working copy: no repeat recovery, no stale unrotated original.
        let reloaded = try #require(HistoryStore(root: root).item(id: item.id))
        let (reopened, reopenedImages, recovered) = try AnnotationStorage.open(reloaded, root: root)
        #expect(!recovered)
        #expect(reopened.objects.isEmpty)
        #expect(reopened.baseSize == CGSize(width: 20, height: 40))
        #expect(TestBitmaps.pixel(try #require(reopenedImages[reopened.base]), 5, 5) == .init(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func anAnnotatedItemWhoseBaseIsGoneIsRecovered() throws {
        let item = try capture()
        let (document, images, _) = try AnnotationStorage.open(item, root: root)
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        try FileManager.default.removeItem(at: saved.folder(in: root).appending(path: AnnotationStorage.historyBase.name))
        let (fallback, fallbackImages, recovered) = try AnnotationStorage.open(saved, root: root)
        #expect(fallback.objects.isEmpty)
        #expect(recovered)
        #expect(fallbackImages[fallback.base]?.width == 40)
    }

    @Test func aHistoryDocumentTakesItsBaseSizeFromItsBase() throws {
        let item = try capture()
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.objects = [AnnotationObject(kind: .filledRectangle(CGRect(x: 2, y: 2, width: 10, height: 10)),
                                             style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 2, shadow: false))]
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        // The document's size goes wrong; the base beside it is ours, so it is the one to believe.
        var wrong = document
        wrong.baseSize = CGSize(width: 30, height: 10)
        try JSONEncoder().encode(wrong).write(to: saved.folder(in: root).appending(path: DocumentPackage.documentFileName))
        let (reopened, _, recovered) = try AnnotationStorage.open(saved, root: root)
        #expect(reopened.baseSize == CGSize(width: 40, height: 20))
        #expect(reopened.objects == document.objects)
        #expect(!recovered)
    }

    @Test func aNeverAnnotatedItemsBaseFollowsItsWorkingCopy() throws {
        let item = try capture()
        _ = try AnnotationStorage.open(item, root: root) // Creates the base, then the editor is discarded.
        // Quick Access rotates the capture: the working copy is now 20 by 40.
        let rotated = try HistoryWriter.replaceImage(of: item, with: TestBitmaps.solid(20, 40, TestBitmaps.red), scale: 2, root: root)
        let (document, images, _) = try AnnotationStorage.open(rotated, root: root)
        #expect(document.baseSize == CGSize(width: 20, height: 40))
        #expect(images[document.base]?.width == 20)
        #expect(TestBitmaps.pixel(try #require(images[document.base]), 5, 5) == .init(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func anAnnotatedItemKeepsItsBaseWhateverItsWorkingCopyIs() throws {
        let item = try capture()
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.canvasRect = CGRect(x: -5, y: -5, width: 50, height: 30)
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        // The working copy is a 50 by 30 render, but the base is still the 40 by 20 capture.
        let (reopened, reopenedImages, _) = try AnnotationStorage.open(saved, root: root)
        #expect(reopened.baseSize == CGSize(width: 40, height: 20))
        #expect(reopenedImages[reopened.base]?.width == 40)
    }

    @Test(arguments: ["original", "Original", ".original"])
    @MainActor func openingAnItemNamedOriginalKeepsTheCapture(name: String) throws {
        // Its working copy is "original.png", which must not be the document's base: saving would overwrite the capture.
        let item = try capture(named: name)
        #expect(item.mediaFileName.lowercased() == "original.png")
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.objects = [AnnotationObject(kind: .filledRectangle(CGRect(x: 2, y: 2, width: 10, height: 10)),
                                             style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 2, shadow: false))]
        document.canvasRect = CGRect(x: -5, y: -5, width: 50, height: 30)
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        #expect(saved.pixelSize == CGSize(width: 50, height: 30))
        let reloaded = try #require(HistoryStore(root: root).item(id: item.id))
        let (reopened, reopenedImages, _) = try AnnotationStorage.open(reloaded, root: root)
        #expect(reopened.objects.count == 1)
        let base = try #require(reopenedImages[reopened.base])
        #expect(base.width == 40 && base.height == 20)
        #expect(TestBitmaps.bytes(base) == TestBitmaps.bytes(TestBitmaps.solid(40, 20, TestBitmaps.blue)))
        #expect(FileManager.default.fileExists(atPath: saved.folder(in: root).appending(path: ".original.png").path(percentEncoded: false)))
    }

    /// A 2x capture, 40 by 20 pixels, resized. 22 by 9 is a scale of 0.995 times 2: close enough to 1x to read as 1x.
    @Test(arguments: [(20, 10, 1.0), (22, 9, 1.0), (30, 15, 1.5), (40, 20, 2.0)])
    func theSavedScaleFollowsResizeOps(width: Int, height: Int, expected: Double) throws {
        let item = try capture()
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.imageOps = [.resize(width: width, height: height)]
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        #expect(saved.pixelSize == CGSize(width: width, height: height))
        #expect(saved.scale == expected)
        // What the editor's copies and drags record as their density: the same scale.
        #expect(document.renderedScale == expected)
    }

    @Test(arguments: [(1.004, 1.0), (0.996, 1.0), (1.996, 2.0), (2.01, 2.0), (1.5, 1.5), (1.02, 1.02), (0.4, 0.4), (0.004, 0.004)])
    func scalesNearAWholeNumberSnapToIt(scale: Double, expected: Double) {
        #expect(AnnotationStorage.snapped(scale: scale) == expected)
    }

    @Test func aDocumentNamingAPathOutsideTheItemFallsBackToTheOriginal() throws {
        let item = try capture()
        let (document, images, _) = try AnnotationStorage.open(item, root: root)
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        // The history root holds other items: a traversing name could reach their files.
        let other = try capture()
        var hostile = document
        hostile.objects = [pictureObject(ImageRef(name: "../\(other.id.uuidString)/\(other.mediaFileName)"))]
        try JSONEncoder().encode(hostile).write(to: saved.folder(in: root).appending(path: DocumentPackage.documentFileName))
        let (fallback, _, recovered) = try AnnotationStorage.open(saved, root: root)
        #expect(fallback.objects.isEmpty)
        #expect(recovered)
    }

    @Test @MainActor func anInterruptedFirstSaveKeepsTheCapture() throws {
        let item = try capture()
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.objects = [AnnotationObject(kind: .filledRectangle(CGRect(x: 2, y: 2, width: 10, height: 10)),
                                             style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 2, shadow: false))]
        let rendered = try #require(Renderer.render(document, images: images))
        // The working copy is written first and the thumbnail second: a directory in the thumbnail's place makes that
        // second write throw, leaving the annotated render on disk before the item's metadata could say so.
        let thumbnail = item.thumbnailURL(in: root)
        try FileManager.default.removeItem(at: thumbnail)
        try FileManager.default.createDirectory(at: thumbnail, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        }
        // The annotated render did replace the working copy, so the flag has to be on disk by now.
        let working = try #require(ImageOps.load(item.mediaURL(in: root)))
        let workingIsTheRender = TestBitmaps.bytes(working) == TestBitmaps.bytes(rendered)
        #expect(workingIsTheRender)
        let reloaded = try #require(HistoryStore(root: root).item(id: item.id))
        #expect(reloaded.hasDocument == true)
        // Opening it again reads the document over the untouched capture instead of copying the render over the base.
        let (reopened, reopenedImages, _) = try AnnotationStorage.open(reloaded, root: root)
        #expect(reopened.objects.count == 1)
        let base = try #require(reopenedImages[reopened.base])
        #expect(base.width == 40 && base.height == 20)
        let baseIsTheCapture = TestBitmaps.bytes(base) == TestBitmaps.bytes(TestBitmaps.solid(40, 20, TestBitmaps.blue))
        #expect(baseIsTheCapture)
    }

    @Test @MainActor func anInterruptedSaveLeavesTheTransparencyOfTheWorkingCopyAlone() throws {
        let details = HistoryWriter.Details(origin: .capture, captureKind: .window, displayName: "Window", savedURL: nil, scale: 1,
                                            appName: nil, isTransparent: true, globalRect: .zero, createdAt: Date())
        let window = TestBitmaps.transparent(40, 20, blocks: [CGRect(x: 5, y: 5, width: 30, height: 10)])
        let item = try HistoryWriter.create(window, details: details, root: root)
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        document.canvasFill = .color(RGBAColor(red: 1, green: 0, blue: 0)) // the see-through area shows the fill: an opaque render
        let rendered = try #require(Renderer.render(document, images: images))
        #expect(!ImageOps.hasTransparentPixels(rendered))
        // A directory where the working copy goes makes its write throw, before anything of the render is on disk.
        try FileManager.default.removeItem(at: item.mediaURL(in: root))
        try FileManager.default.createDirectory(at: item.mediaURL(in: root), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        }
        // The flag is on disk (the document was written), but the working copy is still the transparent capture, so its
        // metadata keeps saying so: the transparency of the render goes in with the render, in the final metadata.
        let reloaded = try #require(HistoryStore(root: root).item(id: item.id))
        #expect(reloaded.hasDocument == true)
        #expect(reloaded.isTransparent)
    }

    @Test @MainActor func savingADocumentWithAnUnsafeImageNameThrowsBeforeTouchingTheItem() throws {
        let item = try capture()
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        let evil = ImageRef(name: "../evil.png")
        images.set(TestBitmaps.solid(4, 4, TestBitmaps.red), for: evil)
        document.objects = [pictureObject(evil)]
        let rendered = try #require(Renderer.render(document, images: images))
        #expect(throws: DocumentError.unsafeImageName("../evil.png")) {
            try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "evil.png").path(percentEncoded: false)))
        #expect(HistoryStore(root: root).item(id: item.id)?.hasDocument != true)
    }
}
