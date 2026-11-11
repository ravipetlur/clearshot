import AppKit
import CSAnnotation

/// What the canvas draws for smart selection: the outline a ⌥-drag would fit to, and a short notice.
extension AnnotationCanvasView {
    func drawSmartSelectionOverlays(in context: CGContext) {
        let zoom = max(magnification(), 0.01)
        if let outline = editor.fitPreviewOutline {
            let rect = viewRect(fromBase: outline)
            context.saveGState()
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2 / zoom)
            context.stroke(rect)
            context.setStrokeColor(NSColor.systemGreen.cgColor)
            context.setLineWidth(1 / zoom)
            context.setLineDash(phase: 0, lengths: [3 / zoom, 3 / zoom])
            context.stroke(rect)
            context.restoreGState()
        }
        if let notice = editor.pixelNotice {
            // Top left of what is on screen.
            let corner = CGRect(x: visibleRect.minX + 8 / zoom, y: visibleRect.minY + 4 / zoom, width: 0, height: 0)
            drawBadge(notice, near: corner, zoom: zoom)
        }
    }
}
