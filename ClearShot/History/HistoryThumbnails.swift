import AppKit
import CSHistory
import ImageIO

/// The History grid's small pictures: each item's `.thumb.png`, read and downsampled off the main actor, cached by item
/// and image stamp (`modifiedAt` changes only when the image is replaced). Never the full working copy: an item without
/// a readable `.thumb.png` (an older write that failed) has no picture.
final class HistoryThumbnails {
    private let root: URL
    private let maxPixel: Int
    private let cache = NSCache<NSString, CGImage>()
    /// Stamps whose file couldn't be read: not tried again until the image is replaced.
    private var unreadable: Set<String> = []
    /// Loads under way, with who is waiting for each.
    private var waiting: [String: [(CGImage?) -> Void]] = [:]

    /// `maxPixel` is the longer side: 384 px is a 192-pt cell at 2×.
    init(root: URL, maxPixel: Int = 384) {
        self.root = root
        self.maxPixel = maxPixel
        // About 180 pictures at 384 × 240 px, several screens of the grid.
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// The item's picture when it is cached. Otherwise nil, and `ready` is called on the main actor once the file has
    /// been read (with nil when it can't be), unless it is already known to be unreadable. Several requests for one
    /// stamp share a single read.
    func image(for item: HistoryItem, ready: @escaping (CGImage?) -> Void) -> CGImage? {
        let key = Self.key(for: item)
        if let image = cache.object(forKey: key as NSString) { return image }
        guard !unreadable.contains(key) else { return nil }
        if waiting[key] != nil {
            waiting[key]?.append(ready)
            return nil
        }
        waiting[key] = [ready]
        let url = item.thumbnailURL(in: root)
        let maxPixel = maxPixel
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { Self.read(url, maxPixel: maxPixel) }.value
            self?.finish(key, image: image)
        }
        return nil
    }

    private func finish(_ key: String, image: CGImage?) {
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        } else {
            unreadable.insert(key)
        }
        let readers = waiting.removeValue(forKey: key) ?? []
        readers.forEach { $0(image) }
    }

    private static func key(for item: HistoryItem) -> String {
        "\(item.id.uuidString)-\(item.modifiedAt?.timeIntervalSinceReferenceDate.description ?? "none")"
    }

    /// Decodes now, so drawing the cell never decodes on the main thread.
    nonisolated private static func read(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
