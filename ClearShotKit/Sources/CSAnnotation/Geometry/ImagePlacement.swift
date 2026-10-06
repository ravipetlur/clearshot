import CoreGraphics
import CSCapture
import Foundation

/// Where a new image object goes and how its bitmap is kept. Sizes and rects in output pixels.
public enum ImagePlacement {
    /// The image's size in output pixels at its own pixel scale: `imageScale` pixels per point in, `outputScale` output
    /// pixels per canvas point (the document's `pixelScale`) out. A scale that isn't a positive number counts as 1.
    public static func naturalSize(pixelSize: CGSize, imageScale: Double, outputScale: Double) -> CGSize {
        let output = outputScale.isFinite && outputScale > 0 ? outputScale : 1
        let image = imageScale.isFinite && imageScale > 0 ? imageScale : 1
        return CGSize(width: pixelSize.width * output / image, height: pixelSize.height * output / image)
    }

    /// Pixels per point from an image's recorded density. Only 72 × n dpi for n = 1, 2 or 3 is a hint of a Retina picture
    /// (macOS writes 144 dpi PNGs, and 216 for 3x); a density within half a dpi of those counts as n. Any other is a print
    /// setting (scans and camera JPEGs at 300, Windows screenshots at 96) that says nothing about how big the picture
    /// should be on screen, and counts as 1. A missing or nonsensical density is 1.
    public static func scale(forDPI dpi: Double?) -> Double {
        guard let dpi, dpi.isFinite, dpi > 0 else { return 1 }
        let multiple = (dpi / 72).rounded()
        return (1...3).contains(multiple) && abs(dpi - 72 * multiple) <= 0.5 ? multiple : 1
    }

