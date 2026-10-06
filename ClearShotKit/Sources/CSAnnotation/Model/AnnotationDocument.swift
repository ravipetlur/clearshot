import CoreGraphics
import CSCapture
import Foundation

/// A document image, by its path relative to the document's folder ("original.png", "images/<id>.png").
public struct ImageRef: Codable, Hashable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }

    public static let original = ImageRef(name: "original.png")

    /// Where this image lives inside `directory`, or nil if the name could lead anywhere else. Names come from
    /// `document.json`, which may not be ours, so an image is only ever a plain relative path of ordinary components,
    /// with no link in it, that ends up inside `directory`. Use this to read and to write images alike.
    public func url(in directory: URL) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("~"), !name.contains("\0") else { return nil }
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let root = directory.standardizedFileURL
        let url = root.appending(path: name).standardizedFileURL
        let rootComponents = root.pathComponents
        guard url.pathComponents.count > rootComponents.count, Array(url.pathComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        // A link in the package could point anywhere. Documents don't contain any, so one is refused wherever it is,
        // including a link that doesn't lead anywhere yet.
        var step = root
        for component in components {
            step = step.appending(path: component)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: step.path) else { break }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return nil }
        }
        return directory.appending(path: name)
    }
}

/// Rotate, flip and resize the whole picture, annotations included, reversibly.
public enum ImageOp: Codable, Equatable, Sendable {
    case rotateLeft, rotateRight, flipHorizontal, flipVertical
    case resize(width: Int, height: Int)
}

/// What fills canvas outside the image: the image's detected edge color, nothing, or a color.
public enum CanvasFill: Codable, Equatable, Sendable {
    case auto
    case transparent
    case color(RGBAColor)
}

/// An annotated image. Objects live in base pixels; `canvasRect` is in output pixels.
public struct AnnotationDocument: Codable, Equatable, Sendable {
    /// Version 2 added `background` and `isWindowShot`.
    public static let currentVersion = 2

    public var version: Int
    public var base: ImageRef
    /// The base image's size in pixels, before image operations.
    public var baseSize: CGSize
    /// Pixels per point of the base image.
    public var pixelScale: Double
    public var imageOps: [ImageOp]
    /// The visible canvas in output pixels; nil is the whole image. It may extend past the image.
    public var canvasRect: CGRect?
    public var canvasFill: CanvasFill
    public var objects: [AnnotationObject]
    /// The frame drawn around the canvas, or nil for none.
    public var background: DocumentBackground?
    /// Whether the document is a window screenshot, which takes the window presets and Previous Settings.
    public var isWindowShot: Bool

    public init(baseSize: CGSize, pixelScale: Double, base: ImageRef = .original) {
        version = Self.currentVersion
        self.base = base
        self.baseSize = baseSize
        self.pixelScale = pixelScale
        imageOps = []
        canvasRect = nil
        canvasFill = .auto
        objects = []
        background = nil
        isWindowShot = false
    }

    private enum CodingKeys: String, CodingKey {
        case version, base, baseSize, pixelScale, imageOps, canvasRect, canvasFill, objects, background, isWindowShot
    }

