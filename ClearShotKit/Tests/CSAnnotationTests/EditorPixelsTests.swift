import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// The editor's picture pixels: built when first asked for, off the main actor, and rebuilt when the picture changes.
@MainActor
struct EditorPixelsTests {
    private func arrow() -> AnnotationObject {
        AnnotationObject(kind: .arrow(ArrowShape(start: CGPoint(x: 30, y: 30), end: CGPoint(x: 60, y: 50), style: .standard)),
                         style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 4, shadow: false))
    }

    /// Waits up to two seconds for the editor's pixels to be ready.
    private func ready(_ editor: AnnotationEditor) async throws -> PicturePixels? {
        for _ in 0..<400 where editor.picturePixels == nil { try await Task.sleep(for: .milliseconds(5)) }
        return editor.picturePixels
    }

    @Test func nothingIsBuiltUntilAsked() async throws {
        let h = EditorHarness()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.editor.picturePixels == nil)
        #expect(h.editor.picturePixelsBuild == nil)
    }

    @Test func currentPixelsAreBuiltAndThenReady() async throws {
        let h = EditorHarness()
        let pixels = try #require(await h.editor.currentPicturePixels())
        #expect(pixels.sampler.size == CGSize(width: 100, height: 80))
        #expect(pixels.color(at: CGPoint(x: 10, y: 10)) == .white)
        let ready = try #require(try await ready(h.editor))
        #expect(ready.identity == h.editor.document.picturePixelsIdentity)
    }

    @Test func loadingBuildsInTheBackground() async throws {
        let h = EditorHarness()
        h.editor.loadPicturePixels()
        let pixels = try #require(try await ready(h.editor))
        #expect(pixels.sampler.size == CGSize(width: 100, height: 80))
    }

    /// Pixels of an earlier picture are never offered: after a turn they are gone at once, and the turned picture's arrive.
    @Test func aPictureChangeRebuilds() async throws {
        let h = EditorHarness()
        _ = await h.editor.currentPicturePixels()
        h.act { h.editor.changeCanvas("Rotate") { $0 = $0.applying(.rotateRight) } }
        #expect(h.editor.picturePixels == nil)
        let pixels = try #require(try await ready(h.editor))
        #expect(pixels.sampler.size == CGSize(width: 80, height: 100))
        #expect(pixels.identity == h.editor.document.picturePixelsIdentity)
    }

    @Test func askingDuringTheWaitBuildsAtOnce() async throws {
        let h = EditorHarness()
        _ = await h.editor.currentPicturePixels()
        h.act { h.editor.changeCanvas("Crop") { $0.canvasRect = CGRect(x: 0, y: 0, width: 50, height: 40) } }
        let pixels = try #require(await h.editor.currentPicturePixels())
        #expect(pixels.sampler.size == CGSize(width: 50, height: 40))
    }

    @Test func anAnnotationKeepsThePixels() async throws {
        let h = EditorHarness()
        let before = try #require(await h.editor.currentPicturePixels())
        _ = try await ready(h.editor)
        h.act { h.editor.add(arrow(), actionName: "Add Arrow") }
        let after = try #require(h.editor.picturePixels)
        #expect(after.identity == before.identity)
        // Nothing is rebuilding.
        try await Task.sleep(for: AnnotationEditor.picturePixelsRebuildDelay + .milliseconds(100))
        #expect(h.editor.picturePixelsRebuild == nil)
        #expect(h.editor.picturePixels != nil)
    }

    /// An undo makes the earlier picture again, and its pixels are built for it.
    @Test func undoMakesTheEarlierPictureAgain() async throws {
        let h = EditorHarness()
        _ = await h.editor.currentPicturePixels()
        h.act { h.editor.changeCanvas("Rotate") { $0 = $0.applying(.rotateLeft) } }
        _ = try #require(try await ready(h.editor))
        h.editor.undoManager.undo()
        let pixels = try #require(try await ready(h.editor))
        #expect(pixels.sampler.size == CGSize(width: 100, height: 80))
    }
}
