import AppKit
import CoreGraphics
import CoreText
import Foundation

extension Renderer {
    /// A ruler: a thin line with a cap across each end, and its label in a small rounded plate beside it (see
    /// `RulerGeometry`). The line is thinner than the object's width says, since a measurement should not hide what it
    /// measures; the plate takes the object's color and the text the color that reads on it. A label without a font size
    /// is set at `pixelScale`.
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
        var sized = ruler
        if sized.labelFontSize == nil {
            sized.labelFontSize = RulerGeometry.labelFontSize(lineWidth: lineWidth, pixelScale: pixelScale)
        }
        guard let plate = RulerGeometry.labelPlate(of: sized, lineWidth: lineWidth, textColor: color.contrastingTextColor.cgColor)
        else { return }
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(roundedRect: plate.frame, cornerWidth: plate.padding, cornerHeight: plate.padding, transform: nil))
        context.fillPath()
        context.translateBy(x: plate.frame.midX, y: plate.frame.midY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -plate.textBounds.midX, y: -plate.textBounds.midY)
        CTLineDraw(plate.line, context)
    }
}
