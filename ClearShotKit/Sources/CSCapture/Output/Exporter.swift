import CoreGraphics
import CSCore
import Foundation

public struct ExportRequest: Sendable {
    public var image: CGImage
    public var format: ImageFormat
    public var quality: Double
    /// The image's own scale, recorded in the file as its density (`ImageEncoder.encode`).
    public var pixelsPerPoint: Double
    public var directory: URL
    public var template: FileNameTemplate
    public var nameContext: FileNameContext
    /// Adds "@2x" before the extension.
    public var retinaSuffix: Bool
    /// Marks the file as a screenshot: a captured screenshot's tag, nil for anything else, which then carries no
    /// screen-capture attributes.
    public var screenCapture: ScreenCaptureTag?
    /// A name chosen by the person (Ask for name, a thumbnail saved later), used instead of the template. Also used
    /// to fix a template name once: a template with random characters gives a new name on every read of `baseName`.
    public var nameOverride: String?

    public init(image: CGImage, format: ImageFormat, quality: Double, pixelsPerPoint: Double, directory: URL,
                template: FileNameTemplate, nameContext: FileNameContext, retinaSuffix: Bool,
                screenCapture: ScreenCaptureTag?, nameOverride: String? = nil) {
        self.image = image
        self.format = format
        self.quality = quality
        self.pixelsPerPoint = pixelsPerPoint
        self.directory = directory
        self.template = template
        self.nameContext = nameContext
        self.retinaSuffix = retinaSuffix
        self.screenCapture = screenCapture
        self.nameOverride = nameOverride
    }

    /// Saves under exactly `baseName` (plus " (2)" and so on if taken).
    public init(image: CGImage, format: ImageFormat, quality: Double, pixelsPerPoint: Double, directory: URL, baseName: String,
                screenCapture: ScreenCaptureTag?) {
        self.init(image: image, format: format, quality: quality, pixelsPerPoint: pixelsPerPoint, directory: directory,
                  template: .standard, nameContext: FileNameContext(), retinaSuffix: false,
                  screenCapture: screenCapture, nameOverride: baseName)
    }

    /// The file name without its extension.
    public var baseName: String {
        if let nameOverride { return nameOverride }
        let name = FileNamer.baseName(for: template, context: nameContext)
        return retinaSuffix ? name + "@2x" : name
    }
}

public enum Exporter {
    /// Encodes and writes the image under its template name, creating the folder if needed. Returns the file's URL.
    public static func save(_ request: ExportRequest) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: request.directory, withIntermediateDirectories: true)
        } catch {
            throw CaptureError.cannotCreateFolder(request.directory.path(percentEncoded: false).trimmingTrailingSlash)
        }
        let url = FileNamer.uniqueURL(in: request.directory, baseName: request.baseName, pathExtension: request.format.fileExtension)
        try write(request.image, as: request.format, quality: request.quality, pixelsPerPoint: request.pixelsPerPoint, to: url,
                  screenCapture: request.screenCapture)
        return url
    }

    /// Encodes and writes to an exact URL, replacing any file there, then, with a `screenCapture` tag, marks it as a
    /// screenshot; a file that can't take the tag is kept, and the failure logged. The file records `pixelsPerPoint` as
    /// its density, so Preview shows it at its point size, as it does macOS's own screenshots.
    public static func write(_ image: CGImage, as format: ImageFormat, quality: Double, pixelsPerPoint: Double, to url: URL,
                             screenCapture: ScreenCaptureTag?) throws {
        // Encoding and writing fail for different reasons, and the person needs different advice for each.
        let data: Data
        do {
            data = try ImageEncoder.encode(image, as: format, quality: quality, pixelsPerPoint: pixelsPerPoint)
        } catch {
            throw CaptureError.cannotEncode(format.title)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CaptureError.cannotSave(url.path(percentEncoded: false))
        }
        // A fresh file (written atomically), so an untagged one carries no attributes from the file it replaced.
        if let screenCapture { ScreenCaptureMetadata.apply(screenCapture, to: url) }
    }
}

public extension Exporter {
    /// Saves a copy of a video or GIF (its history working copy) into `directory` as `baseName` plus the file's own
    /// extension, " (2)" and so on if taken, creating the folder if needed; never re-encoded. On APFS the copy is a clone.
    static func saveCopy(of source: URL, in directory: URL, baseName: String) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CaptureError.cannotCreateFolder(directory.path(percentEncoded: false).trimmingTrailingSlash)
        }
        let url = FileNamer.uniqueURL(in: directory, baseName: baseName, pathExtension: source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            throw CaptureError.cannotSave(url.path(percentEncoded: false))
        }
        return url
    }

    /// Copies a video or GIF to an exact URL (Save As…), replacing any file there. The copy is made beside it first, on
    /// the same volume, and only swapped in once complete, so a copy that fails leaves the file it would replace intact.
    static func writeCopy(of source: URL, to url: URL) throws {
        let fileManager = FileManager.default
        var staging: URL?
        do {
            let folder = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url,
                                             create: true)
            staging = folder
            let copy = folder.appending(path: url.lastPathComponent)
            try fileManager.copyItem(at: source, to: copy)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                _ = try fileManager.replaceItemAt(url, withItemAt: copy)
            } else {
                try fileManager.moveItem(at: copy, to: url)
            }
        } catch {
            if let staging { try? fileManager.removeItem(at: staging) }
            throw CaptureError.cannotSave(url.path(percentEncoded: false))
        }
        if let staging { try? fileManager.removeItem(at: staging) }
    }
}

extension String {
    var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
