import CoreGraphics
import Foundation

/// A document's picture as the secrets check reads it in Annotate (Mask Sensitive Info), and how it lies in the base.
public struct PictureRender: Sendable {
    /// The picture, in output pixels (what `Renderer.render` makes of `AnnotationDocument.pictureOnly`).
    public let image: CGImage
    /// Takes a pixel of `image` back to the base's pixels, where the document's objects are.
    public let mapping: RenderedBaseMapping
}

extension AnnotationDocument {
    /// The document reduced to its picture: the base as the image operations and the canvas have left it, with the
    /// redactions on it, and without the annotations and the background.
    ///
    /// What the secrets check scans is what a mask can hide, and a mask is a redaction. A redaction replaces the picture under
    /// it, and every other object is drawn over the redactions, so a mask over text inside an annotation (a label somebody
    /// typed, a picture pasted in) would be drawn under that text and hide nothing. Those are left out, so that "masked" only
    /// ever means the picture's text is covered, and a second run doesn't find them again. Redactions stay, so text that is
    /// already pixelated isn't found and masked a second time. The background is a frame around the canvas, out of the base:
    /// text in it can't be masked either.
    public var pictureOnly: AnnotationDocument {
        var copy = self
        copy.objects = objects.filter { if case .redact = $0.kind { true } else { false } }
        copy.background = nil
        return copy
    }
}

extension Renderer {
    /// The picture of `document` for the secrets check (`AnnotationDocument.pictureOnly`) and the mapping that takes its
    /// pixels to the base (`baseMapping`), made from the same reduced document so that the two agree. Nil when the picture
    /// can't be rendered (no base image, an output that is empty or too big), or when the mapping isn't of the render that
    /// was made. Uses no cache; call it off the main actor, as `render` is.
    public static func renderPicture(of document: AnnotationDocument, images: ImageStore) -> PictureRender? {
        let picture = document.pictureOnly
        guard let image = render(picture, images: images), let mapping = baseMapping(of: picture, images: images),
              mapping.renderedSize == CGSize(width: image.width, height: image.height) else { return nil }
        return PictureRender(image: image, mapping: mapping)
    }
}
