import CoreGraphics
import CSRecording
import Foundation

/// "Export Before/After GIF": a looping GIF of two frames, the export without the document's topmost image object and
/// then the full export, each shown for `frameDelayCentiseconds`. The frames are made here; the GIF is written by
/// ClearShot's own GIF writer and quantiser.
public enum BeforeAfterGIF {
    /// How long each frame shows: 0.8 s, in the centiseconds a GIF counts in.
    public static let frameDelayCentiseconds = 80

    public enum Failure: Error, Equatable, LocalizedError {
        /// The document has no image object to take off for the first frame.
        case noImage
        /// A frame couldn't be rendered (a missing base image, an output that is empty or too big).
        case cannotRender

        public var errorDescription: String? {
            switch self {
            case .noImage: "There is no added image to compare."
            case .cannotRender: "The picture couldn't be rendered."
            }
        }
    }

    /// The topmost image object: the last one in the document's order, which is how images stack.
    public static func topmostImage(in document: AnnotationDocument) -> AnnotationObject? {
        document.objects.last { if case .image = $0.kind { true } else { false } }
    }

    /// Whether the document has an image object, so there is a before and an after (the menu item's condition).
    public static func isAvailable(for document: AnnotationDocument) -> Bool {
        topmostImage(in: document) != nil
    }

    /// The document as the first frame shows it: without its topmost image object. Nil when it has none.
    public static func withoutTopmostImage(_ document: AnnotationDocument) -> AnnotationDocument? {
        guard let top = topmostImage(in: document) else { return nil }
        var before = document
        before.objects.removeAll { $0.id == top.id }
        return before
    }

    /// The two frames, both at one size: the export without the topmost image, then the full export. When removing the
    /// image changes the output's size (a background that trims to its content), the smaller frame is centered on white.
    /// Rulers are labeled in `rulerUnit`.
    public static func frames(for document: AnnotationDocument, images: ImageStore,
                              rulerUnit: SizeUnit = .rulerDefault) throws -> [CGImage] {
        guard let without = withoutTopmostImage(document) else { throw Failure.noImage }
        guard let before = Renderer.render(without, images: images, rulerUnit: rulerUnit),
              let after = Renderer.render(document, images: images, rulerUnit: rulerUnit) else {
            throw Failure.cannotRender
        }
        let width = max(before.width, after.width), height = max(before.height, after.height)
        return try [before, after].map { try padded($0, toWidth: width, height: height) }
    }

    /// The GIF's bytes: the two frames, one global palette over both, looping forever.
    public static func data(for document: AnnotationDocument, images: ImageStore, rulerUnit: SizeUnit = .rulerDefault) throws -> Data {
        let frames = try frames(for: document, images: images, rulerUnit: rulerUnit).map(gifFrame)
        let palette = GIFQuantizer.palette(from: frames, colors: 255)
        var writer = try GIFWriter(sink: DataSink(), width: frames[0].width, height: frames[0].height, globalPalette: palette)
        for frame in frames {
            // Every pixel is part of a frame: it is whole, not a change from the one before.
            let diff = GIFDiff(rect: GIFRect(x: 0, y: 0, width: frame.width, height: frame.height),
                               changed: [Bool](repeating: true, count: frame.width * frame.height))
            let indices = GIFQuantizer.indices(for: frame, diff: diff, palette: palette, dither: true)
            try writer.add(diff, indices: indices, localPalette: nil, delayCentiseconds: frameDelayCentiseconds)
        }
        return try writer.finish().data
    }

    // MARK: Pieces

    private struct DataSink: GIFByteSink {
        var data = Data()

        mutating func write(_ bytes: UnsafeRawBufferPointer) throws {
            data.append(contentsOf: bytes)
        }
    }

    private static var srgb: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    /// `image` at `width` × `height`: itself when it is that size, else centered on white.
    private static func padded(_ image: CGImage, toWidth width: Int, height: Int) throws -> CGImage {
        guard image.width != width || image.height != height else { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.cannotRender }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: (width - image.width) / 2, y: (height - image.height) / 2,
                                       width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw Failure.cannotRender }
        return result
    }

    /// The image's pixels as the GIF encoder takes them: BGRA, on white where it is transparent (a GIF has no partial
    /// transparency, and a transparent export would show as black).
    private static func gifFrame(_ image: CGImage) throws -> GIFFrame {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: srgb,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.cannotRender }
        return GIFFrame(width: width, height: height, bytesPerRow: bytesPerRow, bgra: bytes)
    }
}
