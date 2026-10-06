import CoreGraphics
import CSCapture
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CSAnnotation

/// Where a background's picture comes from and how it is kept: the stored size, blur and name of a prepared picture,
/// the custom image library, the system wallpapers and their thumbnails. Every folder is a temporary one.
struct BackgroundSourceTests {
    /// A temporary folder, removed by the caller.
    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "background-sources-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try ImageEncoder.encode(image, as: .png, quality: 1).write(to: url)
    }

    static func size(_ image: CGImage?) -> CGSize? {
        image.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// A solid picture in Display P3, as the system's HEIC wallpapers are.
    static func displayP3(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(TestBitmaps.blue)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: Stored sizes

    @Test func aBlurredPictureIsStoredAtMost512() {
        let frame = CGSize(width: 1000, height: 500)
        #expect(BackgroundImagePrep.storedSize(source: CGSize(width: 6016, height: 3384), frame: frame, blurred: true)
            == CGSize(width: 512, height: 288))
        #expect(BackgroundImagePrep.storedSize(source: CGSize(width: 3384, height: 6016), frame: frame, blurred: true)
            == CGSize(width: 288, height: 512))
        #expect(BackgroundImagePrep.storedSize(source: CGSize(width: 300, height: 200), frame: frame, blurred: true)
            == CGSize(width: 300, height: 200))
    }

    @Test func aSharpPictureCoversTheFrameTimesOneAndAHalf() {
        let source = CGSize(width: 6000, height: 4000)
        #expect(BackgroundImagePrep.storedSize(source: source, frame: CGSize(width: 1000, height: 500), blurred: false)
            == CGSize(width: 1500, height: 1000))
        // A tall frame: the height decides.
        #expect(BackgroundImagePrep.storedSize(source: source, frame: CGSize(width: 500, height: 1000), blurred: false)
            == CGSize(width: 2250, height: 1500))
    }

    @Test func aSharpPictureIsNeverUpscaled() {
        #expect(BackgroundImagePrep.storedSize(source: CGSize(width: 800, height: 600), frame: CGSize(width: 2000, height: 2000),
                                               blurred: false) == CGSize(width: 800, height: 600))
    }

    @Test func aSharpPictureIsAtMost4096() {
        #expect(BackgroundImagePrep.storedSize(source: CGSize(width: 8000, height: 4000),
                                               frame: CGSize(width: 5000, height: 3000), blurred: false)
            == CGSize(width: 4096, height: 2048))
    }

    /// A thin panorama's short side would round to nothing.
    @Test func aStoredSizeIsAtLeastOnePixel() {
        #expect(BackgroundImagePrep.storedSize(source: CGSize(width: 20000, height: 2), frame: CGSize(width: 20000, height: 2),
                                               blurred: false) == CGSize(width: 4096, height: 1))
        #expect(BackgroundImagePrep.storedSize(source: CGSize(width: 4000, height: 3), frame: CGSize(width: 100, height: 100),
                                               blurred: true) == CGSize(width: 512, height: 1))
    }

    // MARK: Preparing

    @Test func aWindowWallpaperIsStoredAsCaptured() {
        let picture = TestBitmaps.solid(600, 400, TestBitmaps.red)
        let prepared = BackgroundImagePrep.prepare(picture, for: .windowWallpaper, frame: CGSize(width: 100, height: 100))
        #expect(prepared === picture)
    }

    @Test func nonImageFillsPrepareNothing() {
        let picture = TestBitmaps.solid(600, 400, TestBitmaps.red)
        let fills: [BackgroundFill] = [BackgroundFill.none, .color(RGBAColor(red: 1, green: 0, blue: 0)), .gradient(.standard),
                                       .blurredScreenshot]
        for fill in fills {
            #expect(BackgroundImagePrep.prepare(picture, for: fill, frame: CGSize(width: 100, height: 100)) == nil)
        }
    }

    @Test func sharpPicturesAreStoredAtTheirStoredSize() {
        let picture = TestBitmaps.noise(1200, 800)
        let frame = CGSize(width: 400, height: 200)
        let fills: [BackgroundFill] = [.desktop, .systemWallpaper(fileName: "Sonoma.heic"), .custom(id: UUID())]
        for fill in fills {
            let prepared = BackgroundImagePrep.prepare(picture, for: fill, frame: frame)
            #expect(Self.size(prepared) == CGSize(width: 600, height: 400))
        }
        // Already its stored size: kept as it is.
        let fitting = TestBitmaps.noise(600, 400)
        #expect(BackgroundImagePrep.prepare(fitting, for: .desktop, frame: frame) === fitting)
    }

    @Test func blurredPicturesAreBlurred() throws {
        let picture = TestBitmaps.split(1024, 256, left: TestBitmaps.red, right: TestBitmaps.blue)
        let frame = CGSize(width: 100, height: 100)
        let prepared = try #require(BackgroundImagePrep.prepare(picture, for: .blurredDesktop, frame: frame))
        #expect(Self.size(prepared) == BackgroundImagePrep.storedSize(source: CGSize(width: 1024, height: 256), frame: frame,
                                                                      blurred: true))
        #expect(Self.size(prepared) == CGSize(width: 512, height: 128))
        let edge = TestBitmaps.pixel(prepared, 0, 64)
        #expect(edge.r > 240 && edge.b < 15)
        let middle = TestBitmaps.pixel(prepared, 256, 64)
        #expect((64...192).contains(middle.r) && (64...192).contains(middle.b))
    }

    /// The system's HEIC wallpapers are Display P3, and an HDR picture is extended-range float, which an 8-bit bitmap in its
    /// own colour space can't hold: both still prepare, sharp and blurred.
    @Test func wideColorPicturesStillPrepare() {
        let frame = CGSize(width: 400, height: 200)
        for picture in [Self.displayP3(1200, 800), TestBitmaps.extendedSRGB(1200, 800, TestBitmaps.red)] {
            #expect(Self.size(BackgroundImagePrep.prepare(picture, for: .systemWallpaper(fileName: "Sonoma.heic"), frame: frame))
                == CGSize(width: 600, height: 400))
            #expect(Self.size(BackgroundImagePrep.prepare(picture, for: .blurredDesktop, frame: frame))
                == CGSize(width: 512, height: 341))
        }
    }

    // MARK: Names

    @Test func opaquePicturesGetJPGNamesAndTransparentOnesPNG() throws {
        let opaque = BackgroundImagePrep.reference(for: TestBitmaps.solid(8, 8, TestBitmaps.red))
        let partlyClear = TestBitmaps.transparent(8, 8, blocks: [CGRect(x: 0, y: 0, width: 4, height: 4)])
        let transparent = BackgroundImagePrep.reference(for: partlyClear)
        for (ref, ext) in [(opaque, "jpg"), (transparent, "png")] {
            #expect(ref.name.hasPrefix("images/background-"))
            #expect(ref.name.hasSuffix(".\(ext)"))
            let id = ref.name.dropFirst("images/background-".count).dropLast(ext.count + 1)
            #expect(UUID(uuidString: String(id)) != nil)
        }
        // A picture without an alpha channel is opaque.
        #expect(BackgroundImagePrep.reference(for: Self.displayP3(8, 8)).name.hasSuffix(".jpg"))
        // A fresh name each time.
        let picture = TestBitmaps.solid(8, 8, TestBitmaps.red)
        #expect(BackgroundImagePrep.reference(for: picture) != BackgroundImagePrep.reference(for: picture))
    }

    // MARK: The custom image library

    @Test func addingCopiesUnderANewID() throws {
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Holiday Photo.PNG")
        try Self.writePNG(TestBitmaps.solid(20, 10, TestBitmaps.red), to: source)
        let original = try Data(contentsOf: source)
        // The folder doesn't exist yet: adding makes it.
        let directory = root.appending(path: "Support/Backgrounds", directoryHint: .isDirectory)
        let library = BackgroundLibrary(directory: directory)

        let entry = try library.add(copying: source)
        #expect(entry.url == directory.appending(path: "\(entry.id.uuidString).png"))
        #expect(try Data(contentsOf: entry.url) == original)
        #expect(try Data(contentsOf: source) == original)
        #expect(library.url(for: entry.id) == entry.url)

        let second = try library.add(copying: source)
        #expect(second.id != entry.id)
        #expect(Set(library.entries()) == [entry, second])

        // Without an extension, the picture's type gives one.
        let bare = root.appending(path: "Scan")
        try FileManager.default.copyItem(at: source, to: bare)
        let third = try library.add(copying: bare)
        #expect(third.url.lastPathComponent == "\(third.id.uuidString).png")
        #expect(library.url(for: third.id) == third.url)
    }

    @Test func aLinkedPictureIsCopiedAsAFile() throws {
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "picture.png")
        try Self.writePNG(TestBitmaps.solid(4, 4, TestBitmaps.blue), to: source)
        try Self.setCreated(source, year: 2019)
        let link = root.appending(path: "link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let library = BackgroundLibrary(directory: root.appending(path: "Backgrounds", directoryHint: .isDirectory))

        let start = Date()
        let entry = try library.add(copying: link)
        let attributes = try FileManager.default.attributesOfItem(atPath: entry.url.path(percentEncoded: false))
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: entry.url) == Data(contentsOf: source))
        #expect(library.entries() == [entry])
        // Dated when it was added, as any other copy.
        let stamped = try #require(attributes[.creationDate] as? Date)
        #expect(stamped >= start)
    }

    @Test func aFileThatIsNotAnImageIsRefused() throws {
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appending(path: "notes.png")
        try Data("not a picture".utf8).write(to: text)
        // A PNG header with nothing after it.
        let truncated = root.appending(path: "truncated.png")
        try ImageEncoder.encode(TestBitmaps.solid(20, 10, TestBitmaps.red), as: .png, quality: 1).prefix(60).write(to: truncated)
        let directory = root.appending(path: "Backgrounds", directoryHint: .isDirectory)
        let library = BackgroundLibrary(directory: directory)

        for url in [text, truncated, root.appending(path: "missing.png"), root] {
            #expect(throws: BackgroundLibraryError.notAnImage) { try library.add(copying: url) }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        #expect(library.entries().isEmpty)
    }

    /// Sets the creation date of the file at `url` to 1 January of `year`.
    static func setCreated(_ url: URL, year: Int) throws {
        let date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 1, day: 1)))
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path(percentEncoded: false))
    }

    /// The creation date of the file at `url`, read afresh.
    static func created(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.creationDate] as? Date
    }

    /// The order is by creation date, then id. A picture's creation date is when it was added, so the library lists them in
    /// the order they were added; a file whose date changed since (restored from a backup, say) takes its place by it.
    @Test func entriesAreOldestFirst() throws {
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "picture.png")
        try Self.writePNG(TestBitmaps.solid(4, 4, TestBitmaps.blue), to: source)
        let library = BackgroundLibrary(directory: root.appending(path: "Backgrounds", directoryHint: .isDirectory))
        let added = try (0..<4).map { _ in try library.add(copying: source) }
        #expect(library.entries() == added)

        try Self.setCreated(added[0].url, year: 2022)
        try Self.setCreated(added[1].url, year: 2019)
        try Self.setCreated(added[2].url, year: 2020)
        try Self.setCreated(added[3].url, year: 2020)

        // Equal dates go by id.
        let sameDay = [added[2], added[3]].sorted { $0.id.uuidString < $1.id.uuidString }
        #expect(library.entries() == [added[1]] + sameDay + [added[0]])
    }

    /// A copy would keep the file's own creation date: a picture taken years ago, added today, would go first.
    @Test func anOldPictureAddedLaterIsListedLast() throws {
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let recent = root.appending(path: "recent.png")
        try Self.writePNG(TestBitmaps.solid(4, 4, TestBitmaps.blue), to: recent)
        let old = root.appending(path: "old.png")
        try Self.writePNG(TestBitmaps.solid(4, 4, TestBitmaps.red), to: old)
        try Self.setCreated(old, year: 2019)
        let library = BackgroundLibrary(directory: root.appending(path: "Backgrounds", directoryHint: .isDirectory))

        let start = Date()
        let first = try library.add(copying: recent)
        let second = try library.add(copying: old)
        #expect(library.entries() == [first, second])
        let stamped = try #require(try Self.created(second.url))
        #expect(stamped >= start)
        // The source keeps its own date.
        let original = try #require(try Self.created(old))
        #expect(original < start.addingTimeInterval(-365 * 24 * 3600))
    }

    @Test func twoAddsOfTheSameSourceKeepTheirOrder() throws {
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "picture.png")
        try Self.writePNG(TestBitmaps.solid(4, 4, TestBitmaps.blue), to: source)
        let library = BackgroundLibrary(directory: root.appending(path: "Backgrounds", directoryHint: .isDirectory))

        let added = try (0..<12).map { _ in try library.add(copying: source) }
        #expect(library.entries() == added)
    }

    /// Two adds can fall in one tick of the clock, or the clock can be set back between them: each add is still listed after
    /// every picture already in the library.
    @Test func anAddIsListedAfterEveryPictureAlreadyThere() throws {
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "picture.png")
        try Self.writePNG(TestBitmaps.solid(4, 4, TestBitmaps.blue), to: source)
        let library = BackgroundLibrary(directory: root.appending(path: "Backgrounds", directoryHint: .isDirectory))

        let first = try library.add(copying: source)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(3600)],
                                              ofItemAtPath: first.url.path(percentEncoded: false))
        let second = try library.add(copying: source)
        #expect(library.entries() == [first, second])
    }

    @Test func removeDeletesTheFile() throws {
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "picture.jpg")
        try ImageEncoder.encode(TestBitmaps.solid(4, 4, TestBitmaps.blue), as: .jpeg, quality: 0.9).write(to: source)
        let library = BackgroundLibrary(directory: root.appending(path: "Backgrounds", directoryHint: .isDirectory))
        let kept = try library.add(copying: source)
        let removed = try library.add(copying: source)

        try library.remove(removed.id)
        #expect(!FileManager.default.fileExists(atPath: removed.url.path(percentEncoded: false)))
        #expect(library.url(for: removed.id) == nil)
        #expect(library.entries() == [kept])
        // Already gone: no error.
        try library.remove(removed.id)
        try library.remove(UUID())
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    @Test func anUnknownIDHasNoURL() throws {
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "picture.png")
        try Self.writePNG(TestBitmaps.solid(4, 4, TestBitmaps.blue), to: source)
        let library = BackgroundLibrary(directory: root.appending(path: "Backgrounds", directoryHint: .isDirectory))
        _ = try library.add(copying: source)
        #expect(library.url(for: UUID()) == nil)

        let missing = BackgroundLibrary(directory: root.appending(path: "Nowhere", directoryHint: .isDirectory))
        #expect(missing.url(for: UUID()) == nil)
        #expect(missing.entries().isEmpty)
    }

    @Test func filesNotNamedByAnIDAreIgnored() throws {
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "picture.png")
        try Self.writePNG(TestBitmaps.solid(4, 4, TestBitmaps.blue), to: source)
        let directory = root.appending(path: "Backgrounds", directoryHint: .isDirectory)
        let library = BackgroundLibrary(directory: directory)
        let entry = try library.add(copying: source)

        let strays = [UUID(), UUID(), UUID(), UUID()]
        for name in ["picture.png", strays[0].uuidString, ".\(strays[1].uuidString).png", "\(strays[2].uuidString).old.png"] {
            try FileManager.default.copyItem(at: source, to: directory.appending(path: name))
        }
        try FileManager.default.createDirectory(at: directory.appending(path: "\(strays[3].uuidString).png"),
                                                withIntermediateDirectories: false)

        #expect(library.entries() == [entry])
        for id in strays {
            #expect(library.url(for: id) == nil)
        }
    }

    // MARK: System wallpapers

    /// a.heic, b.jpg, c.png, g.JPEG, d.txt, e.madesktop, .hidden.png, a folder f holding x.png, and a folder named
    /// folder.heic.
    static func wallpaperFolder() throws -> URL {
        let folder = try temporaryFolder()
        for name in ["a.heic", "b.jpg", "c.png", "g.JPEG", "d.txt", "e.madesktop", ".hidden.png"] {
            try Data([1]).write(to: folder.appending(path: name))
        }
        try FileManager.default.createDirectory(at: folder.appending(path: "f"), withIntermediateDirectories: false)
        try Data([1]).write(to: folder.appending(path: "f/x.png"))
        try FileManager.default.createDirectory(at: folder.appending(path: "folder.heic"), withIntermediateDirectories: false)
        return folder
    }

    @Test func onlyPictureFilesAreListed() throws {
        let folder = try Self.wallpaperFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(SystemWallpapers.fileNames(in: folder) == ["a.heic", "b.jpg", "c.png", "g.JPEG"])
    }

    @Test func wallpapersAreSortedAsFinderSortsThem() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Wave 10.heic", "wave 2.heic", "Aurora.png"] {
            try Data([1]).write(to: folder.appending(path: name))
        }
        #expect(SystemWallpapers.fileNames(in: folder) == ["Aurora.png", "wave 2.heic", "Wave 10.heic"])
    }

    @Test func aNameWithASlashHasNoURL() throws {
        let folder = try Self.wallpaperFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(SystemWallpapers.url(for: "f/x.png", in: folder) == nil)
        #expect(SystemWallpapers.url(for: "/b.jpg", in: folder) == nil)
        #expect(SystemWallpapers.url(for: "../\(folder.lastPathComponent)/b.jpg", in: folder) == nil)
        #expect(SystemWallpapers.url(for: "b.jpg", in: folder) == folder.appending(path: "b.jpg"))
    }

    @Test func onlyListedNamesHaveURLs() throws {
        let folder = try Self.wallpaperFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in SystemWallpapers.fileNames(in: folder) {
            #expect(SystemWallpapers.url(for: name, in: folder) == folder.appending(path: name))
        }
        for name in ["", ".", "..", "b.jpg\0", "d.txt", "e.madesktop", ".hidden.png", "f", "folder.heic", "missing.png"] {
            #expect(SystemWallpapers.url(for: name, in: folder) == nil)
        }
    }

    @Test func aMissingDirectoryListsNothing() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appending(path: "Desktop Pictures", directoryHint: .isDirectory)
        #expect(SystemWallpapers.fileNames(in: missing).isEmpty)
        #expect(SystemWallpapers.url(for: "a.heic", in: missing) == nil)
    }

    // MARK: Thumbnails

    @Test func thumbnailsAreAtMost160Pixels() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "wide.png")
        try Self.writePNG(TestBitmaps.solid(1000, 500, TestBitmaps.red), to: url)
        #expect(Self.size(PictureThumbnail.make(at: url)) == CGSize(width: 160, height: 80))
        #expect(Self.size(PictureThumbnail.make(at: url, maxPixel: 40)) == CGSize(width: 40, height: 20))

        let text = folder.appending(path: "notes.png")
        try Data("not a picture".utf8).write(to: text)
        #expect(PictureThumbnail.make(at: text) == nil)
        #expect(PictureThumbnail.make(at: folder.appending(path: "missing.png")) == nil)
    }
}
