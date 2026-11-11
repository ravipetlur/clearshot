import AppKit
import CoreGraphics
import CoreText
import CSCore
import Foundation

/// The ruler's lengths, label text and the places its parts go: what the renderer and the canvas draw, in base pixels.
public enum RulerGeometry {
    /// The tolerance's range (0...64): how far two colors may differ, on any channel, and still count as one run.
    public static let toleranceRange = 0...64
    /// The tolerance a new editor starts with.
    public static let defaultTolerance = 8

    /// `tolerance` held to its range.
    public static func clampedTolerance(_ tolerance: Int) -> Int {
        min(max(tolerance, toleranceRange.lowerBound), toleranceRange.upperBound)
    }

    // MARK: Length and label

    /// The distance between the ruler's ends as shown, in output pixels: through the image operations, so a resize changes
    /// it and a turn does not.
    public static func outputLength(of ruler: RulerObject, in document: AnnotationDocument) -> Double {
        let start = ruler.start.applying(document.transform.transform), end = ruler.end.applying(document.transform.transform)
        return hypot(end.x - start.x, end.y - start.y)
    }

    /// The text for a length: "123 pt" or "246 px". Pixels are whole; points show a tenth when they aren't whole numbers
    /// (a 1.5x display's 100 pixels are 66.7 points).
    public static func labelText(outputPixels: Double, unit: SizeUnit, pixelsPerPoint: Double) -> String {
        let length = unit == .pixels ? outputPixels : outputPixels / max(pixelsPerPoint, 0.0001)
        let rounded = unit == .pixels ? length.rounded() : (length * 10).rounded() / 10
        let number = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(number) \(unit.abbreviation)"
    }

    /// The label of `ruler` in `document`, in `unit`.
    public static func labelText(of ruler: RulerObject, in document: AnnotationDocument, unit: SizeUnit) -> String {
        labelText(outputPixels: outputLength(of: ruler, in: document), unit: unit, pixelsPerPoint: document.renderedScale)
    }

    // MARK: Drawing

    /// Half the length of an end cap: long enough to read against a thick line.
    public static func capHalfLength(lineWidth: Double) -> Double {
        max(lineWidth * 2.5, 5)
    }

    /// The two end caps, each a segment across the line (perpendicular to it) through one end. A ruler with no length has
    /// caps across the horizontal.
    public static func caps(of ruler: RulerObject, lineWidth: Double) -> [(CGPoint, CGPoint)] {
        let direction = unitDirection(of: ruler)
        let half = capHalfLength(lineWidth: lineWidth)
        let across = CGVector(dx: -direction.dy * half, dy: direction.dx * half)
        return [ruler.start, ruler.end].map {
            (CGPoint(x: $0.x - across.dx, y: $0.y - across.dy), CGPoint(x: $0.x + across.dx, y: $0.y + across.dy))
        }
    }

