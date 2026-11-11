import CoreGraphics
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

    /// The painted bounds of the line and its caps (the label is not counted: its size is the renderer's).
    public static func bounds(of ruler: RulerObject, lineWidth: Double) -> CGRect {
        let points = [ruler.start, ruler.end] + caps(of: ruler, lineWidth: lineWidth).flatMap { [$0.0, $0.1] }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
    }

    private static func unitDirection(of ruler: RulerObject) -> CGVector {
        let dx = ruler.end.x - ruler.start.x, dy = ruler.end.y - ruler.start.y
        let length = hypot(dx, dy)
        return length > 0 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 1, dy: 0)
    }
}

extension SizeUnit {
    /// The unit Settings › Annotate › Show sizes in has now. A ruler's label is made wherever the picture is drawn, an export
    /// included, which has no preferences store at hand: this reads the standard defaults the store writes to.
    public static var stored: SizeUnit {
        SizeUnit.read(from: .standard, key: Prefs.annotateSizeUnit.name) ?? Prefs.annotateSizeUnit.defaultValue
    }
}

extension AnnotationDocument {
    /// `objects` with each ruler's `label` set: the length as the picture is now, in `unit`.
    func labelingRulers(_ objects: [AnnotationObject], in unit: SizeUnit) -> [AnnotationObject] {
        objects.map { object in
            guard case .ruler(var ruler) = object.kind else { return object }
            ruler.label = RulerGeometry.labelText(of: ruler, in: self, unit: unit)
            var copy = object
            copy.kind = .ruler(ruler)
            return copy
        }
    }
}
