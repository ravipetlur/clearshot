import CoreGraphics
import CSCapture
import CSCore
import Foundation

public enum DocumentError: Error, LocalizedError, Equatable {
    /// The package's `document.json` is missing or damaged, holds numbers the editor can't work with, names an image
    /// outside the package, or doesn't match its base image's size (the path is the package's). Reading never gets as far
    /// as `unsafeImageName`: a document like that is just unreadable.
    case unreadable(String)
    case newerVersion
    case missingBase
    /// Writing was refused: the document names an image (the name is given) that isn't a plain path inside the package,
    /// so the file would land somewhere else. Nothing is written.
    case unsafeImageName(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The ClearShot project couldn't be opened"
        case .newerVersion: "This project was made by a newer version of ClearShot"
        case .missingBase: "The project's image is missing"
        case .unsafeImageName: "The project has an image that can't be stored safely"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unreadable(let path): "\((path as NSString).abbreviatingWithTildeInPath) may be damaged."
        case .newerVersion: "Update ClearShot, then open it again."
        case .missingBase: "The project's original.png was removed or renamed."
        case .unsafeImageName(let name): "\"\(name)\" isn't a plain file name inside the project."
        }
    }
}

/// `.clearshot` projects: a package directory with `document.json`, the original image, image objects and the
/// background's picture in `images/`, and `QuickLook/Thumbnail.png` and `QuickLook/Preview.png` for Finder.
public enum DocumentPackage {
    public static let fileExtension = "clearshot"
    /// The exported type the app declares in its Info.plist as `$(PRODUCT_BUNDLE_IDENTIFIER).document`.
    public static let typeIdentifier = CSCore.identifier("document")
    public static let documentFileName = "document.json"
    public static let thumbnailPath = "QuickLook/Thumbnail.png"
    public static let previewPath = "QuickLook/Preview.png"
    static let thumbnailMaxPixel = 512

    /// Writes `document.json` and every image the document uses into `directory`. An image file already there under the
    /// same name is kept: images never change once written (bases are originals, image objects get unique names).
    /// Every image's destination is resolved first (`ImageRef.url(in:)`), and a name that leads outside `directory`
    /// throws `DocumentError.unsafeImageName` before anything is created. An image whose name ends in `.jpg`, in any case
    /// (an opaque background picture), is written as JPEG at quality 0.9; every other as PNG. Reading takes either.
    public static func writeContents(_ document: AnnotationDocument, images: ImageStore, to directory: URL) throws {
        let fileManager = FileManager.default
        let destinations = try ImageStore.references(in: document).sorted { $0.name < $1.name }.map { ref in
            guard let url = ref.url(in: directory) else { throw DocumentError.unsafeImageName(ref.name) }
            return (ref: ref, url: url)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (ref, url) in destinations {
            guard !fileManager.fileExists(atPath: url.path(percentEncoded: false)), let image = images[ref] else { continue }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let isJPEG = ref.name.lowercased().hasSuffix(".jpg")
            try ImageEncoder.encode(image, as: isJPEG ? .jpeg : .png, quality: isJPEG ? 0.9 : 1).write(to: url, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: directory.appending(path: documentFileName), options: .atomic)
    }

    /// The package's document. One that names an image (its base, an image object or its background's picture) that
    /// isn't a plain path inside the package, which could reach any file on the machine, is rejected as unreadable. So is
    /// one whose numbers would hang or crash the editor (`AnnotationDocument.isWellFormed`).
    public static func readDocument(from directory: URL) throws -> AnnotationDocument {
        guard let data = try? Data(contentsOf: directory.appending(path: documentFileName)) else {
            throw DocumentError.unreadable(directory.path(percentEncoded: false))
        }
        // Look at the version first, so a newer format gets its own message rather than "damaged".
        struct Version: Decodable { var version: Int }
        if let version = try? JSONDecoder().decode(Version.self, from: data).version, version > AnnotationDocument.currentVersion {
            throw DocumentError.newerVersion
        }
        let document: AnnotationDocument
        do {
            document = try JSONDecoder().decode(AnnotationDocument.self, from: data)
        } catch {
            throw DocumentError.unreadable(directory.path(percentEncoded: false))
        }
        guard ImageStore.references(in: document).allSatisfy({ $0.url(in: directory) != nil }), document.isWellFormed else {
            throw DocumentError.unreadable(directory.path(percentEncoded: false))
        }
        return document
    }

    /// Saves a complete package at `url`, replacing one already there only once the new one is fully written.
    /// `rendered` becomes the Finder preview and thumbnail. Throws `DocumentError.missingBase`, before writing anything,
    /// when `images` doesn't hold the document's base: a package that couldn't be opened never replaces a good one.
    /// The base is always stored as `original.png` (`ImageRef.original`): a capture's document names its base
    /// `.original.png`, which Finder's Show Package Contents and tools that skip dot files would hide. Only the written
    /// document says so; the caller's is unchanged.
    public static func write(_ document: AnnotationDocument, images: ImageStore, rendered: CGImage, to url: URL) throws {
        guard let base = images[document.base] else { throw DocumentError.missingBase }
        var document = document
        var images = images
        if document.base != .original {
            images.set(base, for: .original)
            document.base = .original
        }
        let fileManager = FileManager.default
        // Stage next to the destination, so the final swap stays on one volume. The name doesn't repeat the package's, so
        // a package with a long name can still be saved.
        let staging = url.deletingLastPathComponent()
            .appending(path: ".saving-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        try writeContents(document, images: images, to: staging)
        try fileManager.createDirectory(at: staging.appending(path: "QuickLook", directoryHint: .isDirectory),
                                        withIntermediateDirectories: true)
        try ImageEncoder.encode(rendered, as: .png, quality: 1).write(to: staging.appending(path: previewPath))
        try ImageEncoder.encode(ImageOps.thumbnail(rendered, maxPixel: thumbnailMaxPixel), as: .png, quality: 1)
            .write(to: staging.appending(path: thumbnailPath))
        if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(url, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: url)
        }
    }

    /// The package's document and images. A base image of another size than the document says is rejected as unreadable:
    /// it would be stretched to that size, while redactions are clipped to its own pixels.
    public static func read(from url: URL) throws -> (document: AnnotationDocument, images: ImageStore) {
        let document = try readDocument(from: url)
        let images = ImageStore.load(for: document, from: url)
        guard let base = images[document.base] else { throw DocumentError.missingBase }
        guard CGSize(width: base.width, height: base.height) == document.baseSize else {
            throw DocumentError.unreadable(url.path(percentEncoded: false))
        }
        return (document, images)
    }
}
