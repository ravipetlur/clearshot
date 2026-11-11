import CoreGraphics
import Foundation

/// A guide: a straight line across the whole picture, shown while ⌥S (vertical) or ⌥D (horizontal) is held, and imprinted by a
/// click as a line annotation.
public struct PictureGuide: Equatable, Sendable {
    public enum Axis: Equatable, Sendable {
        /// Full height, at an x position (⌥S).
        case vertical
        /// Full width, at a y position (⌥D).
        case horizontal
    }

    public let axis: Axis
    /// The line's ends in output pixels (the picture as shown): the whole canvas across, at the middle of the pixel under the
    /// pointer, so it is crisp.
    public let start: CGPoint
    public let end: CGPoint
    /// The pixel it runs through, counted from the canvas's top-left corner (the x of a vertical guide, the y of a horizontal).
    public let position: Int
}

extension AnnotationDocument {
    /// The guide of `axis` through `point` (output pixels), or nil when the point is off the canvas.
    public func guide(_ axis: PictureGuide.Axis, through point: CGPoint) -> PictureGuide? {
        let canvas = canvasBounds
        guard canvas.contains(point) else { return nil }
        switch axis {
        case .vertical:
            let column = Int((point.x - canvas.minX).rounded(.down))
            let x = canvas.minX + Double(column) + 0.5
            return PictureGuide(axis: axis, start: CGPoint(x: x, y: canvas.minY), end: CGPoint(x: x, y: canvas.maxY), position: column)
        case .horizontal:
            let row = Int((point.y - canvas.minY).rounded(.down))
            let y = canvas.minY + Double(row) + 0.5
            return PictureGuide(axis: axis, start: CGPoint(x: canvas.minX, y: y), end: CGPoint(x: canvas.maxX, y: y), position: row)
        }
    }

    /// A guide's position in `unit`, as "x 120 pt" or "y 64 px" (a point's position is at the start of its pixel).
    public func guideLabel(_ guide: PictureGuide, in unit: SizeUnit) -> String {
        let value = displayedLength(outputPixels: Double(guide.position), in: unit)
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return "\(guide.axis == .vertical ? "x" : "y") \(number) \(unit.abbreviation)"
    }
}

extension AnnotationEditor {
    /// The guide through `point` (output pixels), or nil off the picture.
    public func guide(_ axis: PictureGuide.Axis, through point: CGPoint) -> PictureGuide? {
        document.guide(axis, through: point)
    }

    /// Imprints a guide as a line across the whole picture, in the current color and width: one undo step, and selected.
    public func imprint(_ guide: PictureGuide) {
        let transform = document.transform
        let style = newStyle(lineWidthPoints: ToolSizes.lineWidth(settings.sizeLevel))
        add(AnnotationObject(kind: .line(start: transform.toBase(guide.start), end: transform.toBase(guide.end)), style: style),
            actionName: "Add Line")
    }
}
