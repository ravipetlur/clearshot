import CoreGraphics
import CSCapture
import Foundation
import Testing
@testable import CSHistory

/// Which items' files are marked as screenshots: only screenshots ClearShot captured, and every file handed out for
/// them, the temporary copies that drags, copies, Mail and Open With of an unsaved capture use included.
@MainActor
final class HistoryMetadataTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "history-meta-\(UUID().uuidString)",
                                                                directoryHint: .isDirectory)
    let temporary = FileManager.default.temporaryDirectory.appending(path: "history-meta-tmp-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
    let rect = CGRect(x: -1440, y: 120, width: 500, height: 250)

    deinit {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: temporary)
    }

    func item(_ kind: MediaKind = .screenshot, origin: HistoryOrigin = .capture,
              captureKind: CaptureKind = .window) -> HistoryItem {
        HistoryItem(id: UUID(), kind: kind, origin: origin, captureKind: captureKind, createdAt: Date(),
                    mediaFileName: "Shot.png", displayName: "Shot", savedPath: nil, pixelWidth: 1000, pixelHeight: 500,
                    scale: 2, appName: nil, isTransparent: false, globalRect: rect)
    }

    func details(origin: HistoryOrigin) -> HistoryWriter.Details {
        HistoryWriter.Details(origin: origin, captureKind: .selection, displayName: "Shot", savedURL: nil, scale: 2,
                              appName: nil, isTransparent: false, globalRect: origin == .capture ? rect : .zero,
                              createdAt: Date())
    }

    @Test func onlyCapturedScreenshotsAreTagged() {
        #expect(item(captureKind: .window).screenCaptureTag == ScreenCaptureTag(kind: .window, globalRect: rect))
        #expect(item(captureKind: .display).screenCaptureTag == ScreenCaptureTag(kind: .display, globalRect: rect))
        // Opened and pasted images are files like any other.
        #expect(item(origin: .file).screenCaptureTag == nil)
        #expect(item(origin: .clipboard).screenCaptureTag == nil)
        // A recording is a capture, but not a screenshot.
        #expect(item(.video).screenCaptureTag == nil)
        #expect(item(.gif).screenCaptureTag == nil)
    }

    @Test func aTemporaryCopyOfACaptureIsTagged() throws {
        let capture = try HistoryWriter.create(image(width: 40, height: 20), details: details(origin: .capture), root: root)
        let copy = try HistoryWriter.temporaryCopy(of: capture, root: root, in: temporary)
        #expect(ScreenCaptureMetadata.isScreenCapture(copy))
        #expect(ScreenCaptureMetadata.captureType(copy) == "selection")
        #expect(ScreenCaptureMetadata.globalRect(copy) == rect)
        // The working copy itself stays as it was written.
        #expect(!ScreenCaptureMetadata.isScreenCapture(capture.mediaURL(in: root)))
    }

    @Test func aTemporaryCopyOfAnImportIsUntagged() throws {
        for origin in [HistoryOrigin.file, .clipboard] {
            let imported = try HistoryWriter.create(image(width: 40, height: 20), details: details(origin: origin), root: root)
            let copy = try HistoryWriter.temporaryCopy(of: imported, root: root, in: temporary)
            #expect(!ScreenCaptureMetadata.isScreenCapture(copy), "\(origin)")
            #expect(ScreenCaptureMetadata.globalRect(copy) == nil, "\(origin)")
        }
    }
}
