import AppKit
import CSAnnotation
import CSCapture
import ImageIO
import UniformTypeIdentifiers

/// Pictures coming into the editor as image objects: image files and image data, upright, with their pixels per point.
enum ImageInput {
    /// A picture and its pixels per point (`ImagePlacement.scale(forDPI:)`).
    typealias Picked = (image: CGImage, scale: Double)

    /// What a pasteboard gave: the pictures that loaded, in order, and how many image files or data it held that didn't
    /// (an SVG, a damaged file), which the person is told about.
    struct Pictures {
        var images: [Picked] = []
        var unreadable = 0
    }

    /// The image data types read from a pasteboard or a drop, best first.
    static let dataTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                                           NSPasteboard.PasteboardType("public.heic")]

    private static let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// ImageIO only, so it can read a file off the main actor (`ImageImporter.importFile`).
    nonisolated static func load(_ url: URL) -> Picked? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(picked(from:))
    }

    /// ImageIO only, so it can decode off the main actor (a URL command's file, read by `APIFiles.read`).
    nonisolated static func load(data: Data) -> Picked? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(picked(from:))
    }

    /// The source is opened once: the picture and its density come from the same image.
    private nonisolated static func picked(from source: CGImageSource) -> Picked? {
        guard let loaded = ImageOps.loadUpright(from: source) else { return nil }
        return (loaded.image, ImagePlacement.scale(forDPI: loaded.dpi))
    }

    /// Whether the pasteboard carries files that are there (copied or dragged from Finder, or with a copy ClearShot made).
    /// Its image data is then never the picture: Finder puts each copied file's icon there, which would go in for a PDF, a
    /// text file or an image that doesn't load. A file that has gone since (a temporary copy, cleared at the next launch)
    /// doesn't count, so a copy ClearShot made still pastes from its image data. `ImageImporter` follows the same rule.
    static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// With files on the pasteboard (`carriesFiles`), every image file among them, in order; the others are ignored, and
    /// the image files that don't load (an SVG, a damaged file) count as unreadable. Without files, the first image data
    /// that loads, as `ImageImporter.openFromClipboard` reads it. The data is read rather than an NSImage, whose CGImage
    /// can come back at point size. Empty, with nothing unreadable, when the pasteboard holds no image at all, which
    /// includes files of which none is an image.
    static func pictures(from pasteboard: NSPasteboard) -> Pictures {
        var pictures = Pictures()
        if carriesFiles(pasteboard) {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL] ?? []
            for url in urls {
                if let picked = load(url) { pictures.images.append(picked) } else { pictures.unreadable += 1 }
            }
            return pictures
        }
        guard pasteboard.availableType(from: dataTypes) != nil else { return pictures }
        if let picked = dataTypes.lazy.compactMap({ pasteboard.data(forType: $0) }).compactMap({ load(data: $0) }).first {
            pictures.images = [picked]
        } else {
            pictures.unreadable = 1
        }
        return pictures
    }

    /// Whether `pasteboard` holds an image `pictures(from:)` may be able to read, judged by its types: with files, an image
    /// file among them; without, image data.
    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        carriesFiles(pasteboard)
            ? pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOptions)
            : pasteboard.availableType(from: dataTypes) != nil
    }
}
