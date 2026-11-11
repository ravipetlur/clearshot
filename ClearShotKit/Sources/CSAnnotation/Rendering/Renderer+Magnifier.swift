import CoreGraphics
import Foundation

/// What a magnifier's callout shows, made once a frame for all of a document's magnifiers: the picture as it is shown,
/// without the other annotations (as the pixel tools read it, `AnnotationDocument.pixelSource`), in base pixels.
struct MagnifiedPicture {
    /// The base with every redaction in it (`Renderer.redactedBase`): the only copy of the base a callout ever draws. Nil
    /// when it can't be made; the callout is then black.
    var base: CGImage?
    var baseSize: CGSize
    /// The image objects (pasted, dropped and combined pictures), in drawing order. They lie over the redactions, as on the
    /// canvas.
    var images: [AnnotationObject]
    /// What lies under the picture where the source reaches past the base: the canvas fill, or nothing (transparent).
    var backdrop: RGBAColor?
}

extension Renderer {
    /// The picture the document's magnifiers show (`MagnifiedPicture`). The redacted base comes from, and goes to, the same
    /// slot of `cache` as the one the canvas draws (`drawBase`), so a frame makes it once.
    static func magnifiedPicture(of document: AnnotationDocument, base: CGImage, cache: RenderCache?) -> MagnifiedPicture {
        let order = document.visualOrder
        let redacted = redactedBase(base, redactions: RedactionKey.all(in: order), pixelScale: document.pixelScale, cache: cache)
        let backdrop: RGBAColor?
        switch document.canvasFill {
        case .transparent:
            backdrop = nil
        case .color(let color):
            backdrop = color
        case .auto:
            if let cached = cache?.edgeColor, cached.base === base {
                backdrop = cached.color
            } else {
                let color = EdgeColor.dominant(in: base)
                cache?.edgeColor = (base, color)
                backdrop = color
            }
        }
        return MagnifiedPicture(base: redacted?.image, baseSize: document.baseSize,
                                images: order.filter { if case .image = $0.kind { true } else { false } },
                                backdrop: backdrop)
    }

    /// A magnifier, in base pixels: the connector, then the callout showing `picture`'s pixels in the source, magnified
    /// without interpolation so each pixel stays a crisp square, then the border.
    ///
    /// **What a redaction hides never shows here.** The only base drawn is the redacted one (`MagnifiedPicture.base`), in
    /// which every pixel under a redaction, on whole base pixels, is already its effect or black; a picture that can't be
    /// made leaves the callout black (`picture` nil: `draw(_:pixelScale:…)` on its own, which has no document to make it
    /// from). The other annotations aren't drawn in the callout: shapes inside the source don't appear there.
    static func drawMagnifier(_ object: AnnotationObject, _ magnifier: MagnifierObject, picture: MagnifiedPicture?,
                              pixelScale: Double, images: ImageStore, in context: CGContext) {
        let magnifier = MagnifierGeometry.normalized(magnifier)
        let source = magnifier.source, callout = magnifier.callout
        guard source.isFiniteRect, callout.isFiniteRect, callout.width > 0, callout.height > 0 else { return }
        let outline = MagnifierGeometry.path(of: magnifier.shape, in: callout)
        let color = object.style.color.cgColor
        let width = object.style.lineWidth
        context.saveGState()
        defer { context.restoreGState() }
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setLineCap(.round)

        if let connector = MagnifierGeometry.connector(of: magnifier) {
            context.setStrokeColor(color)
            context.setLineWidth(max(width / 2, pixelScale))
            context.move(to: connector.start)
            context.addLine(to: connector.end)
            context.strokePath()
        }

        context.saveGState()
        context.addPath(outline)
        context.clip()
        if let picture, let base = picture.base {
            if let backdrop = picture.backdrop {
                context.setFillColor(backdrop.cgColor)
                context.fill(callout)
            }
            context.interpolationQuality = .none
            // Base pixels in the source land on the callout.
            context.translateBy(x: callout.minX, y: callout.minY)
            context.scaleBy(x: callout.width / source.width, y: callout.height / source.height)
            context.translateBy(x: -source.minX, y: -source.minY)
            drawImage(base, in: CGRect(origin: .zero, size: picture.baseSize), context: context)
            for var image in picture.images {
                image.style.shadow = false
                draw(image, pixelScale: pixelScale, base: nil, images: images, in: context)
            }
        } else {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(callout)
        }
        context.restoreGState()

        // Inside the callout's edge, so the border covers the content's outermost pixels and nothing beyond.
        let ring = callout.insetBy(dx: width / 2, dy: width / 2)
        if magnifier.border, width > 0, ring.width > 0, ring.height > 0 {
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.addPath(MagnifierGeometry.path(of: magnifier.shape, in: ring))
            context.strokePath()
        }
    }
}
