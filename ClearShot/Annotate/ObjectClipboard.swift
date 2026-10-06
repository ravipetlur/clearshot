import AppKit
import CSAnnotation
import CSCapture
import CSCore

/// Copying objects between editors. The pasteboard item carries:
/// - for pasting into an editor: the objects, the base pixels per point of the document they came from, and the PNG of
///   each image object's bitmap;
/// - for pasting anywhere else: a PNG of just those objects ("Copy Object to Clipboard").
enum ObjectClipboard {
    static let type = NSPasteboard.PasteboardType(CSCore.identifier("objects"))

    /// What goes on the pasteboard under `type`.
    private struct Payload: Codable {
        var objects: [AnnotationObject]
        var sourceScale: Double?
        /// PNG data by image name.
        var images: [String: Data]
    }

    /// What a paste gets back.
    struct Contents {
        var objects: [AnnotationObject]
        var sourceScale: Double?
        var images: [ImageRef: CGImage]
    }

    static func write(_ objects: [AnnotationObject], document: AnnotationDocument, images: ImageStore) {
        var bitmaps: [String: Data] = [:]
        for object in objects {
            guard case .image(let picture) = object.kind, bitmaps[picture.image.name] == nil, let image = images[picture.image],
                  let png = try? ImageEncoder.encode(image, as: .png, quality: 1) else { continue }
            bitmaps[picture.image.name] = png
        }
        let item = NSPasteboardItem()
        let payload = Payload(objects: objects, sourceScale: document.pixels(fromPoints: 1), images: bitmaps)
        if let data = try? JSONEncoder().encode(payload) { item.setData(data, forType: type) }
        // The picture is in base pixels, `pixelScale` of them to a point in a picture the editor exports (whose
        // `renderedScale` is that times the resize's scale), so the objects come out the size they are there.
        if let image = Renderer.renderObjects(objects, document: document, images: images),
           let png = try? ImageEncoder.encode(image, as: .png, quality: 1, pixelsPerPoint: document.pixelScale) {
            item.setData(png, forType: .png)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// Whether the pasteboard holds ClearShot objects, judged by its types alone (menu validation).
    static var hasObjects: Bool {
        NSPasteboard.general.availableType(from: [type]) != nil
    }

    static func read() -> Contents? {
        guard let data = NSPasteboard.general.data(forType: type) else { return nil }
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            var bitmaps: [ImageRef: CGImage] = [:]
            for (name, png) in payload.images {
                if let image = ImageOps.loadUpright(data: png) { bitmaps[ImageRef(name: name)] = image }
            }
            return Contents(objects: payload.objects, sourceScale: payload.sourceScale, images: bitmaps)
        }
        // The earlier format: just the objects.
        guard let objects = try? JSONDecoder().decode([AnnotationObject].self, from: data) else { return nil }
        return Contents(objects: objects, sourceScale: nil, images: [:])
    }
}
