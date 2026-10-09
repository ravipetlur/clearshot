import CoreGraphics
import CSCore
import Foundation
import ImageIO
import Testing
@testable import CSCapture

struct ExporterTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)/nested/screenshot", directoryHint: .isDirectory)
    static let date: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 5, second: 9))!
    }()
    /// A captured screenshot's tag, as the router passes it.
    static let tag = ScreenCaptureTag(kind: .selection, globalRect: CGRect(x: 0, y: 0, width: 10, height: 5))

    /// Untagged unless a test passes a tag.
    func request(format: ImageFormat = .jpeg, retinaSuffix: Bool = false, directory: URL? = nil,
                 screenCapture: ScreenCaptureTag? = nil) -> ExportRequest {
        ExportRequest(image: TestImages.solid(width: 20, height: 10, color: TestImages.red), format: format, quality: 0.9,
                      pixelsPerPoint: 2, directory: directory ?? self.directory, template: .standard,
                      nameContext: FileNameContext(date: Self.date, timeZone: TimeZone(identifier: "Asia/Kolkata")!),
                      retinaSuffix: retinaSuffix, screenCapture: screenCapture)
    }

    @Test func savesWithTheTemplateNameIntoANewFolder() throws {
        let url = try Exporter.save(request(screenCapture: Self.tag))
        #expect(url.lastPathComponent == "Screenshot 2026-10-02 at 14.05.09.jpg")
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(ScreenCaptureMetadata.isScreenCapture(url))
    }

    @Test func addsTheRetinaSuffixAndNumbersCollisions() throws {
        let first = try Exporter.save(request(format: .png, retinaSuffix: true))
        let second = try Exporter.save(request(format: .png, retinaSuffix: true))
        #expect(first.lastPathComponent == "Screenshot 2026-10-02 at 14.05.09@2x.png")
        #expect(second.lastPathComponent == "Screenshot 2026-10-02 at 14.05.09@2x (2).png")
    }

    @Test func aFolderThatCantBeCreatedThrowsAClearError() {
        #expect(throws: CaptureError.cannotCreateFolder("/System/ClearShotNoAccess")) {
            try Exporter.save(request(directory: URL(filePath: "/System/ClearShotNoAccess", directoryHint: .isDirectory)))
        }
    }

    @Test func aFolderThatCantBeWrittenThrowsCannotSave() throws {
        let readOnly = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path(percentEncoded: false)) }

        // The file Exporter picks: the template's name plus the format's extension, inside the folder.
        let expected = readOnly.appending(path: "Screenshot 2026-10-02 at 14.05.09").appendingPathExtension("jpg")
        #expect(throws: CaptureError.cannotSave(expected.path(percentEncoded: false))) {
            try Exporter.save(request(directory: readOnly))
        }
    }

    @Test func encoderFailureIsNotReportedAsALocationProblem() {
        // The WebP encoder rejects images wider than 16383 pixels (what macOS can decode).
        let tooWide = TestImages.solid(width: 16384, height: 1, color: TestImages.red)
        var request = request(format: .webp)
        request.image = tooWide
        #expect(throws: CaptureError.cannotEncode("WebP")) {
            try Exporter.save(request)
        }
    }

    @Test func nameOverrideReplacesTheTemplate() throws {
        var named = request(format: .png)
        named.nameOverride = "Bug report"
        #expect(try Exporter.save(named).lastPathComponent == "Bug report.png")
    }

    @Test func baseNameIncludesTheRetinaSuffix() {
        #expect(request(retinaSuffix: true).baseName == "Screenshot 2026-10-02 at 14.05.09@2x")
        #expect(request().baseName == "Screenshot 2026-10-02 at 14.05.09")
    }

    @Test func theBaseNameInitializerSavesUnderThatName() throws {
        let named = ExportRequest(image: TestImages.solid(width: 4, height: 4, color: TestImages.red), format: .jpeg, quality: 0.9,
                                  pixelsPerPoint: 1, directory: directory, baseName: "Named", screenCapture: nil)
        #expect(try Exporter.save(named).lastPathComponent == "Named.jpg")
    }

    @Test func writeReplacesTheFileAtAnExactURL() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "exact.png")
        try Exporter.write(TestImages.solid(width: 4, height: 4, color: TestImages.red), as: .png, quality: 1, pixelsPerPoint: 1,
                           to: url, screenCapture: Self.tag)
        try Exporter.write(TestImages.solid(width: 8, height: 2, color: TestImages.blue), as: .png, quality: 1, pixelsPerPoint: 1,
                           to: url, screenCapture: Self.tag)
        let image = try #require(ImageOps.load(url))
        #expect(image.width == 8)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) == ["exact.png"])
        #expect(ScreenCaptureMetadata.isScreenCapture(url))
    }

    /// An opened or pasted image, saved: a file like any other, not a screenshot. Rewritten untagged (a rotate), a file
    /// an older build tagged loses the tag.
    @Test func writeWithoutATagLeavesNoMetadata() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "untagged.png")
        try Exporter.write(TestImages.solid(width: 4, height: 4, color: TestImages.red), as: .png, quality: 1, pixelsPerPoint: 1,
                           to: url, screenCapture: Self.tag)
        try Exporter.write(TestImages.solid(width: 4, height: 4, color: TestImages.red), as: .png, quality: 1, pixelsPerPoint: 1,
                           to: url, screenCapture: nil)
        let saved = try Exporter.save(request(format: .png, screenCapture: nil))
        for file in [url, saved] {
            #expect(!ScreenCaptureMetadata.isScreenCapture(file))
            #expect(ScreenCaptureMetadata.captureType(file) == nil)
            #expect(ScreenCaptureMetadata.globalRect(file) == nil)
        }
    }

    @Test func saveTagsWithTheRequestsTag() throws {
        let tag = ScreenCaptureTag(kind: .display, globalRect: CGRect(x: -1440, y: 120, width: 1440, height: 900))
        let url = try Exporter.save(request(format: .png, screenCapture: tag))
        #expect(ScreenCaptureMetadata.isScreenCapture(url))
        #expect(ScreenCaptureMetadata.captureType(url) == "display")
        #expect(ScreenCaptureMetadata.globalRect(url) == CGRect(x: -1440, y: 120, width: 1440, height: 900))
    }

    // MARK: Media files

    /// A recording's working copy, beside the export folder: a file whose bytes a copy must keep exactly.
    private func mediaFile(named name: String = "recording.mp4") throws -> URL {
        let folder = directory.deletingLastPathComponent().appending(path: "history", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]).write(to: url)
        return url
    }

    @Test func aMediaFileIsSavedAsACopyKeepingItsExtension() throws {
        let source = try mediaFile()
        let url = try Exporter.saveCopy(of: source, in: directory, baseName: "Screenshot 2026-10-02 at 14.05.09")
        #expect(url.lastPathComponent == "Screenshot 2026-10-02 at 14.05.09.mp4")
        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(try Data(contentsOf: url) == Data(contentsOf: source))
        // The working copy stays where it was.
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    @Test func aMediaCopyNumbersCollisions() throws {
        let source = try mediaFile(named: "recording.gif")
        let first = try Exporter.saveCopy(of: source, in: directory, baseName: "Clip")
        let second = try Exporter.saveCopy(of: source, in: directory, baseName: "Clip")
        #expect(first.lastPathComponent == "Clip.gif")
        #expect(second.lastPathComponent == "Clip (2).gif")
    }

    @Test func aMediaCopyIntoAFolderThatCantBeCreatedThrowsAClearError() throws {
        let source = try mediaFile()
        #expect(throws: CaptureError.cannotCreateFolder("/System/ClearShotNoAccess")) {
            try Exporter.saveCopy(of: source, in: URL(filePath: "/System/ClearShotNoAccess", directoryHint: .isDirectory),
                                  baseName: "Clip")
        }
    }

    @Test func aMissingMediaFileThrowsCannotSave() throws {
        let missing = try mediaFile().deletingLastPathComponent().appending(path: "gone.mp4")
        let expected = directory.appending(path: "Clip").appendingPathExtension("mp4")
        #expect(throws: CaptureError.cannotSave(expected.path(percentEncoded: false))) {
            try Exporter.saveCopy(of: missing, in: directory, baseName: "Clip")
        }
    }

    @Test func writeCopyReplacesTheFileAtAnExactURL() throws {
        let source = try mediaFile()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "chosen.mp4")
        try Data("older".utf8).write(to: url)
        try Exporter.writeCopy(of: source, to: url)
        #expect(try Data(contentsOf: url) == Data(contentsOf: source))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) == ["chosen.mp4"])
    }

    /// Save As over a file: a copy that fails (here, its source is gone) leaves the file it would have replaced as it
    /// was, and leaves nothing beside it.
    @Test func aFailedWriteCopyKeepsTheFileItWouldReplace() throws {
        let missing = try mediaFile().deletingLastPathComponent().appending(path: "gone.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "chosen.mp4")
        try Data("older".utf8).write(to: url)
        #expect(throws: CaptureError.cannotSave(url.path(percentEncoded: false))) {
            try Exporter.writeCopy(of: missing, to: url)
        }
        #expect(try Data(contentsOf: url) == Data("older".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) == ["chosen.mp4"])
    }

    @Test func writeCopyMakesAFileThatDidntExist() throws {
        let source = try mediaFile()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "new.mp4")
        try Exporter.writeCopy(of: source, to: url)
        #expect(try Data(contentsOf: url) == Data(contentsOf: source))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) == ["new.mp4"])
    }

    /// The density of the file at `url`, as ImageIO reads it.
    private func dpi(of url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
    }

    @Test func aSavedFileRecordsItsPixelsPerPointAsItsDensity() throws {
        // `request` is a 2× image: 144 dpi, as macOS records its own Retina screenshots.
        #expect(dpi(of: try Exporter.save(request(format: .png))) == 144)
        #expect(dpi(of: try Exporter.save(request(format: .jpeg))) == 144)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "exact.heic")
        try Exporter.write(TestImages.solid(width: 4, height: 4, color: TestImages.red), as: .heic, quality: 1, pixelsPerPoint: 1,
                           to: url, screenCapture: nil)
        #expect(dpi(of: url) == 72)
    }
}