    /// Where the label of `size` goes: centered along the line, clear of the caps, above a mostly horizontal ruler and to
    /// the right of a mostly vertical one.
    public static func labelFrame(of ruler: RulerObject, size: CGSize, lineWidth: Double) -> CGRect {
        let middle = CGPoint(x: (ruler.start.x + ruler.end.x) / 2, y: (ruler.start.y + ruler.end.y) / 2)
        let gap = capHalfLength(lineWidth: lineWidth) + lineWidth
        let horizontal = abs(ruler.end.x - ruler.start.x) >= abs(ruler.end.y - ruler.start.y)
        let center = horizontal
            ? CGPoint(x: middle.x, y: middle.y - gap - size.height / 2)
            : CGPoint(x: middle.x + gap + size.width / 2, y: middle.y)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// The label's font size in base pixels: 11 points at the picture's scale, larger beside a thick line.
    public static func labelFontSize(lineWidth: Double, pixelScale: Double) -> Double {
        max(11 * pixelScale, lineWidth * 3.5)
    }

    /// The label as the renderer draws it: its text set in `font`, on a rounded plate at `frame` with corners of `padding`.
    struct LabelPlate {
        var frame: CGRect
        var font: NSFont
        var line: CTLine
        /// The text's optical bounds, relative to its baseline origin.
        var textBounds: CGRect
        var padding: Double
    }

    /// The ruler's label plate (`labelFrame`), or nil for a ruler without a label. The text color is `textColor`, which
    /// doesn't change the plate's size.
    static func labelPlate(of ruler: RulerObject, lineWidth: Double, textColor: CGColor? = nil) -> LabelPlate? {
        guard let label = ruler.label, !label.isEmpty else { return nil }
        let size = ruler.labelFontSize ?? labelFontSize(lineWidth: lineWidth, pixelScale: 1)
        guard size.isFinite, size > 0 else { return nil }
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let textColor { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = textColor }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
        let text = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padding = font.pointSize * 0.3
        let plateSize = CGSize(width: text.width + 2 * padding, height: font.pointSize * 1.3 + padding)
        return LabelPlate(frame: labelFrame(of: ruler, size: plateSize, lineWidth: lineWidth), font: font, line: line,
                          textBounds: text, padding: padding)
    }

    /// The painted bounds of the line, its caps and, for a labeled ruler, its label's plate.
    public static func bounds(of ruler: RulerObject, lineWidth: Double) -> CGRect {
        let points = [ruler.start, ruler.end] + caps(of: ruler, lineWidth: lineWidth).flatMap { [$0.0, $0.1] }
        let xs = points.map(\.x), ys = points.map(\.y)
        let line = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        guard let plate = labelPlate(of: ruler, lineWidth: lineWidth)?.frame, plate.isFiniteRect else { return line }
        return line.union(plate)
    }

    private static func unitDirection(of ruler: RulerObject) -> CGVector {
        let dx = ruler.end.x - ruler.start.x, dy = ruler.end.y - ruler.start.y
        let length = hypot(dx, dy)
        return length > 0 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 1, dy: 0)
    }
}

extension SizeUnit {
    /// The unit a ruler's label is written in when the caller doesn't say: Settings › Annotate › Show sizes in's default.
    /// The app passes the setting itself to the renderer (`Renderer.render(_:images:rulerUnit:)`).
    public static let rulerDefault = Prefs.annotateSizeUnit.defaultValue
}

extension AnnotationDocument {
    /// `objects` with each ruler's `label` set: the length as the picture is now, in `unit`, at the size the renderer
    /// writes it.
    public func labelingRulers(_ objects: [AnnotationObject], in unit: SizeUnit) -> [AnnotationObject] {
        objects.map { labelingRuler($0, in: unit) }
    }

    private func labelingRuler(_ object: AnnotationObject, in unit: SizeUnit) -> AnnotationObject {
        guard case .ruler(var ruler) = object.kind else { return object }
        ruler.label = RulerGeometry.labelText(of: ruler, in: self, unit: unit)
        ruler.labelFontSize = RulerGeometry.labelFontSize(lineWidth: object.style.lineWidth, pixelScale: pixelScale)
        var copy = object
        copy.kind = .ruler(ruler)
        return copy
    }

    /// The objects in `visualOrder`, with each ruler labeled in `rulerUnit`: what the renderer draws.
    public func drawingOrder(rulerUnit: SizeUnit) -> [AnnotationObject] {
        labelingRulers(visualOrder, in: rulerUnit)
    }

    /// Everything `object` paints when this document draws it, in base pixels (`ObjectGeometry.bounds`), a ruler's label
    /// included. With `rulerUnit` nil a ruler's bounds hold its label in either unit, so they don't depend on a setting.
    public func paintedBounds(of object: AnnotationObject, rulerUnit: SizeUnit? = nil) -> CGRect {
        guard case .ruler = object.kind else { return ObjectGeometry.bounds(of: object) }
        let units = rulerUnit.map { [$0] } ?? SizeUnit.allCases
        return units.reduce(CGRect.null) { $0.union(ObjectGeometry.bounds(of: labelingRuler(object, in: $1))) }
    }
}
