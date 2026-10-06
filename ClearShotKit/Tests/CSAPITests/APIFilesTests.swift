import Foundation
import Testing
@testable import CSAPI

/// Files in a temporary folder of the test's own, which also stands in for the home folder.
final class APIFilesTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "clearshot-api-files-\(UUID().uuidString)", directoryHint: .isDirectory)
    /// `DocumentPackage.fileExtension`, which the app passes in.
    let project = "clearshot"

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        return url
    }

    @discardableResult
    func folder(_ name: String) throws -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func validate(_ path: String, as kind: APIFileKind) throws(APIError) -> URL {
        try APIFiles.validate(path, as: kind, projectExtension: project, home: root)
    }

    @Test func anExistingImageIsAccepted() throws {
        let png = try file("my screenshot.png")
        for kind in [APIFileKind.image, .imageOrMovie, .imageOrProject] {
            #expect(try validate(png.path, as: kind).path == png.path)
        }
        let upper = try file("SHOT.JPG")
        #expect(try validate(upper.path, as: .image).path == upper.path)
        try file("still.gif")
        #expect(throws: Never.self) { try self.validate(self.root.appending(path: "still.gif").path, as: .image) }
        // A link to an image is the image.
        let link = root.appending(path: "link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: png)
        #expect(throws: Never.self) { try self.validate(link.path, as: .image) }
    }

    @Test func aRelativePathIsAnError() {
        for path in ["a.png", "Desktop/a.png", "./a.png", "~john/a.png"] {
            #expect(throws: APIError.relativePath(path)) { try self.validate(path, as: .image) }
        }
    }

    @Test func aTildeExpandsAgainstHome() throws {
        let png = try file("a.png")
        #expect(try validate("~/a.png", as: .image).path == png.path)
        #expect(throws: APIError.notAFile(root.lastPathComponent)) { try self.validate("~", as: .image) }
    }

    @Test func aMissingFileIsAnError() throws {
        let missing = root.appending(path: "missing.png").path
        #expect(throws: APIError.fileNotFound("~/missing.png")) { try self.validate(missing, as: .image) }
        #expect(throws: APIError.fileNotFound("~/Shots/missing.png")) { try self.validate("~/Shots/missing.png", as: .image) }
        // Outside home the path is shown in full.
        #expect(throws: APIError.fileNotFound("/nonexistent-clearshot/a.png")) {
            try self.validate("/nonexistent-clearshot/a.png", as: .image)
        }
        // A link to nothing is no file.
        let link = root.appending(path: "dangling.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appending(path: "gone.png"))
        #expect(throws: APIError.fileNotFound("~/dangling.png")) { try self.validate(link.path, as: .image) }
    }

    @Test func aFolderIsNotAFile() throws {
        let pictures = try folder("Pictures")
        #expect(throws: APIError.notAFile("Pictures")) { try self.validate(pictures.path, as: .image) }
        let named = try folder("looks like.png")
        #expect(throws: APIError.notAFile("looks like.png")) { try self.validate(named.path, as: .imageOrMovie) }
        #expect(throws: APIError.notAFile("looks like.png")) { try self.validate(named.path, as: .imageOrProject) }
    }

    @Test func aMovieIsAcceptedOnlyForQuickAccess() throws {
        for name in ["clip.mp4", "clip.mov"] {
            let movie = try file(name)
            #expect(try validate(movie.path, as: .imageOrMovie).path == movie.path)
            #expect(throws: APIError.wrongFileType(name, expected: .image)) { try self.validate(movie.path, as: .image) }
            #expect(throws: APIError.wrongFileType(name, expected: .imageOrProject)) {
                try self.validate(movie.path, as: .imageOrProject)
            }
        }
    }

    @Test func aProjectPackageIsAcceptedOnlyForAnnotate() throws {
        let package = try folder("Mockup.clearshot")
        let validated = try validate(package.path, as: .imageOrProject)
        #expect(validated.path == package.path)
        #expect(validated.hasDirectoryPath)
        #expect(throws: APIError.notAFile("Mockup.clearshot")) { try self.validate(package.path, as: .image) }
        #expect(throws: APIError.notAFile("Mockup.clearshot")) { try self.validate(package.path, as: .imageOrMovie) }
        // A project is a package; a plain file with its extension is neither an image nor a project.
        let plain = try file("plain.clearshot")
        #expect(throws: APIError.wrongFileType("plain.clearshot", expected: .imageOrProject)) {
            try self.validate(plain.path, as: .imageOrProject)
        }
    }

    @Test func aTextFileIsNotAnImage() throws {
        let text = try file("notes.txt")
        #expect(throws: APIError.wrongFileType("notes.txt", expected: .image)) { try self.validate(text.path, as: .image) }
        #expect(throws: APIError.wrongFileType("notes.txt", expected: .imageOrMovie)) {
            try self.validate(text.path, as: .imageOrMovie)
        }
        let bare = try file("README")
        #expect(throws: APIError.wrongFileType("README", expected: .image)) { try self.validate(bare.path, as: .image) }
    }

    @Test func anUnreadableFileIsAnError() throws {
        let locked = try file("locked.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        #expect(throws: APIError.unreadable("locked.png")) { try self.validate(locked.path, as: .image) }
        #expect(throws: APIError.unreadable("locked.png")) { try self.read(locked) }
    }

    // MARK: Links, FIFOs, and the file as it is when it is read

    @discardableResult
    func link(_ name: String, to destination: URL) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    @discardableResult
    func fifo(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        #expect(mkfifo(url.path, 0o644) == 0)
        return url
    }

    func read(_ url: URL, limit: Int = APIFiles.readLimit) throws(APIError) -> Data {
        try APIFiles.read(url, limit: limit, home: root)
    }

    /// A link counts as the regular file it points to, never as a folder: a link named like a project can't open any
    /// folder in Annotate, and a link named like an image isn't one.
    @Test func aLinkToAFolderIsNotAFile() throws {
        let package = try folder("Mockup.clearshot")
        let linkedProject = try link("Linked.clearshot", to: package)
        #expect(throws: APIError.notAFile("Linked.clearshot")) {
            try self.validate(linkedProject.path, as: .imageOrProject)
        }
        // Also with a trailing slash, which would make `lstat` follow the link.
        #expect(throws: APIError.notAFile("Linked.clearshot")) {
            try self.validate(linkedProject.path + "/", as: .imageOrProject)
        }
        let anyFolder = try link("Documents.clearshot", to: try folder("Documents"))
        #expect(throws: APIError.notAFile("Documents.clearshot")) {
            try self.validate(anyFolder.path, as: .imageOrProject)
        }
        let namedLikeAnImage = try link("folder.png", to: package)
        for kind in [APIFileKind.image, .imageOrMovie, .imageOrProject] {
            #expect(throws: APIError.notAFile("folder.png")) { try self.validate(namedLikeAnImage.path, as: kind) }
        }
        // The package itself still opens, with or without a trailing slash.
        #expect(try validate(package.path + "/", as: .imageOrProject).path == package.path)
    }

    @Test func aFIFOIsNotAFile() throws {
        let pipe = try fifo("pipe.png")
        #expect(throws: APIError.notAFile("pipe.png")) { try self.validate(pipe.path, as: .image) }
        let linked = try link("linked pipe.png", to: pipe)
        #expect(throws: APIError.notAFile("linked pipe.png")) { try self.validate(linked.path, as: .imageOrMovie) }
    }

    @Test func readGivesTheFilesBytes() throws {
        let png = try file("a.png")
        #expect(try read(png) == Data([0x89, 0x50, 0x4E, 0x47]))
        // Through a link to it, too.
        let linked = try link("linked.png", to: png)
        #expect(try read(linked) == Data([0x89, 0x50, 0x4E, 0x47]))
        let empty = root.appending(path: "empty.png")
        try Data().write(to: empty)
        #expect(try read(empty) == Data())
    }

    /// The file is checked again as it is opened, on the descriptor that is read: whatever replaced it after `validate`
    /// is refused, and a FIFO is refused without waiting for a writer (the test would hang otherwise).
    @Test(.timeLimit(.minutes(1))) func readRefusesWhatReplacedTheCheckedFile() throws {
        let names = ["fifo.png", "folder.png", "linked fifo.png", "linked folder.png"]
        for name in names {
            try file(name)
            _ = try validate(root.appending(path: name).path, as: .image)
        }
        let target = try fifo("target")
        let folder = try folder("Pictures")
        for name in names {
            try FileManager.default.removeItem(at: root.appending(path: name))
        }
        try fifo("fifo.png")
        try self.folder("folder.png")
        try link("linked fifo.png", to: target)
        try link("linked folder.png", to: folder)
        for name in names {
            #expect(throws: APIError.notAFile(name)) { try self.read(self.root.appending(path: name)) }
        }
        #expect(throws: APIError.fileNotFound("~/gone.png")) { try self.read(self.root.appending(path: "gone.png")) }
    }

    /// The file is read into memory, so a bigger one than `limit` is refused rather than read.
    @Test func readRefusesAFileOverTheLimit() throws {
        let png = try file("big.png")
        #expect(try read(png, limit: 4).count == 4)
        #expect(throws: APIError.tooLarge("big.png")) { try self.read(png, limit: 3) }
        #expect(APIFiles.readLimit == 1 << 30)
    }
}