    /// A rect of `size` centred on `center`, scaled down (never up) so it fits within `fraction` of `canvas` on both sides
    /// (`fraction` counts as 100% at most), then moved, if its centre is near or past an edge, to lie within `canvas`: an
    /// image put in the canvas never grows it. Whole pixels, at least one on a side.
    public static func placed(size: CGSize, in canvas: CGRect, centeredOn center: CGPoint, fraction: Double = 0.8) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: center, size: .zero) }
        let share = min(fraction, 1)
        let scale = min(1, canvas.width * share / size.width, canvas.height * share / size.height)
        let width = max(1, (size.width * scale).rounded()), height = max(1, (size.height * scale).rounded())
        let x = max(canvas.minX, min((center.x - width / 2).rounded(), canvas.maxX - width))
        let y = max(canvas.minY, min((center.y - height / 2).rounded(), canvas.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The bitmap scaled down, keeping its proportions, so its longer side is at most `maximumSide` pixels; the bitmap
    /// itself when it already is. Nil if it can't be scaled.
    public static func limited(_ image: CGImage, maximumSide: Int = Int(AnnotationDocument.maximumOutputSide)) -> CGImage? {
        let longer = max(image.width, image.height)
        guard longer > maximumSide else { return image }
        let scale = Double(maximumSide) / Double(longer)
        return ImageOps.resized(image, width: max(1, Int((Double(image.width) * scale).rounded())),
                                height: max(1, Int((Double(image.height) * scale).rounded())))
    }

    /// The bitmap turned and mirrored so that, drawn upright in base pixels, it shows upright in the output. Image
    /// objects live in base pixels, which Rotate and Flip turn with everything else, and objects can't rotate. The
    /// bitmap itself when the document has no turn or mirror. Nil if a bitmap can't be made.
    public static func orientedForBase(_ image: CGImage, transform: DocumentTransform) -> CGImage? {
        let m = transform.transform
        let sx = hypot(m.a, m.b), sy = hypot(m.c, m.d)
        guard sx > 0, sy > 0 else { return image }
        // The base-to-output map's turn and mirror, without its scale.
        let orientation = CGAffineTransform(a: (m.a / sx).rounded(), b: (m.b / sx).rounded(), c: (m.c / sy).rounded(),
                                            d: (m.d / sy).rounded(), tx: 0, ty: 0)
        guard orientation != .identity else { return image }
        let inverse = orientation.inverted()
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height).applying(inverse)
        let width = Int(extent.width.rounded()), height = Int(extent.height.rounded())
        // The image's own color space when an 8-bit bitmap can hold it, sRGB when not (an extended-range or HDR picture).
        guard width > 0, height > 0, let context = ImageOps.bitmapContext(width: width, height: height, preferring: image.colorSpace)
        else { return nil }
        // y down, like base pixels; then each point of the upright image lands where the inverse turn puts it.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -extent.minX, y: -extent.minY)
        context.concatenate(inverse)
        Renderer.drawImage(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
        return context.makeImage()
    }
}

/// Combining screenshots: an image put beside the canvas on one side, centred on the other axis, and the canvas grown
/// to hold both. Output pixels, except the drop zones, which are in view points.
public enum CombineLayout {
    /// The least an image scaled down to fit may be on either side: less is a sliver, not a picture.
    public static let minimumScaledSide = 16.0

    /// Where an image of `imageSize` goes beside `canvas` on `edge`, `gap` pixels away, and the canvas that holds both.
    /// An image that would take the canvas past `maximumSide` on a side is scaled down to fit. Nil when that side has no
    /// room left, or so little that the scaled image would be under `minimumScaledSide` on a side: the caller then puts
    /// the image where it was dropped instead.
    public static func place(imageSize: CGSize, onto canvas: CGRect, edge: RectEdge, gap: Double = 0,
                             maximumSide: Double = AnnotationDocument.maximumOutputSide) -> (rect: CGRect, canvas: CGRect)? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let horizontal = edge == .left || edge == .right
        let room = (horizontal ? maximumSide - canvas.width : maximumSide - canvas.height) - gap
        guard room >= 1 else { return nil }
        let scale = horizontal
            ? min(1, room / imageSize.width, maximumSide / imageSize.height)
            : min(1, room / imageSize.height, maximumSide / imageSize.width)
        let width = max(1, (imageSize.width * scale).rounded())
        let height = max(1, (imageSize.height * scale).rounded())
        guard scale == 1 || min(width, height) >= minimumScaledSide else { return nil }
        let rect: CGRect = switch edge {
        case .right: CGRect(x: canvas.maxX + gap, y: (canvas.midY - height / 2).rounded(), width: width, height: height)
        case .left: CGRect(x: canvas.minX - gap - width, y: (canvas.midY - height / 2).rounded(), width: width, height: height)
        case .top: CGRect(x: (canvas.midX - width / 2).rounded(), y: canvas.minY - gap - height, width: width, height: height)
        case .bottom: CGRect(x: (canvas.midX - width / 2).rounded(), y: canvas.maxY + gap, width: width, height: height)
        }
        return (rect, canvas.union(rect))
    }

    /// The four drop zones shown while an image is dragged over the canvas: strips `thickness` deep along the edges of
    /// `area` (the visible canvas, in view points, y down). The left and right ones run the full height; the top and bottom
    /// ones fit between them.
    public static func dropZones(in area: CGRect, thickness: Double) -> [(edge: RectEdge, rect: CGRect)] {
        let depth = max(0, min(thickness, area.width / 2, area.height / 2))
        return [
            (.left, CGRect(x: area.minX, y: area.minY, width: depth, height: area.height)),
            (.right, CGRect(x: area.maxX - depth, y: area.minY, width: depth, height: area.height)),
            (.top, CGRect(x: area.minX + depth, y: area.minY, width: area.width - 2 * depth, height: depth)),
            (.bottom, CGRect(x: area.minX + depth, y: area.maxY - depth, width: area.width - 2 * depth, height: depth)),
        ]
    }

    /// The drop zone under `point`, if any.
    public static func edge(at point: CGPoint, in area: CGRect, thickness: Double) -> RectEdge? {
        dropZones(in: area, thickness: thickness).first { $0.rect.contains(point) }?.edge
    }
}
