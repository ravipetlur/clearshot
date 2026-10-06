import CoreGraphics
import CSCore
import Foundation
import Testing
@testable import CSCapture

final class MetadataTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "meta-\(UUID().uuidString)", directoryHint: .isDirectory)
    /// Logs only to the unified log: no test writes the user's live log file.
    let logger = AppLogger(category: "metadata-tests", sink: nil)

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A file with some bytes and no attributes yet.
    func file() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "shot-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        return url
    }

    @Test func marksTheFileAsAScreenCapture() throws {
        let url = try file()
        #expect(!ScreenCaptureMetadata.isScreenCapture(url))
        let tag = ScreenCaptureTag(kind: .window, globalRect: CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(ScreenCaptureMetadata.apply(tag, to: url, logger: logger))
        #expect(ScreenCaptureMetadata.isScreenCapture(url))
        #expect(ScreenCaptureMetadata.captureType(url) == "window")
    }

    @Test func theRectReadsBackAsWritten() throws {
        let url = try file()
        #expect(ScreenCaptureMetadata.globalRect(url) == nil)
        let tag = ScreenCaptureTag(kind: .selection, globalRect: CGRect(x: 1, y: 2, width: 3, height: 4))
        ScreenCaptureMetadata.apply(tag, to: url, logger: logger)
        #expect(ScreenCaptureMetadata.globalRect(url) == CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    /// Nothing throws: the write says it failed, and logs why. The log goes to a file in this test's own temporary
    /// folder, so the line can be checked without touching the user's live log.
    @Test func aFailedWriteReturnsFalse() throws {
        let missing = folder.appending(path: "gone/missing.png")
        let logs = folder.appending(path: "Logs", directoryHint: .isDirectory)
        let sink = FileLogSink(directory: logs)
        let tag = ScreenCaptureTag(kind: .display, globalRect: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(!ScreenCaptureMetadata.apply(tag, to: missing, logger: AppLogger(category: "capture", sink: sink)))
        #expect(!ScreenCaptureMetadata.isScreenCapture(missing))
        let logged = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(logged.contains("[ERROR] [capture] Couldn't mark missing.png as a screenshot: No such file or directory"))
        // Once, not once per attribute.
        #expect(logged.components(separatedBy: "Couldn't mark").count == 2)
    }
}
