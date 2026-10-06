import AppKit
import CSCore
import Testing
@testable import CSCapture

@MainActor
struct ClipboardWriterTests {
    let png: Data
    let file = URL(filePath: "/tmp/shot.jpg")

    init() throws {
        png = try ImageEncoder.encode(TestImages.solid(width: 4, height: 4, color: TestImages.red), as: .png, quality: 1)
    }

    func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("test.clearshot.pasteboard.\(UUID().uuidString)"))
    }

    @Test func fileAndImageWritesBoth() {
        let board = pasteboard()
        #expect(ClipboardWriter.write(pngData: png, fileURL: file, mode: .fileAndImage, to: board))
        let types = board.types ?? []
        #expect(board.data(forType: .png) == png)
        #expect(types.contains(.fileURL))
        #expect(board.pasteboardItems?.count == 1)
        board.releaseGlobally()
    }

    @Test func imageOnlyLeavesTheFileOut() {
        let board = pasteboard()
        #expect(ClipboardWriter.write(pngData: png, fileURL: file, mode: .imageOnly, to: board))
        let types = board.types ?? []
        #expect(types.contains(.png))
        #expect(!types.contains(.fileURL))
        #expect(board.pasteboardItems?.count == 1)
        board.releaseGlobally()
    }

    @Test func fileOnlyLeavesTheImageOut() {
        let board = pasteboard()
        #expect(ClipboardWriter.write(pngData: png, fileURL: file, mode: .fileOnly, to: board))
        let types = board.types ?? []
        #expect(types.contains(.fileURL))
        #expect(!types.contains(.png))
        #expect(board.pasteboardItems?.count == 1)
        board.releaseGlobally()
    }

    @Test func fileOnlyWithoutAFileFallsBackToTheImage() {
        let board = pasteboard()
        #expect(ClipboardWriter.write(pngData: png, fileURL: nil, mode: .fileOnly, to: board))
        let types = board.types ?? []
        #expect(types.contains(.png))
        #expect(!types.contains(.fileURL))
        #expect(board.pasteboardItems?.count == 1)
        board.releaseGlobally()
    }

    /// The caller encodes the PNG off the main actor, and only when the pasteboard item will carry it.
    @Test func onlyFileOnlyWithAFileSkipsTheImage() {
        #expect(!ClipboardWriter.includesImage(mode: .fileOnly, fileURL: file))
        #expect(ClipboardWriter.includesImage(mode: .fileOnly, fileURL: nil))
        #expect(ClipboardWriter.includesImage(mode: .imageOnly, fileURL: file))
        #expect(ClipboardWriter.includesImage(mode: .fileAndImage, fileURL: file))
        #expect(ClipboardWriter.includesImage(mode: .fileAndImage, fileURL: nil))
    }

    /// History's ⌘C with several items: file URLs only, one item each, in order.
    @Test func severalFilesAreWrittenAsOneItemEach() {
        let board = pasteboard()
        let files = ["/tmp/a.png", "/tmp/b.jpg", "/tmp/c.mp4"].map { URL(filePath: $0) }
        #expect(ClipboardWriter.write(fileURLs: files, to: board))
        let items = board.pasteboardItems ?? []
        #expect(items.count == 3)
        #expect(items.map { $0.string(forType: .fileURL) } == files.map(\.absoluteString))
        #expect(items.allSatisfy { $0.types.contains(.fileURL) && !$0.types.contains(.png) })
        #expect(!(board.types ?? []).contains(.png))
        board.releaseGlobally()
    }

    @Test func noFilesWritesNothing() {
        let board = pasteboard()
        board.clearContents()
        board.setString("before", forType: .string)
        #expect(!ClipboardWriter.write(fileURLs: [], to: board))
        #expect(board.string(forType: .string) == "before")
        board.releaseGlobally()
    }

    /// A video goes on the pasteboard as its file URL alone, one item, replacing what was there. The function takes no
    /// clipboard mode: there is no image to put beside the file.
    @Test func aMediaFileIsCopiedAsItsURL() {
        let board = pasteboard()
        board.clearContents()
        board.setString("before", forType: .string)
        let video = URL(filePath: "/tmp/ClearShot 2026-10-05 at 10.00.00.mp4")
        #expect(ClipboardWriter.write(mediaFileURL: video, gifData: nil, to: board))
        let items = board.pasteboardItems ?? []
        #expect(items.count == 1)
        #expect(items.first?.string(forType: .fileURL) == video.absoluteString)
        let types = board.types ?? []
        #expect(!types.contains(.png))
        #expect(!types.contains(.string))
        #expect(!types.contains(NSPasteboard.PasteboardType("com.compuserve.gif")))
        board.releaseGlobally()
    }

    /// A GIF also carries its data, so apps that paste images rather than files get the animation.
    @Test func aGIFAlsoCarriesGIFData() {
        let board = pasteboard()
        let gif = URL(filePath: "/tmp/ClearShot 2026-10-05 at 10.00.00.gif")
        let data = Data("GIF89a and the frames".utf8)
        #expect(ClipboardWriter.write(mediaFileURL: gif, gifData: data, to: board))
        let items = board.pasteboardItems ?? []
        #expect(items.count == 1)
        #expect(items.first?.string(forType: .fileURL) == gif.absoluteString)
        #expect(items.first?.data(forType: NSPasteboard.PasteboardType("com.compuserve.gif")) == data)
        board.releaseGlobally()
    }

    /// Nothing to write (no PNG, and no file the mode allows) leaves whatever was on the pasteboard.
    @Test(arguments: [(nil, ClipboardMode.fileAndImage), (URL(filePath: "/tmp/shot.jpg"), .imageOnly)])
    func nothingToWriteLeavesThePasteboardAlone(fileURL: URL?, mode: ClipboardMode) {
        let board = pasteboard()
        board.clearContents()
        board.setString("before", forType: .string)
        #expect(!ClipboardWriter.write(pngData: nil, fileURL: fileURL, mode: mode, to: board))
        #expect(board.string(forType: .string) == "before")
        board.releaseGlobally()
    }
}
