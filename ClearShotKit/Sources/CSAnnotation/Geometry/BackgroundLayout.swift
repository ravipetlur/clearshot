import CoreGraphics
import Foundation

/// How much auto-balance takes off each edge of the content, in whole output pixels.
public struct EdgeTrims: Hashable, Sendable {
    public var top, left, bottom, right: Double

    public static let zero = EdgeTrims(top: 0, left: 0, bottom: 0, right: 0)

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// The background's frame around the canvas, in output pixels: the canvas and its objects stay where they are and the
/// frame grows around them.
///
/// The content (the canvas less auto-balance's trims) grows by the inset into the box, which the inset colour fills and
/// the corners and shadow shape. The box grows by the padding into the frame; a ratio then grows the frame's shorter side,
/// and the alignment says where the extra room goes. Padding and inset are whole pixels, so with a whole canvas the frame
/// is whole too. No side passes `AnnotationDocument.maximumOutputSide` unless the content itself does.
public struct BackgroundLayout: Equatable, Sendable {
    /// The canvas less the trims.
    public var content: CGRect
    /// The content grown by the inset.
    public var box: CGRect
    /// Everything the background draws: the box grown by the padding and the ratio.
    public var frame: CGRect
    /// The padding and inset in whole pixels, as used: the limit can make them smaller than the style's.
    public var padding: Double
    public var inset: Double
    /// The box's corner radius in pixels, at most half its shorter side.
    public var cornerRadius: Double
    /// The ratio the frame has: the style's, or Auto when the limit gave it up.
    public var ratio: BackgroundRatio

    /// The layout of `style` around `canvas`, with style lengths at `scale` pixels per point
    /// (`AnnotationDocument.backgroundScale`).
    ///
    /// A frame over the limit first drops the ratio to Auto, then takes as much padding as fits. A box over the limit by
    /// itself has no padding and as much inset as fits; content over it (only a document `isWellFormed` allows, up to
    /// `AnnotationDocument.maximumSide`) is its own frame.
    public static func make(canvas: CGRect, style: BackgroundStyle, scale: Double, trims: EdgeTrims = .zero) -> BackgroundLayout {
        let limit = AnnotationDocument.maximumOutputSide
        let content = CGRect(x: canvas.minX + trims.left, y: canvas.minY + trims.top,
                             width: max(0, canvas.width - trims.left - trims.right),
                             height: max(0, canvas.height - trims.top - trims.bottom))
        var inset = wholePixels(style.inset, scale: scale)
        var padding = wholePixels(style.padding, scale: scale)
        var box = content.insetBy(dx: -inset, dy: -inset)
        var ratio = style.ratio
        var frame = Self.frame(around: box, padding: padding, ratio: ratio, alignment: style.alignment)
        func fits(_ rect: CGRect) -> Bool {
            rect.width <= limit && rect.height <= limit
        }
        if !fits(frame) {
            ratio = .auto
            frame = Self.frame(around: box, padding: padding, ratio: .auto, alignment: style.alignment)
        }
        if !fits(frame) {
            /// The most room that fits around `inner` on every side, in whole pixels.
            func room(around inner: CGRect) -> Double {
                max(0, min((limit - inner.width) / 2, (limit - inner.height) / 2).rounded(.down))
            }
            if fits(box) {
                padding = room(around: box)
            } else {
                inset = room(around: content)
                box = content.insetBy(dx: -inset, dy: -inset)
                padding = 0
            }
            frame = Self.frame(around: box, padding: padding, ratio: .auto, alignment: style.alignment)
        }
        let corners = style.corners * scale
        let cornerRadius = max(0, min(corners.isFinite ? corners : 0, box.width / 2, box.height / 2))
        return BackgroundLayout(content: content, box: box, frame: frame, padding: padding, inset: inset,
                                cornerRadius: cornerRadius, ratio: ratio)
    }

    /// `points` at `scale`, in whole pixels, rounded as the window capture rounds its padding (`Int(x.rounded())`, so
    /// 18.5 is 19). What isn't a positive number is 0; past the limit is the limit, which `make` reduces anyway, so the
    /// conversion can't trap.
    private static func wholePixels(_ points: Double, scale: Double) -> Double {
        let pixels = (points * scale).rounded()
        guard pixels > 0 else { return 0 }
        return Double(Int(min(pixels, AnnotationDocument.maximumOutputSide)))
    }

    /// The box grown by `padding`, then on its shorter side to `ratio` (rounded up to whole pixels; the −1e-9 keeps an
    /// exact product from rounding up a pixel), with the extra room placed by `alignment`. The room before the box is
    /// floored to a whole pixel, so an odd room splits with the extra pixel after the box.
    private static func frame(around box: CGRect, padding: Double, ratio: BackgroundRatio,
                              alignment: BackgroundAlignment) -> CGRect {
        let minimumWidth = box.width + 2 * padding, minimumHeight = box.height + 2 * padding
        var width = minimumWidth, height = minimumHeight
        if let aspect = ratio.aspect, minimumWidth > 0, minimumHeight > 0 {
            if minimumWidth / minimumHeight < aspect {
                width = max(minimumWidth, (minimumHeight * aspect - 1e-9).rounded(.up))
            } else {
                height = max(minimumHeight, (minimumWidth / aspect - 1e-9).rounded(.up))
            }
        }
        let factor = alignment.factor
        let before = (x: ((width - minimumWidth) * factor.x).rounded(.down), y: ((height - minimumHeight) * factor.y).rounded(.down))
        return CGRect(x: box.minX - padding - before.x, y: box.minY - padding - before.y, width: width, height: height)
    }
}
