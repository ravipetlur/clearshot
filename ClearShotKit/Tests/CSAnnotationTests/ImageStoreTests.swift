import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CSAnnotation

struct ImageRefSafetyTests {
    let folder = URL(filePath: "/tmp/clearshot-doc", directoryHint: .isDirectory)

    @Test func ordinaryNamesResolveInsideTheFolder() throws {
        let original = try #require(ImageRef(name: "original.png").url(in: folder))
        #expect(original.standardizedFileURL.path == "/tmp/clearshot-doc/original.png")
        let nested = try #require(ImageRef(name: "images/abc.png").url(in: folder))
        #expect(nested.standardizedFileURL.path == "/tmp/clearshot-doc/images/abc.png")
        // The history documents' base: a dot file, which no working copy's name can be.
        let hidden = try #require(AnnotationStorage.historyBase.url(in: folder))
        #expect(hidden.standardizedFileURL.path == "/tmp/clearshot-doc/.original.png")
    }

    @Test(arguments: ["../x.png", "images/../../x.png", "/etc/hosts", "", "~/x.png", "..", ".", "images/./a.png", "images//a.png",
                      "images/", "a\u{0}.png"])
    func unsafeNamesAreRefused(name: String) {
        #expect(ImageRef(name: name).url(in: folder) == nil)
    }

    @Test func parentComponentsAreRefusedEvenWhenTheyStayInside() {
        // The writer never produces a "..", so a document with one is not one of ours.
        #expect(ImageRef(name: "images/../original.png").url(in: folder) == nil)
    }

    @Test func symlinksInsideTheFolderAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "clearshot-links-\(UUID().uuidString)", directoryHint: .isDirectory)
        let package = root.appending(path: "package", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: outside.appending(path: "secret.png"))
        // A folder that points out of the package, a file that does, and a link that dangles.
        try FileManager.default.createSymbolicLink(at: package.appending(path: "images"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: package.appending(path: "leaf.png"), withDestinationURL: outside.appending(path: "secret.png"))
        try FileManager.default.createSymbolicLink(at: package.appending(path: "dangling.png"), withDestinationURL: outside.appending(path: "new.png"))
        try Data([1]).write(to: package.appending(path: "original.png"))
        #expect(ImageRef(name: "images/secret.png").url(in: package) == nil) // exists, through the folder link
        #expect(ImageRef(name: "images/new.png").url(in: package) == nil) // doesn't exist yet, as when writing
        #expect(ImageRef(name: "leaf.png").url(in: package) == nil)
        #expect(ImageRef(name: "dangling.png").url(in: package) == nil)
        #expect(ImageRef(name: "original.png").url(in: package) != nil)
        #expect(ImageRef(name: "images2/new.png").url(in: package) != nil) // a path that doesn't exist yet is fine
    }
}

struct ImageStoreLoadTests {
    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func loadingSkipsImagesOutsideTheFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "clearshot-load-\(UUID().uuidString)", directoryHint: .isDirectory)
        let package = root.appending(path: "package", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package.appending(path: "images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = TestBitmaps.solid(4, 4, TestBitmaps.blue)
        try writePNG(picture, to: package.appending(path: "original.png"))
        try writePNG(picture, to: package.appending(path: "images/inside.png"))
        try writePNG(picture, to: root.appending(path: "outside.png"))

        var document = AnnotationDocument(baseSize: CGSize(width: 4, height: 4), pixelScale: 1)
        let style = ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 4, shadow: false)
        for name in ["images/inside.png", "../outside.png", "images/../../outside.png", "images/missing.png"] {
            document.objects.append(AnnotationObject(kind: .image(ImageObject(rect: CGRect(x: 0, y: 0, width: 4, height: 4),
                                                                              image: ImageRef(name: name))), style: style))
        }
        let store = ImageStore.load(for: document, from: package)
        #expect(store[ImageRef.original] != nil)
        #expect(store[ImageRef(name: "images/inside.png")] != nil)
        #expect(store[ImageRef(name: "images/missing.png")] == nil)
        // The file really is there one level up; it must not be read.
        #expect(store[ImageRef(name: "../outside.png")] == nil)
        #expect(store[ImageRef(name: "images/../../outside.png")] == nil)
        #expect(store.images.keys.sorted() == ["images/inside.png", "original.png"])
    }
}
