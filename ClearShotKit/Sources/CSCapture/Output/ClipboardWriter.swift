import AppKit
import CSCore

@MainActor
public enum ClipboardWriter {
    /// Whether the pasteboard item carries the image: always, except "File only" with a file. "File only"
    /// without a file falls back to the image so copying never does nothing. Callers encode the PNG (off the
    /// main actor) only when this is true.
    public nonisolated static func includesImage(mode: ClipboardMode, fileURL: URL?) -> Bool {
        mode != .fileOnly || fileURL == nil
    }

    /// Puts a capture on the pasteboard as one item: PNG data, a file URL, or both, as `mode` asks. The pasteboard is
    /// cleared only when there is something to write. Returns whether anything was written.
    @discardableResult
    public static func write(pngData: Data?, fileURL: URL?, mode: ClipboardMode, to pasteboard: NSPasteboard = .general) -> Bool {
        let png = includesImage(mode: mode, fileURL: fileURL) ? pngData : nil
        let file = mode == .imageOnly ? nil : fileURL
        guard png != nil || file != nil else { return false }
        let item = NSPasteboardItem()
        if let png { item.setData(png, forType: .png) }
        if let file { item.setString(file.absoluteString, forType: .fileURL) }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// Puts a video or a GIF on the pasteboard as one item: its file URL whatever the clipboard mode (there is no image
    /// to put beside it), plus the GIF's data (`com.compuserve.gif`) when given, which the caller reads off the main
    /// actor. Clears the pasteboard first. Returns whether the item was written.
    @discardableResult
    public static func write(mediaFileURL: URL, gifData: Data?, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        item.setString(mediaFileURL.absoluteString, forType: .fileURL)
        if let gifData { item.setData(gifData, forType: gifType) }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    private static let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")

    /// Puts several files on the pasteboard (History's Copy with more than one item selected): one item per file, each
    /// carrying only its file URL, no image data. The pasteboard is cleared only when there is at least one file.
    /// Returns whether anything was written.
    @discardableResult
    public static func write(fileURLs: [URL], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !fileURLs.isEmpty else { return false }
        let items = fileURLs.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }
}
