import CoreGraphics

/// An arrow key's move of a pin.
public enum PinNudge: Sendable {
    case left, right, up, down
}

/// A pin's size, zoom, opacity and moves. Sizes are in points; frames are AppKit (y up).
public enum PinGeometry {
    /// The shortest a pin window's side gets, so a tiny image still has something to grab.
    public static let minimumSide: CGFloat = 48
    /// The longest a pin window's side gets: 16 000 px on a 2× display, under the 16 384 px texture limit.
    public static let maximumSide: CGFloat = 8000
    public static let cornerRadius: CGFloat = 10
    /// The Zoom submenu, smallest first.
    public static let zoomPresets: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]
    /// The Opacity submenu, smallest first.
    public static let opacityPresets: [Double] = [0.25, 0.5, 0.75, 1]
    public static let zoomLimits: ClosedRange<Double> = 0.1...8
    public static let opacityLimits: ClosedRange<Double> = 0.1...1

    /// How far from the current zoom a preset has to be for ⌘+ or ⌘− to step to it.
    private static let presetTolerance = 0.001
    /// How close a value has to be to a preset for the menu to check it.
    private static let currentTolerance = 0.005
    /// Opacity change per trackpad point and per wheel line scrolled.
    private static let opacityPerPoint = 0.005
    private static let opacityPerLine = 0.05

    /// The image's size in points. A scale that is zero, negative or not finite counts as 1.
    public static func imagePoints(pixelSize: CGSize, scale: Double) -> CGSize {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        return CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }

    /// The highest zoom for this image: 800%, or less when the longer side would pass `maximumSide`. Never below 10%.
    public static func maximumZoom(imagePoints: CGSize) -> Double {
        let longer = Double(max(imagePoints.width, imagePoints.height))
        guard longer > 0 else { return zoomLimits.upperBound }
        return max(zoomLimits.lowerBound, min(zoomLimits.upperBound, Double(maximumSide) / longer))
    }

    /// `zoom` within 10% and `maximumZoom`. A zoom that isn't finite counts as 100%.
    public static func clampedZoom(_ zoom: Double, imagePoints: CGSize) -> Double {
        let zoom = zoom.isFinite ? zoom : 1
        return min(max(zoom, zoomLimits.lowerBound), maximumZoom(imagePoints: imagePoints))
    }

    /// `opacity` within 10% and 100%. An opacity that isn't finite counts as 100%.
    public static func clampedOpacity(_ opacity: Double) -> Double {
        guard opacity.isFinite else { return opacityLimits.upperBound }
        return min(max(opacity, opacityLimits.lowerBound), opacityLimits.upperBound)
    }

    /// The pin window: the image at `zoom`, each side at least `minimumSide`.
    public static func windowSize(imagePoints: CGSize, zoom: Double) -> CGSize {
        let image = scaled(imagePoints, by: zoom)
        return CGSize(width: max(minimumSide, image.width), height: max(minimumSide, image.height))
    }

    /// Where the image sits in the window, in the window's own coordinates: at its own size for `zoom`, centred, its
    /// origin on whole points. It is never stretched to fill a window the minimum side made larger.
    public static func imageRect(imagePoints: CGSize, zoom: Double) -> CGRect {
        let image = scaled(imagePoints, by: zoom)
        let window = windowSize(imagePoints: imagePoints, zoom: zoom)
        return CGRect(x: ((window.width - image.width) / 2).rounded(.down),
                      y: ((window.height - image.height) / 2).rounded(.down),
                      width: image.width, height: image.height)
    }

    /// `frame` resized to `size` so `anchor` stays at the same fraction of it: the point under the pointer for a pinch.
    /// A nil anchor, or one outside the frame, keeps the centre (the zoom keys and the Zoom menu).
    public static func zoomed(_ frame: CGRect, to size: CGSize, anchor: CGPoint?) -> CGRect {
        let point = anchor.flatMap { isWithin(frame, $0) ? $0 : nil } ?? CGPoint(x: frame.midX, y: frame.midY)
        let fractionX = frame.width > 0 ? (point.x - frame.minX) / frame.width : 0.5
        let fractionY = frame.height > 0 ? (point.y - frame.minY) / frame.height : 0.5
        return CGRect(x: point.x - fractionX * size.width, y: point.y - fractionY * size.height,
                      width: size.width, height: size.height)
    }

    /// The next preset up (⌘+), skipping presets this image can't reach; nil at the top.
    public static func nextZoom(after zoom: Double, imagePoints: CGSize) -> Double? {
        let ceiling = maximumZoom(imagePoints: imagePoints)
        return zoomPresets.first { $0 > zoom + presetTolerance && $0 <= ceiling }
    }

    /// The next preset down (⌘−); nil at the bottom.
    public static func previousZoom(before zoom: Double) -> Double? {
        zoomPresets.last { $0 < zoom - presetTolerance }
    }

    /// Whether the menu checks `preset` for the pin's current `value`.
    public static func isCurrent(_ preset: Double, _ value: Double) -> Bool {
        abs(preset - value) <= currentTolerance
    }

    /// The opacity after a vertical scroll. `delta` is the scroll toward the top of the screen in physical terms
    /// (fingers up on a trackpad, the wheel turned away from you): trackpad points when `precise`, else wheel lines.
    public static func opacity(_ opacity: Double, scrolledUp delta: Double, precise: Bool) -> Double {
        clampedOpacity(opacity + delta * (precise ? opacityPerPoint : opacityPerLine))
    }

    /// `frame` moved by an arrow key: 1 pt, or 10 pt when `large` (⇧). Up is +y.
    public static func nudged(_ frame: CGRect, _ direction: PinNudge, large: Bool) -> CGRect {
        let step: CGFloat = large ? 10 : 1
        return switch direction {
        case .left: frame.offsetBy(dx: -step, dy: 0)
        case .right: frame.offsetBy(dx: step, dy: 0)
        case .up: frame.offsetBy(dx: 0, dy: step)
        case .down: frame.offsetBy(dx: 0, dy: -step)
        }
    }

    private static func scaled(_ size: CGSize, by zoom: Double) -> CGSize {
        CGSize(width: size.width * zoom, height: size.height * zoom)
    }

    /// Whether `point` is in `frame`, edges included (`CGRect.contains` leaves out the max edges).
    private static func isWithin(_ frame: CGRect, _ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }
}
