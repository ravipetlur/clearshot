import AppKit
import CoreGraphics
import CoreText
import Foundation

extension Renderer {
    /// A ruler: a thin line with a cap across each end, and its label in a small rounded plate beside it (see
    /// `RulerGeometry`). The line is thinner than the object's width says, since a measurement should not hide what it
    /// measures; the plate takes the object's color and the text the color that reads on it.
    static func drawRuler(_ ruler: RulerObject, lineWidth: Double, color: RGBAColor, pixelScale: Double, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(max(lineWidth / 2, 1))
        context.setLineCap(.butt)
        context.move(to: ruler.start)
        context.addLine(to: ruler.end)
        for (from, to) in RulerGeometry.caps(of: ruler, lineWidth: lineWidth) {
            context.move(to: from)
            context.addLine(to: to)
        }
        context.strokePath()
        guard let label = ruler.label, !label.isEmpty else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(11 * pixelScale, lineWidth * 3.5), weight: .semibold)
        let attributed = NSAttributedString(string: label, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.contrastingTextColor.cgColor,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let text = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padding = font.pointSize * 0.3
        let size = CGSize(width: text.width + 2 * padding, height: font.pointSize * 1.3 + padding)
        let plate = RulerGeometry.labelFrame(of: ruler, size: size, lineWidth: lineWidth)
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(roundedRect: plate, cornerWidth: padding, cornerHeight: padding, transform: nil))
        context.fillPath()
        context.translateBy(x: plate.midX, y: plate.midY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -text.midX, y: -text.midY)
        CTLineDraw(line, context)
    }
}