    /// Tolerant of older files: only the image's size and scale are required, so a field added in a later version
    /// (with a default here) never makes a saved document unreadable. A background or window-shot flag that doesn't
    /// decode is none: a broken background never makes the document unreadable.
    ///
    /// The version read only matters to `DocumentPackage.readDocument`, which refuses a newer one before decoding. In
    /// memory a document is in today's format, as it will be written (`encode(to:)`), so `version` is `currentVersion`
    /// and an older file decodes equal to the same document made today.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseSize = try container.decode(CGSize.self, forKey: .baseSize)
        pixelScale = try container.decode(Double.self, forKey: .pixelScale)
        version = Self.currentVersion
        base = try container.decodeIfPresent(ImageRef.self, forKey: .base) ?? .original
        imageOps = try container.decodeIfPresent([ImageOp].self, forKey: .imageOps) ?? []
        canvasRect = try container.decodeIfPresent(CGRect.self, forKey: .canvasRect)
        canvasFill = try container.decodeIfPresent(CanvasFill.self, forKey: .canvasFill) ?? .auto
        objects = try container.decodeIfPresent([AnnotationObject].self, forKey: .objects) ?? []
        background = try? container.decodeIfPresent(DocumentBackground.self, forKey: .background)
        isWindowShot = (try? container.decodeIfPresent(Bool.self, forKey: .isWindowShot)) ?? false
    }

    /// Always written as `currentVersion`, whatever version was read: a saved document is in today's format, fields and
    /// all, so an older build refuses it (`DocumentError.newerVersion`) instead of dropping what it doesn't know.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(base, forKey: .base)
        try container.encode(baseSize, forKey: .baseSize)
        try container.encode(pixelScale, forKey: .pixelScale)
        try container.encode(imageOps, forKey: .imageOps)
        try container.encodeIfPresent(canvasRect, forKey: .canvasRect)
        try container.encode(canvasFill, forKey: .canvasFill)
        try container.encode(objects, forKey: .objects)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encode(isWindowShot, forKey: .isWindowShot)
    }

    /// The longest side a base image or a canvas may have: in pixels, and for the canvas the editor shows, in points.
    public static let maximumSide = 32_768.0
    /// The largest pixel scale a document may have.
    public static let maximumPixelScale = 16.0

    /// Whether every number in the document is one the editor and the renderer can work with. A document read from a file
    /// that may not be ours is checked with this, so a crafted file can't hang the app with an infinite or enormous canvas
    /// or crash it:
    /// - `pixelScale` is finite and in (0, 16];
    /// - `baseSize` is finite, positive and at most `maximumSide` on a side;
    /// - the canvas is finite and at most `maximumSide` on a side, in output pixels and in points (the canvas view's frame);
    /// - every object's numbers are finite (`AnnotationObject.isFinite`);
    /// - the background style's numbers are finite (`BackgroundStyle.isFinite`; a decoded style's always are), and its
    ///   frame, untrimmed, passes the canvas's test. Trims only shrink the content, so the untrimmed frame is the largest.
    public var isWellFormed: Bool {
        guard pixelScale.isFinite, pixelScale > 0, pixelScale <= Self.maximumPixelScale else { return false }
        guard [baseSize.width, baseSize.height].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= Self.maximumSide }) else { return false }
        /// Finite, and at most `maximumSide` on a side in output pixels and in points.
        func fits(_ rect: CGRect) -> Bool {
            let points = CGSize(width: rect.width / pixelScale, height: rect.height / pixelScale)
            return [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
                && [rect.width, rect.height, points.width, points.height].allSatisfy({ abs($0) <= Self.maximumSide })
        }
        guard fits(canvasBounds) else { return false }
        guard background?.style.isFinite ?? true else { return false }
        if let frame = backgroundLayout()?.frame, !fits(frame) { return false }
        return objects.allSatisfy(\.isFinite)
    }

    public var transform: DocumentTransform {
        DocumentTransform(baseSize: baseSize, ops: imageOps)
    }

    /// The visible canvas in output pixels.
    public var canvasBounds: CGRect {
        canvasRect ?? CGRect(origin: .zero, size: transform.outputSize)
    }

    /// Objects in the exact order the renderer draws them, bottom first: redactions (which replace the picture), then
    /// the spotlights (whose dimming covers what is under it), then everything else in creation order, then the
    /// counters. `Renderer.draw` iterates this, and clicks look for objects in its reverse, so the object a click picks
    /// is the one on top.
    public var visualOrder: [AnnotationObject] {
        var redactions: [AnnotationObject] = [], spotlights: [AnnotationObject] = []
        var others: [AnnotationObject] = [], counters: [AnnotationObject] = []
        for object in objects {
            switch object.kind {
            case .redact: redactions.append(object)
            case .spotlight: spotlights.append(object)
            case .counter: counters.append(object)
            default: others.append(object)
            }
        }
        return redactions + spotlights + others + counters
    }

    /// The next counter's value: one more than the highest so far, or `start` for the first.
    public func nextCounterValue(start: Int) -> Int {
        let values = objects.compactMap { object -> Int? in
            if case .counter(let counter) = object.kind { counter.value } else { nil }
        }
        // Saturating: a document we didn't write may hold the largest value there is.
        return values.max().map { $0 == .max ? $0 : $0 + 1 } ?? start
    }

    /// The document with one more image operation; an explicit canvas moves with the picture.
    public func applying(_ op: ImageOp) -> AnnotationDocument {
        var copy = self
        let before = transform
        copy.imageOps.append(op)
        if let canvas = canvasRect {
            copy.canvasRect = canvas.applying(before.inverse.concatenating(copy.transform.transform))
        }
        return copy
    }

    /// The image operation that a Quick Access menu change means for this annotated document, so the annotations turn
    /// and scale with the picture instead of being flattened. `itemScale` is the working copy's pixels per point.
    ///
    /// A resize names the size of the whole output, as the Resize dialog shows it (the working copy), but the operation
    /// resizes the picture. With a canvas that reaches past the picture, or a background around it, the picture gets its
    /// share of the size asked for, so the rest moves and scales with it and ends up at that size (within a pixel or two of
    /// rounding). `outputSize` is the size the request is a share of: the output bounds (`outputBounds()`, or the
    /// renderer's with auto-balance), or the canvas when nil. With no explicit canvas and no background the share is the
    /// whole size. Sizes are at least one pixel.
    public func imageOp(for change: ImageTransform, itemScale: Double, outputSize: CGSize? = nil) -> ImageOp {
        let picture = transform.outputSize
        switch change {
        case .rotateLeft:
            return .rotateLeft
        case .flipHorizontal:
            return .flipHorizontal
        case .scaleTo1x:
            return .resize(width: max(1, Int((picture.width / max(itemScale, 1)).rounded())),
                           height: max(1, Int((picture.height / max(itemScale, 1)).rounded())))
        case .resize(let width, let height):
            let whole = outputSize ?? canvasBounds.size
            return .resize(width: max(1, Int((picture.width * Double(width) / max(whole.width, 1)).rounded())),
                           height: max(1, Int((picture.height * Double(height) / max(whole.height, 1)).rounded())))
        }
    }

    /// A size in points as base pixels, so it looks that size in the output whatever the pixel scale and resize.
    public func pixels(fromPoints points: Double) -> Double {
        points * pixelScale / max(transform.scale, 0.0001)
    }

    /// The rendered picture's pixels per point as ClearShot records it: the capture's own scale, which a resize changes,
    /// snapped to a whole number within 0.01 of one, so a Retina capture resized to half reads as 1x. History stores it
    /// with the render, and the editor's copies, drags and files record it as their density.
    public var renderedScale: Double {
        AnnotationStorage.snapped(scale: pixelScale * transform.scale)
    }
}
