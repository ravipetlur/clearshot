import CoreGraphics
import Foundation

/// How the pixels of a document's render (`Renderer.render`) lie in the document's base, which its objects are in.
public struct RenderedBaseMapping: Equatable, Sendable {
    /// The render's size in pixels.
    public let renderedSize: CGSize
    /// Takes a point in the render's pixels (top-left origin) to the base's pixels (top-left origin), through the image
    /// operations undone and the canvas's and the background frame's offset taken off. The identity for a document nothing
    /// has been done to.
    public let toBase: CGAffineTransform

    public init(renderedSize: CGSize, toBase: CGAffineTransform) {
        self.renderedSize = renderedSize
        self.toBase = toBase
    }
}

extension Renderer {
    /// How the render of `document` maps back onto its base. The render starts at the output bounds rounded out to whole
    /// pixels (`render` does exactly that: the background's frame, or the canvas without a background); a point of it is
    /// that origin plus the pixel, in output space, and the image operations' inverse takes output space to the base. Both
    /// are in pixels: a document's `pixelScale` plays no part in where things are, only in how a redaction's blocks are
    /// sized.
    ///
    /// The working copy of a capture whose document has been written is this render, so a rectangle found in the working
    /// copy goes through `toBase` to where an object over it belongs. Nil when the render couldn't be made either (no base
    /// image, an output that is empty or too big).
    public static func baseMapping(of document: AnnotationDocument, images: ImageStore) -> RenderedBaseMapping? {
        guard images[document.base] != nil else { return nil }
        let bounds = outputBounds(of: document, images: images, cache: nil)
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) else { return nil }
        let output = bounds.integral
        guard output.width >= 1, output.height >= 1, output.width <= AnnotationDocument.maximumSide,
              output.height <= AnnotationDocument.maximumSide else { return nil }
        let toBase = CGAffineTransform(translationX: output.minX, y: output.minY).concatenating(document.transform.inverse)
        return RenderedBaseMapping(renderedSize: output.size, toBase: toBase)
    }
}
