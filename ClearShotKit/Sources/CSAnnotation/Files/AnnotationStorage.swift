import CoreGraphics
import CSCapture
import CSHistory
import Foundation

/// Annotate documents for history items. The item's folder holds `document.json`, `.original.png` (the untouched
/// capture) and `images/`. Its working copy becomes a render of the document, so the thumbnail, copies and drags show
/// the annotations, and reopening shows every object still editable.
public enum AnnotationStorage {
    /// The base image of a history item's document: the capture as it was when the editor first opened it. A dot file,
    /// which `FileNamer.sanitize` never leaves at the start of a name, so no working copy (named after the capture) can
    /// share its name, case-insensitively or otherwise.
    public static let historyBase = ImageRef(name: ".original.png")

    /// A scale within 0.01 of a whole number (at least 1) is that number, so a Retina capture resized to half reads as 1x.
    static func snapped(scale: Double) -> Double {
        let nearest = scale.rounded()
        return nearest >= 1 && abs(scale - nearest) <= 0.01 ? nearest : scale
    }

    /// The item's document and images. An item never annotated gets a new, empty document whose base is the capture: its
    /// working copy, copied to `historyBase` afresh on every open, because Quick Access may have rotated or resized the
    /// capture since the editor last had it. An annotated item's working copy is a render, so its document is read and its
    /// base kept; the base is ours, so its size is the one to trust over the document's. A document that can't be read
    /// falls back to a new one over the kept base (or, if that is gone too, the working copy), so the capture is never
    /// lost. `recovered` says that happened: the item was annotated, but its annotations are gone from what was opened, and
    /// applying it would replace the annotated working copy. A new document is a window screenshot (`isWindowShot`) when
    /// the item is a window capture; a document read keeps its own flag.
    public static func open(_ item: HistoryItem, root: URL) throws
        -> (document: AnnotationDocument, images: ImageStore, recovered: Bool) {
        let folder = item.folder(in: root)
        if let read = openReadOnly(item, root: root) { return (read.document, read.images, false) }
        let fileManager = FileManager.default
        let original = folder.appending(path: historyBase.name)
        if item.hasDocument != true || !fileManager.fileExists(atPath: original.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: original)
            try fileManager.copyItem(at: item.mediaURL(in: root), to: original)
        }
        guard let base = ImageOps.load(original) else { throw DocumentError.missingBase }
        var document = AnnotationDocument(baseSize: CGSize(width: base.width, height: base.height), pixelScale: item.scale,
                                          base: historyBase)
        document.isWindowShot = item.captureKind == .window
        return (document, ImageStore([historyBase.name: base]), item.hasDocument == true)
    }

    /// The item's saved document and its images, **read only**: nothing in its folder is written, copied or removed. Nil when
    /// the item has no document, or its document can't be used: it can't be read, its base image is gone, or its numbers aren't
    /// well formed (`AnnotationDocument.isWellFormed`). It is the first branch of `open` and nothing more, so a caller that only
    /// wants to look (the secrets check's scan, which runs in the background) never reaches `open`'s recovery, which copies the
    /// working copy over the base. The base's size is the image's own, as in `open`.
    public static func openReadOnly(_ item: HistoryItem, root: URL) -> (document: AnnotationDocument, images: ImageStore)? {
        guard item.hasDocument == true else { return nil }
        let folder = item.folder(in: root)
        guard var document = try? DocumentPackage.readDocument(from: folder) else { return nil }
        let images = ImageStore.load(for: document, from: folder)
        guard let base = images[document.base] else { return nil }
        document.baseSize = CGSize(width: base.width, height: base.height)
        guard document.isWellFormed else { return nil }
        return (document, images)
    }

    /// For an annotated item whose document couldn't be read (`open` reported `recovered`): makes `image`, its working copy
    /// as Quick Access just rotated, flipped or resized it, annotations and all, the capture of record. It becomes the
    /// working copy with the item no longer flagged as annotated, and the unreadable `document.json` goes. The next open
    /// then treats the item as never annotated and starts from this image, instead of reporting the recovery again and
    /// editing the stale original. Returns the updated item; the caller records it in the `HistoryStore`.
    public static func makeCaptureOfRecord(_ image: CGImage, scale: Double, for item: HistoryItem, root: URL) throws -> HistoryItem {
        var plain = item
        plain.hasDocument = false
        let updated = try HistoryWriter.replaceImage(of: plain, with: image, scale: scale, root: root)
        // After the flag is off, which is what makes the next open ignore the document; a leftover file is harmless.
        try? FileManager.default.removeItem(at: item.folder(in: root).appending(path: DocumentPackage.documentFileName))
        return updated
    }

    /// Writes the document into the item's folder and replaces the working copy and thumbnail with `rendered`. Returns
    /// the updated item; the caller records it in the `HistoryStore`. For an item not yet flagged, the metadata with
    /// `hasDocument` set (still the old size and scale) is written before the render, so the flag is on disk before any
    /// render is: an interrupted save leaves an item that opens its document over the untouched base, never one that
    /// treats the annotated working copy as the capture. When the save throws partway (a failed thumbnail write, say),
    /// the caller must re-read the item (`HistoryStore.reload`), because the store's copy doesn't have the flag the disk
    /// now does. `replaceImage` then writes the render and the final metadata, with the document's scale after
    /// resizing. The item's `isTransparent` becomes whether `rendered` has any see-through pixel, written with the render
    /// and not before it.
    public static func save(_ document: AnnotationDocument, images: ImageStore, rendered: CGImage, to item: HistoryItem,
                            root: URL) throws -> HistoryItem {
        try DocumentPackage.writeContents(document, images: images, to: item.folder(in: root))
        var flagged = item
        flagged.hasDocument = true
        if item.hasDocument != true { try HistoryWriter.writeMetadata(flagged, root: root) }
        // Whether the render has see-through pixels (a transparent fill, or a transparent window shot's expanded canvas),
        // so a later save never picks a format that can't hold them (ExportFormatPolicy reads this). It goes in with the
        // render, in the final metadata, not the flag-first write above: until the render replaces the working copy, the
        // metadata still describes the old one.
        var annotated = flagged
        annotated.isTransparent = ImageOps.hasTransparentPixels(rendered)
        return try HistoryWriter.replaceImage(of: annotated, with: rendered, scale: document.renderedScale, root: root)
    }

    /// Writes a new history item that is a document from the start (a capture that got a background, `CaptureDocument`)
    /// and returns it; the caller records it in the `HistoryStore`. The document and its images (`.original.png`,
    /// `images/`, `document.json`) go into the item's folder first, then `HistoryWriter.create` writes `rendered` as the
    /// working copy and the thumbnail, and `meta.json` last, with `hasDocument` set. Until `meta.json` is there the store
    /// doesn't list the folder, and `HistoryStore.purge` removes it later, so a write that stops partway leaves no item.
    /// The item's scale is the document's (`renderedScale`), and its `isTransparent` is whether `rendered` has any
    /// see-through pixel: a fill of None with corners makes an opaque capture transparent. Every other detail is `details`'s.
    public static func createItem(document: AnnotationDocument, images: ImageStore, rendered: CGImage,
                                  details: HistoryWriter.Details, id: UUID = UUID(), root: URL) throws -> HistoryItem {
        try DocumentPackage.writeContents(document, images: images,
                                          to: root.appending(path: id.uuidString, directoryHint: .isDirectory))
        var annotated = details
        annotated.hasDocument = true
        annotated.isTransparent = ImageOps.hasTransparentPixels(rendered)
        annotated.scale = document.renderedScale
        return try HistoryWriter.create(rendered, details: annotated, id: id, root: root)
    }
}
